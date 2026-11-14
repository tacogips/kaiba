import XCTest
@testable import AppCore

final class NotebookDraftIdentityMatcherTests: XCTestCase {
  func testInsertsAndDeletesAnchorFollowingSections() {
    XCTAssertEqual(match(["A", "B", "C"], ["Edited A", "New", "B", "C"]), [0, nil, 1, 2])
    XCTAssertEqual(match(["A", "B", "C"], ["A", "C"]), [0, 2])
    XCTAssertEqual(match(["A", "B", "C"], ["Edited A", "Edited B", "C"]), [0, 1, 2])
  }

  func testSplitsAndMergesKeepTheFirstEditedSection() {
    XCTAssertEqual(match(["A", "B"], ["First half", "Second half", "B"]), [0, nil, 1])
    XCTAssertEqual(match(["A", "B", "C"], ["Merged A and B", "C"]), [0, 2])
  }

  func testMovedUnchangedBodiesKeepIDsAndDuplicateTiesFavorTheirPositions() {
    XCTAssertEqual(match(["A", "B", "C"], ["C", "A", "B"]), [2, 0, 1])
    XCTAssertEqual(match(["Same", "Same", "Tail"], ["Changed", "Same", "Tail"]), [0, 1, 2])
    XCTAssertEqual(match(["Same", "Same", "Tail"], ["Same", "Changed", "Tail"]), [0, 1, 2])
  }

  func testAllNewOrEmptySectionsAndBoundedLargeFallback() {
    XCTAssertEqual(match([], ["A", ""]), [nil, nil])
    XCTAssertEqual(match(["A", "B"], ["Changed A", "Changed B"]), [0, 1])
    let old = (0..<2100).map { "Note \($0)" }
    var new = old; new.insert("Inserted", at: 1000)
    let matches = match(old, new)
    XCTAssertNil(matches[1000])
    XCTAssertEqual(matches[1001], 1000)
    XCTAssertEqual(matches.last, 2099)
  }

  private func match(_ old: [String], _ new: [String]) -> [Int?] {
    NotebookDraftIdentityMatcher.matchingOldIndices(oldBodies: old, newBodies: new)
  }
}
