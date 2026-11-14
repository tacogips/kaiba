import Foundation

public enum NoteTitleDerivation {
  public static let fallbackTitleLimit = 120

  public static func title(from bodyMarkdown: String) -> String? {
    let lines = scannableLines(in: bodyMarkdown)
    if let headingTitle = lines.compactMap(markdownHeadingTitle).first {
      return headingTitle
    }
    return lines.compactMap(firstLineTitle).first
  }

  public static func fallbackTitle(from bodyMarkdown: String, defaultTitle: String = "Untitled") -> String {
    title(from: bodyMarkdown) ?? defaultTitle
  }

  private static func markdownHeadingTitle(_ line: String) -> String? {
    guard leadingSpaceCount(in: line) <= 3 else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var hashCount = 0
    for character in trimmed {
      guard character == "#" else {
        break
      }
      hashCount += 1
    }
    guard (1...6).contains(hashCount),
          trimmed.dropFirst(hashCount).first?.isWhitespace == true
    else {
      return nil
    }
    let rawTitle = trimmed.dropFirst(hashCount).trimmingCharacters(in: .whitespacesAndNewlines)
    let title = strippingClosingATXHashes(from: rawTitle)
    return cappedTitle(title)
  }

  private static func firstLineTitle(_ line: String) -> String? {
    guard leadingSpaceCount(in: line) < 4 else {
      return nil
    }
    var title = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return nil
    }
    title = title.replacingOccurrences(
      of: #"^\s{0,3}>\s*"#,
      with: "",
      options: .regularExpression
    )
    title = title.replacingOccurrences(
      of: #"^\s{0,3}([-+*]|\d+[.)])\s+"#,
      with: "",
      options: .regularExpression
    )
    title = title.replacingOccurrences(
      of: #"^#{1,6}\s+"#,
      with: "",
      options: .regularExpression
    )
    title = strippingClosingATXHashes(from: title)
    return cappedTitle(title)
  }

  private static func cappedTitle(_ title: String) -> String? {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return nil
    }
    return String(normalized.prefix(fallbackTitleLimit))
  }

  private static func scannableLines(in bodyMarkdown: String) -> [String] {
    var lines: [String] = []
    var fence: MarkdownFence?
    for line in bodyMarkdown.components(separatedBy: .newlines) {
      if let activeFence = fence {
        if activeFence.isClosed(by: line) {
          fence = nil
        }
        continue
      }
      if let openingFence = MarkdownFence(openingLine: line) {
        fence = openingFence
        continue
      }
      lines.append(line)
    }
    return lines
  }

  private static func strippingClosingATXHashes(from title: String) -> String {
    title.replacingOccurrences(
      of: #"\s+#+\s*$"#,
      with: "",
      options: .regularExpression
    )
  }

  private static func leadingSpaceCount(in line: String) -> Int {
    var count = 0
    for character in line {
      guard character == " " else {
        break
      }
      count += 1
    }
    return count
  }
}

private struct MarkdownFence {
  var marker: Character
  var count: Int

  init?(openingLine: String) {
    guard NoteTitleDerivation.leadingSpaceCountForFence(in: openingLine) <= 3 else {
      return nil
    }
    let trimmed = openingLine.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "`" || first == "~" else {
      return nil
    }
    let markerCount = trimmed.prefix { $0 == first }.count
    guard markerCount >= 3 else {
      return nil
    }
    marker = first
    count = markerCount
  }

  func isClosed(by line: String) -> Bool {
    guard NoteTitleDerivation.leadingSpaceCountForFence(in: line) <= 3 else {
      return false
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let markerCount = trimmed.prefix { $0 == marker }.count
    guard markerCount >= count else {
      return false
    }
    return trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
  }
}

extension NoteTitleDerivation {
  fileprivate static func leadingSpaceCountForFence(in line: String) -> Int {
    leadingSpaceCount(in: line)
  }
}
