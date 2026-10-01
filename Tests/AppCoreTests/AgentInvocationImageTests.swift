import Foundation
@testable import AppCore
import XCTest

final class AgentInvocationImageTests: XCTestCase {
  func testTransportableImageWithinAllowedMediaTypeAndSize() {
    let image = AgentInvocationImage(data: Data(repeating: 1, count: 10), mediaType: "image/png")

    XCTAssertTrue(image.isTransportable)
  }

  func testUnsupportedMediaTypeIsNotTransportable() {
    let image = AgentInvocationImage(data: Data([1]), mediaType: "image/tiff")

    XCTAssertFalse(image.isTransportable)
  }

  func testImageOverMaximumSizeIsNotTransportable() {
    let image = AgentInvocationImage(
      data: Data(repeating: 1, count: AgentInvocationImage.maximumBytes + 1),
      mediaType: "image/jpeg"
    )

    XCTAssertFalse(image.isTransportable)
  }

  func testEmptyImageIsNotTransportable() {
    let image = AgentInvocationImage(data: Data(), mediaType: "image/jpeg")

    XCTAssertFalse(image.isTransportable)
  }

  func testDroppingImagesWithoutImagesReturnsUnchangedRequest() {
    let request = makeRequest(contextMarkdown: "ctx")

    XCTAssertEqual(request.droppingImagesWithNotice(), request)
  }

  func testDroppingImagesAddsNoticeAfterContext() {
    let request = makeRequest(contextMarkdown: "ctx", images: [makeImage()])

    let result = request.droppingImagesWithNotice()

    XCTAssertTrue(result.images.isEmpty)
    XCTAssertEqual(
      result.contextMarkdown,
      "ctx\n\n\(AgentInvocationRequest.imageFallbackNotice)"
    )
  }

  func testDroppingImagesWithNilContextUsesNoticeAlone() {
    let request = makeRequest(contextMarkdown: nil, images: [makeImage()])

    let result = request.droppingImagesWithNotice()

    XCTAssertTrue(result.images.isEmpty)
    XCTAssertEqual(result.contextMarkdown, AgentInvocationRequest.imageFallbackNotice)
  }

  func testToolLoopModelRequestDefaultsImageFields() {
    let request = ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])

    XCTAssertEqual(request.images, [])
    XCTAssertNil(request.imageMessageIndex)
  }

  private func makeRequest(
    contextMarkdown: String?,
    images: [AgentInvocationImage] = []
  ) -> AgentInvocationRequest {
    AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "system",
      turns: [AgentInvocationTurn(role: .user, markdown: "question")],
      contextMarkdown: contextMarkdown,
      images: images
    )
  }

  private func makeImage() -> AgentInvocationImage {
    AgentInvocationImage(data: Data([1]), mediaType: "image/png")
  }
}
