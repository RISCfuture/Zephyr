import Foundation
import Testing

@testable import libZephyr

@Suite
struct ZephyrMarkTests {
  private static let frameCount = 24
  private static let revolution = ZephyrMark.badgeRevolution

  private func frame(at offsetSec: TimeInterval) -> Int {
    ZephyrMarkFilmstrip.frameIndex(
      at: Date(timeIntervalSinceReferenceDate: offsetSec),
      of: Self.frameCount
    )
  }

  @Test("A turn's frames run once round and land back where they started")
  func framesRunOnceRound() {
    let start = frame(at: 0)
    #expect(frame(at: Self.revolution) == start)
    #expect(frame(at: Self.revolution / 2) == start + Self.frameCount / 2)

    // A clock set before the reference date turns a remainder negative, and a
    // negative frame is a trap rather than a wrong pixel.
    let turn = stride(from: -Self.revolution, to: Self.revolution, by: Self.revolution / 100)
    #expect(turn.allSatisfy { (0..<Self.frameCount).contains(frame(at: $0)) })
  }
}
