//
//  OPFParser.swift
//  R2Streamer
//
//  Created by Alexandre Camilleri on 2/21/17.
//  Copyright © 2017 Readium. All rights reserved.
//

import Foundation
import AEXML

extension OPFParser: Loggable {}

enum OPFParserError: Error {
    /// The Epub have no title. Title is mandatory.
    case missingPublicationTitle
}

/// EpubParser support class, able to parse the OPF package document.
/// OPF: Open Packaging Format.
public class OPFParser {
    let smilp: SMILParser!

    internal init() {
        smilp = SMILParser()
    }

    /// Parse the OPF file of the Epub container and return a `Publication`.
    /// It also complete the informations stored in the container.
    ///
    /// - Parameter container: The EPUB container whom OPF file will be parsed.
    /// - Returns: The `Publication` object resulting from the parsing.
    /// - Throws: `EpubParserError.xmlParse`.
    internal func parseOPF(from document: AEXMLDocument,
                           with container: EpubContainer,
                           and epubVersion: Double) throws -> Publication
    {
        /// The 'to be built' Publication.
        var publication = Publication()

        publication.epubVersion = epubVersion
        publication.internalData["type"] = "epub"
        publication.internalData["rootfile"] = container.rootFile.rootFilePath
        // Self link is added when the epub is being served (in the EpubServer).
        // CoverId.
        var coverId: String?
        if let coverMetas = document.root["metadata"]["meta"].all(withAttributes: ["name" : "cover"]) {
            coverId = coverMetas.first?.string
        }
        try parseMetadata(from: document, to: &publication)
        parseRessources(from: document.root["manifest"], to: &publication, coverId: coverId)
        parseSpine(from: document.root["spine"], to: &publication)
        try parseMediaOverlay(from: container, to: &publication)
        return publication
    }

    /// Parse the Metadata in the XML <metadata> element.
    ///
    /// - Parameter document: Parse the Metadata in the XML <metadata> element.
    /// - Returns: The Metadata object representing the XML <metadata> element.
    internal func parseMetadata(from document: AEXMLDocument, to publication: inout Publication) throws {
        /// The 'to be returned' Metadata object.
        var metadata = Metadata()
        let mp = MetadataParser()
        let metadataElement = document.root["metadata"]

        // Title.
        guard let multilangTitle = mp.mainTitle(from: metadataElement) else {
            throw OPFParserError.missingPublicationTitle
        }
        metadata._title = multilangTitle
        // Identifier.
        metadata.identifier = mp.uniqueIdentifier(from: metadataElement,
                                                  with: document.root.attributes)
        // Description.
        if let description = metadataElement["dc:description"].value {
            metadata.description = description
        }
        // Date. (year?)
        if let date = metadataElement["dc:date"].value {
            metadata.publicationDate = date
        }
        // Last modification date.
        metadata.modified = mp.modifiedDate(from: metadataElement)
        // Source.
        if let source = metadataElement["dc:source"].value {
            metadata.source = source
        }
        // Subject.
        if let subject = mp.subject(from: metadataElement) {
            metadata.subjects.append(subject)
        }
        // Languages.
        if let languages = metadataElement["dc:language"].all {
            metadata.languages = languages.map({ $0.string })
        }
        // Rights.
        if let rights = metadataElement["dc:rights"].all {
            metadata.rights = rights.map({ $0.string }).joined(separator: " ")
        }
        // Publishers, Creators, Contributors.
        let epubVersion = publication.epubVersion
        mp.parseContributors(from: metadataElement, to: &metadata, epubVersion)
        // Page progression direction.
        if let direction = document.root["spine"].attributes["page-progression-direction"] {
            metadata.direction = direction
        }
        // Rendition properties.
        mp.parseRenditionProperties(from: metadataElement, to: &metadata)
        publication.metadata = metadata
        /// Other Metadata.
        // Media overlays: media:duration
        mp.parseMediaDurations(from: metadataElement, to: &metadata.otherMetadata)
    }

    /// Parse XML elements of the <Manifest> in the package.opf file.
    /// Temporarily store the XML elements ids into the `.title` property of the
    /// `Link` created for each element.
    ///
    /// - Parameters:
    ///   - manifest: The Manifest XML element.
    ///   - publication: The `Publication` object with `.resource` properties to
    ///                  fill.
    ///   - coverId: The coverId to identify the cover ressource and tag it.
    internal func parseRessources(from manifest: AEXMLElement,
                                  to publication: inout Publication,
                                  coverId: String?)
    {
        // Get the manifest children items
        guard let manifestItems = manifest["item"].all else {
            log(level: .warning, "Manifest have no children elements.")
            return
        }
        /// Creates an Link for each of them and add it to the ressources.
        for item in manifestItems {
            // Add it to the manifest items dict if it has an id.
            guard let id = item.attributes["id"] else {
                log(level: .warning, "Manifest item MUST have an id, item ignored.")
                continue
            }
            let link = linkFromManifest(item)
            // If the link's rel contains the cover tag, append it to the publication links.
            if link.rel.contains("cover") {
                publication.links.append(link)
            }
            // If it's a media overlay ressource append it to the publication links.
            if link.typeLink == "application/smil+xml" {
                // Retrieve the duration of the smil file
                if let duration = publication.metadata.otherMetadata.first(where: { $0.property == "#\(id)" })?.value {

                    link.duration = Double(smilp.smilTimeToSeconds(duration))
                }
                //publication.links.append(link)
            }
            publication.resources.append(link)
        }
    }

    /// Parse XML elements of the <Spine> in the package.opf file.
    /// They are only composed of an `idref` referencing one of the previously
    /// parsed resource (XML: idref -> id). Since we normally don't keep
    /// the resource id, we store it in the `.title` property, temporarily.
    ///
    /// - Parameters:
    ///   - spine: The Spine XML element.
    ///   - publication: The `Publication` object with `.resource` and `.spine`
    ///                  properties to fill.
    internal func parseSpine(from spine: AEXMLElement, to publication: inout Publication) {
        // Get the spine children items.
        guard let spineItems = spine["itemref"].all else {
            log(level: .warning, "Spine have no children elements.")
            return
        }
        // Create a `Link` for each spine item and add it to `Publication.spine`.
        for item in spineItems {
            // Retrieve `idref`, referencing a resource id.
            // Only linear items are added to the spine.
            guard let idref = item.attributes["idref"],
                item.attributes["linear"]?.lowercased() != "no" else {
                    continue
            }
            // Find the ressource `idref` is referencing to.
            guard let index = publication.resources.index(where: { $0.title == idref }) else {
                log(level: .warning, "Referenced ressource for spine item with \(idref) not found.")
                continue
            }
            // Clean the title - used as a holder for the `idref`.
            publication.resources[index].title = nil
            // Move ressource to `.spine` and remove it from `.ressources`.
            publication.spine.append(publication.resources[index])
            publication.resources.remove(at: index)
        }
    }

    /// Parse the mediaOverlays informations contained in the ressources then
    /// parse the associted SMIL files to populate the MediaOverlays objects 
    /// in each of the Spine's Links.
    ///
    /// - Parameters:
    ///   - container: The Epub Container.
    ///   - publication: The Publication object representing the Epub data.
    internal func parseMediaOverlay(from container: EpubContainer,
                                    to publication: inout Publication) throws
    {
        let mediaOverlays = publication.resources.filter({ $0.typeLink ==  "application/smil+xml"})

        guard !mediaOverlays.isEmpty else {
            log(level: .info, "No media-overlays found in the Publication.")
            return
        }
        for mediaOverlayLink in mediaOverlays {
            let node = MediaOverlayNode()
            let smilXml = try container.xmlDocument(forRessourceReferencedByLink: mediaOverlayLink)
            let body = smilXml.root["body"]

            node.role.append("section")
            node.text = body.attributes["epub:textref"]
            // get body parameters <par>
            smilp.parseParameters(in: body, withParent: node)
            smilp.parseSequences(in: body, withParent: node, publicationSpine: &publication.spine)
            // "../xhtml/mo-002.xhtml#mo-1" => "../xhtml/mo-002.xhtml"

            guard let baseHref = node.text?.components(separatedBy: "#")[0],
                let link = publication.spine.first(where: {
                guard let linkRef = $0.href else {
                    return false
                }
                return baseHref.contains(linkRef)
            }) else {
                continue
            }
            link.mediaOverlays.append(node)
            link.properties.mediaOverlay.append(EpubConstant.mediaOverlayURL + link.href!)
        }
    }

    // MARK: - Fileprivate Methods.

    /// Generate a `Link` form the given manifest's XML element.
    ///
    /// - Parameter item: The XML element, or manifest XML item.
    /// - Returns: The `Link` representing the manifest XML item.
    fileprivate func linkFromManifest(_ item: AEXMLElement) -> Link {
        // The "to be built" link representing the manifest item.
        let link = Link()

        // TMP used for storing the id (associated to the idref of the spine items).
        // Will be cleared after the spine parsing.
        link.title = item.attributes["id"]
        //
        link.href = item.attributes["href"]
        link.typeLink = item.attributes["media-type"]
        // Look if item have any properties.
        if let propertyAttribute = item.attributes["properties"] {
            let properties = propertyAttribute.components(separatedBy: CharacterSet.whitespaces)

            // TODO: The contains "math/js" like in the Go streamer.
            // + refactor below.
            if properties.contains("nav") {
                link.rel.append("contents")
            }
            // If it's a cover, set the rel to cover and add the link to `links`
            if properties.contains("cover-image") {
                link.rel.append("cover")
            }
            let otherProperties = properties.filter { $0 != "cover-image" && $0 != "nav" }
            link.properties.mediaOverlay.append(contentsOf: otherProperties)
            // TODO: rendition properties
        }
        return link
    }
}












