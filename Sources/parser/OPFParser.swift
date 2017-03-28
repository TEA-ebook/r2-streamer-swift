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

/// EpubParser support class, able to parse the OPF package document.
/// OPF: Open Packaging Format.
public class OPFParser {

    internal init() {}

    /// Parse the OPF file of the Epub container and return a `Publication`.
    /// It also complete the informations stored in the container.
    ///
    /// - Parameter container: The EPUB container whom OPF file will be parsed.
    /// - Returns: The `Publication` object resulting from the parsing.
    /// - Throws: `EpubParserError.xmlParse`,
    ///           `OPFParserError.missingNavLink`,
    ///           `throw OPFParserError.missingNavLinkHref`.
    internal func parseOPF(from document: AEXMLDocument,
                           with container: Container,
                           and epubVersion: Double) throws -> Publication
    {
        /// The 'to be built' Publication.
        var publication = Publication()

        publication.epubVersion = epubVersion
        publication.internalData["type"] = "epub"
        publication.internalData["rootfile"] = container.rootFile.rootFilePath
        // TODO: Add self to links.
        // But we don't know the self URL here
        //publication.links.append(Link(href: "TODO", typeLink: "application/webpub+json", rel: "self"))

        var coverId: String?
        if let coverMetas = document.root["metadata"]["meta"].all(withAttributes: ["name" : "cover"]) {
            coverId = coverMetas.first?.string
        }
        parseMetadata(from: document, to: &publication)
        parseRessources(from: document.root["manifest"], to: &publication, coverId: coverId)
        parseSpine(from: document.root["spine"], to: &publication)
        return publication
    }

    /// Parse the Metadata in the XML <metadata> element.
    ///
    /// - Parameter document: Parse the Metadata in the XML <metadata> element.
    /// - Returns: The Metadata object representing the XML <metadata> element.
    internal func parseMetadata(from document: AEXMLDocument, to publication: inout Publication) {
        /// The 'to be returned' Metadata object.
        var metadata = Metadata()
        let mp = MetadataParser()
        let metadataElement = document.root["metadata"]

        metadata.title = mp.mainTitle(from: metadataElement, epubVersion: publication.epubVersion)
        metadata.identifier = mp.uniqueIdentifier(from: metadataElement,
                                                  withAttributes: document.root.attributes)
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
        mp.parseContributors(from: metadataElement, to: &metadata, with: publication.epubVersion)
        // Page progression direction.
        if let direction = document.root["spine"].attributes["page-progression-direction"] {
            metadata.direction = direction
        }
        // Rendition properties.
        mp.parseRenditionProperties(from: metadataElement["meta"], to: &metadata)
        publication.metadata = metadata
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
                log(level: .info, "Manifest item MUST have an id, item ignored.")
                continue
            }
            let link = linkFromManifest(item)
            // If it's the cover's item id, set the rel to cover and add the link to `links`.
            if id == coverId {
                link.rel.append("cover")
            }
            // If the link's rel contains the cover tag, append it to the publication link
            if link.rel.contains("cover") {
                publication.links.append(link)
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
            let link = Link()

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
            let ws = CharacterSet.whitespaces
            let properties = propertyAttribute.components(separatedBy: ws)

            if properties.contains("nav") {
                link.rel.append("contents")
            }
            // If it's a cover, set the rel to cover and add the link to `links`
            if properties.contains("cover-image") {
                link.rel.append("cover")
            }
            let otherProperties = properties.filter { $0 != "cover-image" && $0 != "nav" }
            link.properties.append(contentsOf: otherProperties)
            // TODO: rendition properties
        }
        return link
    }
}
