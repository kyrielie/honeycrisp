import AppKit
import Foundation
import MediaPlayer

/// Coordinates macOS system media keys (Play/Pause, Next Track, Previous Track,
/// Bluetooth/headset remotes) with `SpeechCoordinator` via `MPRemoteCommandCenter`
/// and updates macOS Now Playing info via `MPNowPlayingInfoCenter`.
@MainActor
final class MediaKeyCoordinator {
    static let shared = MediaKeyCoordinator()

    private var targetsRegistered = false
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

    private init() {}

    nonisolated func setup() {
        Task { @MainActor in
            guard !targetsRegistered else { return }
            targetsRegistered = true

            commandCenter.playCommand.isEnabled = true
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                return DispatchQueue.main.sync {
                    self.handlePlay()
                }
            }

            commandCenter.pauseCommand.isEnabled = true
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                return DispatchQueue.main.sync {
                    self.handlePause()
                }
            }

            commandCenter.togglePlayPauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                return DispatchQueue.main.sync {
                    self.handleTogglePlayPause()
                }
            }

            commandCenter.nextTrackCommand.isEnabled = true
            commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                return DispatchQueue.main.sync {
                    self.handleNextTrack()
                }
            }

            commandCenter.previousTrackCommand.isEnabled = true
            commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                return DispatchQueue.main.sync {
                    self.handlePreviousTrack()
                }
            }
        }
    }

    private func currentReader() -> ReaderViewController? {
        (NSApp.delegate as? AppDelegate)?.readerVC()
    }

    private func handlePlay() -> MPRemoteCommandHandlerStatus {
        guard let reader = currentReader() else { return .noActionableNowPlayingItem }
        if reader.speechCoordinator.playbackState.isPaused {
            reader.speechCoordinator.resume()
            return .success
        } else if reader.speechCoordinator.playbackState.isIdle {
            reader.speakCurrentLocation()
            return .success
        }
        return .success
    }

    private func handlePause() -> MPRemoteCommandHandlerStatus {
        guard let reader = currentReader(), reader.speechCoordinator.playbackState.isPlaying else {
            return .noActionableNowPlayingItem
        }
        reader.speechCoordinator.pause()
        return .success
    }

    private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
        guard let reader = currentReader() else { return .noActionableNowPlayingItem }
        reader.speechCoordinator.togglePlayPause {
            reader.speakCurrentLocation()
        }
        return .success
    }

    private func handleNextTrack() -> MPRemoteCommandHandlerStatus {
        guard let reader = currentReader(), !reader.speechCoordinator.playbackState.isIdle else {
            return .noActionableNowPlayingItem
        }
        reader.speechCoordinator.skipNext()
        return .success
    }

    private func handlePreviousTrack() -> MPRemoteCommandHandlerStatus {
        guard let reader = currentReader(), !reader.speechCoordinator.playbackState.isIdle else {
            return .noActionableNowPlayingItem
        }
        reader.speechCoordinator.skipPrevious()
        return .success
    }

    /// Updates Now Playing metadata for macOS Control Center and widgets.
    func updateNowPlaying(state: SpeechCoordinator.PlaybackState, reader: ReaderViewController?) {
        guard let reader, !state.isIdle else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        if let title = reader.currentBookTitle {
            info[MPMediaItemPropertyTitle] = title
        }
        if let chapter = reader.currentChapterTitle {
            info[MPMediaItemPropertyArtist] = chapter
        } else {
            info[MPMediaItemPropertyArtist] = "Honeycrisp"
        }

        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        nowPlayingInfoCenter.nowPlayingInfo = info
    }
}
