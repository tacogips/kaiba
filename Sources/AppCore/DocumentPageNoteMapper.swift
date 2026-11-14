import Foundation

/// Maps source-document pages onto the notes that `MarkdownHeadingSplitter`
/// produced, so page captures and embedded images land on the note whose text
/// they belong to.
///
/// The markdown conversion loses page geometry, so the only reliable link left
/// is the note title: the heading a note starts with is normally printed on the
/// page where that section begins. Matching walks forward only (a later note
/// never starts before an earlier one), which keeps a repeated heading in a
/// running header from dragging notes backwards.
///
/// A page where the title stands alone on its own line outranks a page that
/// merely mentions it: cross-references and tables of contents quote later
/// headings inside running prose, and matching those would attribute a whole
/// section to the page that links to it.
public enum DocumentPageNoteMapper {
  /// Titles shorter than this never match; they produce too many false hits
  /// against ordinary page text.
  public static let minimumMatchableTitleLength = 3

  /// Returns, for each page, the index of the note that page belongs to.
  /// The result has one element per entry in `pageTexts`.
  public static func noteIndexByPage(pageTexts: [String], noteTitles: [String?]) -> [Int] {
    guard !pageTexts.isEmpty, !noteTitles.isEmpty else {
      return Array(repeating: 0, count: pageTexts.count)
    }
    let pages = pageTexts.map(NormalizedPage.init(text:))
    // Ties resolve to the last note starting on a page: when several headings
    // share one page, that page mostly shows the later section.
    var lastNoteStartingOnPage = Array(repeating: -1, count: pages.count)
    lastNoteStartingOnPage[0] = 0
    var searchFrom = 0
    for noteIndex in 1..<noteTitles.count {
      guard let needle = matchableTitle(noteTitles[noteIndex]),
            let page = startPage(for: needle, in: pages, from: searchFrom) else {
        continue
      }
      lastNoteStartingOnPage[page] = noteIndex
      searchFrom = page
    }

    var mapping = Array(repeating: 0, count: pages.count)
    var currentNote = 0
    for page in pages.indices {
      if lastNoteStartingOnPage[page] >= 0 {
        currentNote = lastNoteStartingOnPage[page]
      }
      mapping[page] = currentNote
    }
    return mapping
  }

  /// One page of extracted text, kept in both the forms matching needs: whole
  /// lines to recognise a standalone heading, and one collapsed run to survive
  /// a heading that the extractor wrapped across lines.
  private struct NormalizedPage {
    var lines: Set<String>
    var collapsed: String

    init(text: String) {
      self.lines = Set(
        text.split(whereSeparator: \.isNewline)
          .map { normalized(String($0)) }
          .filter { !$0.isEmpty }
      )
      self.collapsed = normalized(text)
    }
  }

  private static func startPage(
    for needle: String,
    in pages: [NormalizedPage],
    from searchFrom: Int
  ) -> Int? {
    let range = searchFrom..<pages.count
    return range.first { pages[$0].lines.contains(needle) }
      ?? range.first { pages[$0].collapsed.contains(needle) }
  }

  private static func matchableTitle(_ title: String?) -> String? {
    guard let title else {
      return nil
    }
    let needle = normalized(title)
    return needle.count >= minimumMatchableTitleLength ? needle : nil
  }

  /// Lowercases, drops markdown inline markup, and collapses every whitespace
  /// run to a single space. Extracted PDF text wraps headings across lines, so
  /// comparison only works once both sides are on one line.
  static func normalized(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    var pendingSpace = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character.isWhitespace {
        pendingSpace = !result.isEmpty
        index = text.index(after: index)
        continue
      }
      if character == "*" || character == "`" || character == "_" || character == "#" {
        index = text.index(after: index)
        continue
      }
      if character == "[", let link = linkLabel(in: text, from: index) {
        if pendingSpace {
          result.append(" ")
          pendingSpace = false
        }
        result += normalized(link.label)
        index = link.end
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(Character(character.lowercased()))
      index = text.index(after: index)
    }
    return result
  }

  /// Parses `[label](destination)` starting at `start`, returning the label and
  /// the index just past the closing parenthesis. Nested brackets are not
  /// supported; such a link is left as literal text.
  private static func linkLabel(
    in text: String,
    from start: String.Index
  ) -> (label: String, end: String.Index)? {
    guard let labelEnd = text[start...].firstIndex(of: "]") else {
      return nil
    }
    let afterLabel = text.index(after: labelEnd)
    guard afterLabel < text.endIndex, text[afterLabel] == "(",
          let destinationEnd = text[afterLabel...].firstIndex(of: ")") else {
      return nil
    }
    let label = String(text[text.index(after: start)..<labelEnd])
    return (label, text.index(after: destinationEnd))
  }
}
