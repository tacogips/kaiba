import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Pulls the images an EPUB embeds, walking the OPF spine so every image is
/// attributed to the content document that references it.
///
/// EPUB is reflowable and has no page geometry, so there is nothing to capture
/// as a page raster without a full web renderer: this extractor emits embedded
/// images only. `pageNumber` therefore means "1-based spine position", which is
/// the closest stable analogue to a page in this format.
public struct EPUBDocumentImageExtractor: DocumentImageExtracting {
  /// Runaway guard for documents with unusually many illustrations.
  public static let maximumImages = 200

  private static let containerPath = "META-INF/container.xml"

  public init() {}

  public func extractImages(
    fileURL: URL,
    sourceFormat: String
  ) throws -> DocumentImageExtractionResult {
    let archive = try MinimalZipArchive(fileURL: fileURL)
    guard let packagePath = try Self.packagePath(in: archive) else {
      return .empty
    }
    let package = try EPUBPackageDocument.parse(
      data: try archive.data(forPath: packagePath)
    )

    var images: [DocumentExtractedImage] = []
    var pageTexts: [String] = []
    var seenPaths: Set<String> = []
    for (spineIndex, itemId) in package.spineItemIds.enumerated() {
      let pageNumber = spineIndex + 1
      guard let href = package.hrefByItemId[itemId],
            let documentPath = Self.resolvePath(href, relativeTo: packagePath),
            let documentData = try? archive.data(forPath: documentPath),
            let markup = Self.decodeText(documentData) else {
        pageTexts.append("")
        continue
      }
      pageTexts.append(HTMLTextExtraction.plainText(markup))

      var emittedOnPage = 0
      for reference in HTMLImageReferenceScanner.references(in: markup) {
        guard images.count < Self.maximumImages,
              let imagePath = Self.resolvePath(reference, relativeTo: documentPath),
              !seenPaths.contains(imagePath),
              let mediaType = Self.mediaType(forPath: imagePath),
              let data = try? archive.data(forPath: imagePath),
              !data.isEmpty else {
          continue
        }
        seenPaths.insert(imagePath)
        emittedOnPage += 1
        images.append(DocumentExtractedImage(
          pageNumber: pageNumber,
          kind: .embedded,
          data: data,
          mediaType: mediaType,
          suggestedFilename: DocumentImageNaming.embeddedFilename(
            pageNumber: pageNumber,
            index: emittedOnPage,
            fileExtension: DocumentImageNaming.fileExtension(forMediaType: mediaType)
          )
        ))
      }
    }
    return DocumentImageExtractionResult(images: images, pageTexts: pageTexts)
  }

  static func packagePath(in archive: MinimalZipArchive) throws -> String? {
    guard archive.contains(path: containerPath) else {
      return nil
    }
    let container = try archive.data(forPath: containerPath)
    guard let fullPath = EPUBContainerDocument.rootfilePath(data: container) else {
      return nil
    }
    // `full-path` is relative to the archive root, not to container.xml.
    return resolvePath(fullPath, relativeTo: "")
  }

  /// Resolves a document-relative reference to an archive path. Returns nil for
  /// external references (absolute URLs, `data:`) and empty targets.
  static func resolvePath(_ reference: String, relativeTo documentPath: String) -> String? {
    var value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fragment = value.firstIndex(of: "#") {
      value = String(value[..<fragment])
    }
    if let query = value.firstIndex(of: "?") {
      value = String(value[..<query])
    }
    guard !value.isEmpty,
          !value.contains("://"),
          !value.lowercased().hasPrefix("data:"),
          !value.lowercased().hasPrefix("mailto:") else {
      return nil
    }
    let decoded = value.removingPercentEncoding ?? value
    // A leading slash addresses the archive root, not the container root.
    var components = decoded.hasPrefix("/")
      ? []
      : documentPath.split(separator: "/").dropLast().map(String.init)
    for component in decoded.split(separator: "/") {
      switch component {
      case ".":
        continue
      case "..":
        if !components.isEmpty {
          components.removeLast()
        }
      default:
        components.append(String(component))
      }
    }
    return components.isEmpty ? nil : components.joined(separator: "/")
  }

  /// EPUB content documents are required to be UTF-8 or UTF-16.
  static func decodeText(_ data: Data) -> String? {
    String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
  }

  static func mediaType(forPath path: String) -> String? {
    switch (path as NSString).pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    default: return nil
    }
  }
}

/// `META-INF/container.xml`, reduced to the package document it points at.
enum EPUBContainerDocument {
  static func rootfilePath(data: Data) -> String? {
    let collector = EPUBXMLCollector(elements: ["rootfile"])
    let parser = XMLParser(data: data)
    parser.delegate = collector
    parser.shouldProcessNamespaces = false
    guard parser.parse() else {
      return nil
    }
    return collector.elements.first?["full-path"]
  }
}

/// The OPF package document, reduced to the manifest hrefs and the spine order.
struct EPUBPackageDocument: Equatable {
  var hrefByItemId: [String: String]
  var spineItemIds: [String]

  static func parse(data: Data) throws -> EPUBPackageDocument {
    let collector = EPUBXMLCollector(elements: ["item", "itemref"])
    let parser = XMLParser(data: data)
    parser.delegate = collector
    parser.shouldProcessNamespaces = false
    guard parser.parse() else {
      throw DocumentConversionError.failed("EPUB package document is not parseable XML")
    }
    var hrefByItemId: [String: String] = [:]
    var spineItemIds: [String] = []
    for element in collector.elements {
      switch element[EPUBXMLCollector.elementNameKey] {
      case "item":
        if let id = element["id"], let href = element["href"] {
          hrefByItemId[id] = href
        }
      case "itemref":
        if let idref = element["idref"] {
          spineItemIds.append(idref)
        }
      default:
        continue
      }
    }
    return EPUBPackageDocument(hrefByItemId: hrefByItemId, spineItemIds: spineItemIds)
  }
}

/// Collects the attributes of the named elements in document order. Element
/// names are compared without their namespace prefix, since EPUB packages are
/// written both with and without one.
final class EPUBXMLCollector: NSObject, XMLParserDelegate {
  static let elementNameKey = "__element"

  private let wanted: Set<String>
  private(set) var elements: [[String: String]] = []

  init(elements wanted: Set<String>) {
    self.wanted = wanted
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String]
  ) {
    let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
    guard wanted.contains(localName) else {
      return
    }
    var element = attributes
    element[Self.elementNameKey] = localName
    elements.append(element)
  }
}

/// Finds `<img src>` and SVG `<image href/xlink:href>` targets in document
/// order. A tolerant scan is deliberate: EPUB content documents are XHTML in
/// principle but frequently ship with markup a strict parser rejects.
enum HTMLImageReferenceScanner {
  static func references(in markup: String) -> [String] {
    guard let tagPattern = try? NSRegularExpression(
      pattern: "<(?:image|img)\\b[^>]*>",
      options: [.caseInsensitive]
    ), let attributePattern = try? NSRegularExpression(
      pattern: "(?:xlink:href|href|src)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
      options: [.caseInsensitive]
    ) else {
      return []
    }
    let text = markup as NSString
    let fullRange = NSRange(location: 0, length: text.length)
    return tagPattern.matches(in: markup, range: fullRange).compactMap { tagMatch in
      let tag = text.substring(with: tagMatch.range)
      let tagRange = NSRange(location: 0, length: (tag as NSString).length)
      guard let attribute = attributePattern.firstMatch(in: tag, range: tagRange) else {
        return nil
      }
      let value = (tag as NSString)
      for group in 1..<attribute.numberOfRanges where attribute.range(at: group).location != NSNotFound {
        return value.substring(with: attribute.range(at: group))
      }
      return nil
    }
  }
}

/// Strips markup so spine documents can be matched against note titles.
enum HTMLTextExtraction {
  /// Elements whose text content is markup machinery rather than prose.
  private static let opaqueElements = ["script", "style"]

  static func plainText(_ markup: String) -> String {
    var result = ""
    result.reserveCapacity(markup.count)
    var insideTag = false
    var openOpaqueElement: String?
    var index = markup.startIndex
    while index < markup.endIndex {
      let character = markup[index]
      if character == "<" {
        if let element = openOpaqueElement {
          if hasPrefix("</\(element)", in: markup, at: index) {
            openOpaqueElement = nil
          }
        } else if let element = opaqueElements.first(where: {
          hasPrefix("<\($0)", in: markup, at: index)
        }) {
          openOpaqueElement = element
        }
        insideTag = true
        result.append(" ")
        index = markup.index(after: index)
        continue
      }
      if character == ">" {
        insideTag = false
        index = markup.index(after: index)
        continue
      }
      if !insideTag, openOpaqueElement == nil {
        result.append(character)
      }
      index = markup.index(after: index)
    }
    return decodeEntities(result)
  }

  /// Case-insensitive prefix comparison over a bounded window, so scanning a
  /// long document stays linear.
  private static func hasPrefix(_ prefix: String, in text: String, at start: String.Index) -> Bool {
    var cursor = start
    for expected in prefix {
      guard cursor < text.endIndex,
            String(text[cursor]).lowercased() == String(expected).lowercased() else {
        return false
      }
      cursor = text.index(after: cursor)
    }
    return true
  }

  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else {
      return text
    }
    var result = ""
    result.reserveCapacity(text.count)
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index] == "&",
            let end = text[index...].prefix(12).firstIndex(of: ";") else {
        result.append(text[index])
        index = text.index(after: index)
        continue
      }
      let entity = String(text[text.index(after: index)..<end])
      result.append(replacement(forEntity: entity) ?? String(text[index...end]))
      index = text.index(after: end)
    }
    return result
  }

  private static func replacement(forEntity entity: String) -> String? {
    switch entity.lowercased() {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos": return "'"
    case "nbsp": return " "
    default:
      break
    }
    guard entity.hasPrefix("#") else {
      return nil
    }
    let digits = entity.dropFirst()
    let scalarValue: UInt32?
    if digits.first == "x" || digits.first == "X" {
      scalarValue = UInt32(digits.dropFirst(), radix: 16)
    } else {
      scalarValue = UInt32(digits, radix: 10)
    }
    guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else {
      return nil
    }
    return String(Character(scalar))
  }
}
