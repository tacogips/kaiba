import Foundation

/// Splits one converted markdown document into notebook pages (design decision
/// DI2/K11): one section per H1 heading, falling back to H2 when the document
/// has no H1, and a single page when it has no headings at all. Content before
/// the first split heading becomes the first page. Headings inside fenced code
/// blocks never split. Sections above `maximumSectionBytes` split recursively
/// at the next heading level, then at paragraph boundaries.
public enum MarkdownHeadingSplitter {
  /// Safety margin under the 512 KiB GraphQL document cap.
  public static let maximumSectionBytes = 400 * 1024

  public static func split(markdown: String) -> [NotePageDraft] {
    let sections = splitSections(markdown: markdown)
    return sections.enumerated().map { index, body in
      NotePageDraft(bodyMarkdown: body, noteNumber: index + 1)
    }
  }

  static func splitSections(markdown: String) -> [String] {
    let lines = markdown.components(separatedBy: "\n")
    let headingLevels = Set(headings(in: lines).map(\.level))
    let splitLevel = headingLevels.contains(1) ? 1 : (headingLevels.contains(2) ? 2 : nil)
    let sections: [String]
    if let splitLevel {
      sections = splitLines(lines, at: splitLevel)
    } else {
      sections = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? [] : [markdown]
    }
    return sections.flatMap { enforceSizeLimit(on: $0, belowLevel: splitLevel ?? 6) }
  }

  struct Heading: Equatable {
    var lineIndex: Int
    var level: Int
  }

  /// ATX headings outside fenced code blocks.
  static func headings(in lines: [String]) -> [Heading] {
    var results: [Heading] = []
    var fenceDelimiter: String?
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let delimiter = fenceDelimiter {
        if isClosingFence(trimmed, opening: delimiter) {
          fenceDelimiter = nil
        }
        continue
      }
      if let delimiter = openingFenceDelimiter(trimmed) {
        fenceDelimiter = delimiter
        continue
      }
      if let level = atxHeadingLevel(trimmed) {
        results.append(Heading(lineIndex: index, level: level))
      }
    }
    return results
  }

  private static func openingFenceDelimiter(_ trimmed: String) -> String? {
    for character in ["`", "~"] where trimmed.hasPrefix(String(repeating: character, count: 3)) {
      let run = trimmed.prefix { String($0) == character }
      return String(run)
    }
    return nil
  }

  private static func isClosingFence(_ trimmed: String, opening: String) -> Bool {
    guard let character = opening.first else {
      return false
    }
    let run = trimmed.prefix { $0 == character }
    return run.count >= opening.count && trimmed.allSatisfy { $0 == character }
  }

  private static func atxHeadingLevel(_ trimmed: String) -> Int? {
    let marks = trimmed.prefix { $0 == "#" }
    guard (1...6).contains(marks.count) else {
      return nil
    }
    let rest = trimmed.dropFirst(marks.count)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else {
      return nil
    }
    return marks.count
  }

  private static func splitLines(_ lines: [String], at level: Int) -> [String] {
    let starts = headings(in: lines).filter { $0.level == level }.map(\.lineIndex)
    guard !starts.isEmpty else {
      let whole = lines.joined(separator: "\n")
      return whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [whole]
    }
    var sections: [String] = []
    let preamble = lines[..<starts[0]].joined(separator: "\n")
    if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append(preamble)
    }
    for (position, start) in starts.enumerated() {
      let end = position + 1 < starts.count ? starts[position + 1] : lines.count
      sections.append(lines[start..<end].joined(separator: "\n"))
    }
    return sections
  }

  private static func enforceSizeLimit(on section: String, belowLevel: Int) -> [String] {
    guard section.utf8.count > maximumSectionBytes else {
      return [section]
    }
    let lines = section.components(separatedBy: "\n")
    let deeperLevels = headings(in: lines).map(\.level).filter { $0 > belowLevel }
    if let nextLevel = deeperLevels.min() {
      return splitLines(lines, at: nextLevel)
        .flatMap { enforceSizeLimit(on: $0, belowLevel: nextLevel) }
    }
    return splitAtParagraphs(section)
  }

  /// Last-resort split at blank-line boundaries, packing paragraphs into
  /// chunks under the limit. A single oversized paragraph stays intact rather
  /// than being corrupted mid-construct.
  private static func splitAtParagraphs(_ section: String) -> [String] {
    let paragraphs = section.components(separatedBy: "\n\n")
    var chunks: [String] = []
    var current = ""
    for paragraph in paragraphs {
      let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
      if candidate.utf8.count > maximumSectionBytes, !current.isEmpty {
        chunks.append(current)
        current = paragraph
      } else {
        current = candidate
      }
    }
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      chunks.append(current)
    }
    return chunks.isEmpty ? [section] : chunks
  }
}
