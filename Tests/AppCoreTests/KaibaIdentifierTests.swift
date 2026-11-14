import Foundation
@testable import AppCore
import XCTest

// The typed id wrappers must stay transparent on the wire: a note id encodes
// as the bare string it always was, so stored rows and GraphQL payloads are
// unchanged by the newtypes.

final class KaibaIdentifierTests: XCTestCase {
  func testIdentifierEncodesAsABareString() throws {
    let payload = try JSONEncoder().encode(NoteID("note-1"))

    XCTAssertEqual(String(bytes: payload, encoding: .utf8), "\"note-1\"")
  }

  func testIdentifierDecodesFromABareString() throws {
    let decoded = try JSONDecoder().decode(NotebookID.self, from: Data("\"nb-7\"".utf8))

    XCTAssertEqual(decoded, NotebookID("nb-7"))
  }

  func testIdentifierEncodesInsideAContainingModel() throws {
    let user = NoteUser(userId: UserID("user-1"), displayName: "Ada", createdAt: "2026-01-01T00:00:00Z")

    let payload = try JSONEncoder().encode(user)
    let object = try JSONValue(parsing: payload)

    XCTAssertEqual(object["userId"]?.asString, "user-1")
  }

  func testValidatingInitializerRejectsBlankText() {
    XCTAssertNil(NoteID(validating: "   "))
    XCTAssertEqual(NoteID(validating: "  note-2 "), NoteID("note-2"))
  }

  func testDescriptionAndInterpolationUseTheRawValue() {
    XCTAssertEqual("\(NoteID("note-3"))", "note-3")
  }

  func testIdentifiersSortByRawValue() {
    let sorted = [NoteID("c"), NoteID("a"), NoteID("b")].sorted()

    XCTAssertEqual(sorted, [NoteID("a"), NoteID("b"), NoteID("c")])
  }
}
