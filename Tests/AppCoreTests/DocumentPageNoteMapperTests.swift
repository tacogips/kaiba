import Foundation
@testable import AppCore
import XCTest

final class DocumentPageNoteMapperTests: XCTestCase {
  func testMapsPagesToTheNoteWhoseHeadingStartsThem() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: [
        "Chapter One\nopening body",
        "still chapter one",
        "Chapter Two\nsecond body",
        "trailing body"
      ],
      noteTitles: ["Chapter One", "Chapter Two"]
    )
    XCTAssertEqual(mapping, [0, 0, 1, 1])
  }

  func testFirstNoteOwnsPagesBeforeAnyMatch() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["cover page", "front matter", "Chapter One begins"],
      noteTitles: ["Preface", "Chapter One"]
    )
    XCTAssertEqual(mapping, [0, 0, 1])
  }

  func testMatchingNeverMovesBackwards() {
    // "Chapter C" also appears on page 0, but a later note may not start
    // before an earlier one did.
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["intro mentioning Chapter C", "Chapter B", "middle", "Chapter C"],
      noteTitles: ["Intro", "Chapter B", "Chapter C"]
    )
    XCTAssertEqual(mapping, [0, 1, 1, 2])
  }

  func testUnmatchedNoteKeepsItsPagesWithThePreviousNote() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["Alpha", "middle", "Gamma"],
      noteTitles: ["Alpha", "Beta never printed", "Gamma"]
    )
    XCTAssertEqual(mapping, [0, 0, 2])
  }

  func testMatchesTitlesWrappedAcrossExtractedLines() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["cover", "The Long\nChapter   Title\nbody text"],
      noteTitles: ["Cover", "The Long Chapter Title"]
    )
    XCTAssertEqual(mapping, [0, 1])
  }

  func testMatchesTitlesCarryingMarkdownInlineMarkup() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["cover", "Reading the config file now"],
      noteTitles: ["Cover", "Reading the **config** `file`"]
    )
    XCTAssertEqual(mapping, [0, 1])
  }

  func testMatchesTitlesContainingLinks() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["cover", "See the appendix for details"],
      noteTitles: ["Cover", "See the [appendix](appendix.md) for details"]
    )
    XCTAssertEqual(mapping, [0, 1])
  }

  func testShortAndMissingTitlesNeverMatch() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["ab page", "untitled page", "Gamma"],
      noteTitles: ["Alpha", "ab", nil, "Gamma"]
    )
    XCTAssertEqual(mapping, [0, 0, 3])
  }

  func testTiesResolveToTheLastNoteStartingOnAPage() {
    let mapping = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: ["Alpha then Beta on one page", "later"],
      noteTitles: ["Alpha", "Beta"]
    )
    XCTAssertEqual(mapping, [1, 1])
  }

  func testEmptyInputsProduceEmptyOrZeroMapping() {
    XCTAssertEqual(
      DocumentPageNoteMapper.noteIndexByPage(pageTexts: [], noteTitles: ["Alpha"]),
      []
    )
    XCTAssertEqual(
      DocumentPageNoteMapper.noteIndexByPage(pageTexts: ["one", "two"], noteTitles: []),
      [0, 0]
    )
  }

  func testNormalizationCollapsesWhitespaceAndDropsMarkup() {
    XCTAssertEqual(
      DocumentPageNoteMapper.normalized("  ## **Big**\n\tTitle_here  "),
      "big titlehere"
    )
  }
}
