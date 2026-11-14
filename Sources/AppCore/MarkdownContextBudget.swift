/// Helpers for callers requesting explicitly bounded text previews. Chat
/// context uses complete source text by default. Byte limits here are application
/// preview sizes, not model token limits.

/// Returns the longest prefix whose UTF-8 encoding is at most `limit` bytes.
/// The cut is backed up to a scalar boundary so a multi-byte encoding is
/// never split.
func utf8Prefix(_ value: String, limit: Int) -> String {
  guard limit > 0 else { return "" }
  let utf8 = value.utf8
  guard utf8.count > limit else { return value }
  var end = utf8.index(utf8.startIndex, offsetBy: limit)
  while end > utf8.startIndex, String.Index(end, within: value.unicodeScalars) == nil {
    end = utf8.index(before: end)
  }
  guard let scalarEnd = String.Index(end, within: value.unicodeScalars) else { return "" }
  return String(value.unicodeScalars[..<scalarEnd])
}

/// Joins `heading` and `sections` with horizontal-rule separators while
/// keeping the result within `limitBytes` of UTF-8. Separator bytes count
/// against the budget, and assembly stops after the first section that no
/// longer fits completely.
func boundedMarkdownContext(heading: String, sections: [String], limitBytes: Int) -> String {
  var context = utf8Prefix(heading, limit: limitBytes)
  guard context.utf8.count == heading.utf8.count else { return context }
  for body in sections {
    let remaining = limitBytes - context.utf8.count
    guard remaining > 0 else { break }
    let section = "\n\n---\n\n" + body
    let fitted = utf8Prefix(section, limit: remaining)
    context += fitted
    if fitted.utf8.count < section.utf8.count { break }
  }
  return context
}
