/// Keeps untouched note identities anchored while a continuous source buffer
/// inserts, splits, merges, or removes sections. Edited sections retain IDs in
/// order within the gaps between exact-body anchors. Entirely rewritten or
/// identical duplicate sections are inherently ambiguous without source IDs.
enum NotebookDraftIdentityMatcher {
  static func matchingOldIndices(oldBodies: [String], newBodies: [String]) -> [Int?] {
    var interned: [String: Int] = [:]
    func intern(_ body: String) -> Int {
      if let existing = interned[body] { return existing }
      let index = interned.count
      interned[body] = index
      return index
    }
    let old = oldBodies.map(intern), new = newBodies.map(intern)
    let anchors = longestCommonSubsequence(old: old, new: new)
    var matches = [Int?](repeating: nil, count: new.count)
    var used = Set<Int>()
    for anchor in anchors { matches[anchor.new] = anchor.old; used.insert(anchor.old) }

    // Preserve exact-body moves as well as in-order anchors. Prefer a duplicate
    // in its original position before consuming another indistinguishable note.
    var unmatched: [Int: [Int]] = [:]
    for index in old.indices where !used.contains(index) { unmatched[old[index], default: []].append(index) }
    for index in new.indices where matches[index] == nil {
      guard var candidates = unmatched[new[index]], !candidates.isEmpty else { continue }
      let candidate = candidates.firstIndex(of: index) ?? 0
      let previous = candidates.remove(at: candidate)
      unmatched[new[index]] = candidates
      matches[index] = previous
      used.insert(previous)
    }

    var previousOld = -1, previousNew = -1
    for anchor in anchors + [(old: old.count, new: new.count)] {
      let oldGap = ((previousOld + 1)..<anchor.old).filter { !used.contains($0) }
      let newGap = ((previousNew + 1)..<anchor.new).filter { matches[$0] == nil }
      for (oldIndex, newIndex) in zip(oldGap, newGap) {
        matches[newIndex] = oldIndex
        used.insert(oldIndex)
      }
      previousOld = anchor.old; previousNew = anchor.new
    }
    return matches
  }

  private static func longestCommonSubsequence(old: [Int], new: [Int]) -> [(old: Int, new: Int)] {
    guard !old.isEmpty, !new.isEmpty else { return [] }
    // Bound working memory even for notebooks imported outside the writer's
    // section limit. The caller's exact-body pass still preserves every
    // unchanged section if this bound rules out an LCS table.
    guard old.count <= 4_000_000 / new.count else { return [] }
    let width = new.count + 1
    let weight = Int64(max(old.count, new.count) * min(old.count, new.count) + 1)
    var scores = [Int64](repeating: 0, count: (old.count + 1) * width)
    for oldIndex in old.indices.reversed() {
      for newIndex in new.indices.reversed() {
        let offset = oldIndex * width + newIndex
        let skipped = max(scores[offset + width], scores[offset + 1])
        let matched = old[oldIndex] == new[newIndex]
          ? scores[offset + width + 1] + weight - Int64(abs(oldIndex - newIndex)) : -1
        scores[offset] = max(skipped, matched)
      }
    }
    var oldIndex = 0, newIndex = 0
    var result: [(old: Int, new: Int)] = []
    while oldIndex < old.count, newIndex < new.count {
      let offset = oldIndex * width + newIndex
      let matched = scores[offset + width + 1] + weight - Int64(abs(oldIndex - newIndex))
      if old[oldIndex] == new[newIndex], scores[offset] == matched {
        result.append((old: oldIndex, new: newIndex)); oldIndex += 1; newIndex += 1
      } else if scores[offset + width] >= scores[offset + 1] {
        oldIndex += 1
      } else { newIndex += 1 }
    }
    return result
  }
}
