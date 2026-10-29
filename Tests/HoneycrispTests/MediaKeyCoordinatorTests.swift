import Foundation
import MediaPlayer
import XCTest
@testable import Honeycrisp

@MainActor
final class MediaKeyCoordinatorTests: XCTestCase {

    func testSetupRegistersTargetsIdempotently() {
        let coordinator = MediaKeyCoordinator.shared
        coordinator.setup()
        coordinator.setup() // second call should not crash or duplicate
        XCTAssertTrue(MPRemoteCommandCenter.shared().playCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled)
    }

    func testNowPlayingUpdateWhenIdleClearsNowPlayingInfo() {
        let coordinator = MediaKeyCoordinator.shared
        coordinator.updateNowPlaying(state: .idle, reader: nil)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
}
