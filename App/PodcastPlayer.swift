import PodcastCore
import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor final class PodcastPlayer: ObservableObject {
    @Published private(set) var episode: Episode?
    @Published private(set) var show: Podcast?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var speed: Float = 1
    @Published private(set) var sleepDeadline: Date?
    @Published private(set) var buffering = false
    var authorize: ((String, AccessEntry) -> Bool)?
    var onStarted: ((String) -> Void)?
    var onProgress: ((String, Double, Double, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onError: ((String) -> Void)?
    private var av = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var notifications: [NSObjectProtocol] = []
    private var session = ProgressSession()
    private var restoring = false
    @Published private(set) var wantsPlay = false
    private var interruptionRecovery = InterruptionRecovery()
    private var preferences = PlayerPreferences()
    private var sourceURL: URL?
    private var lastCheckpoint = Date.distantPast
    private var sleepTimer: Timer?
    private var artwork: MPMediaItemArtwork?
    private let audioSessionQueue = DispatchQueue(label: "org.quietcast.audio-session")
    private var audioActivationGeneration: UInt64 = 0
    private var activationPending = false
    init() {
        configureRemote()
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() } }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resetMediaServices() }
        })
    }
    func load(_ episode: Episode, show: Podcast, localURL: URL?, position: Double, preferences: PlayerPreferences, autoplay: Bool) {
        guard authorize?(episode.id, .playback) == true else { return }
        unload()
        self.episode = episode; self.show = show; self.preferences = preferences; self.speed = preferences.speed
        self.position = position; duration = episode.duration ?? 0; sourceURL = localURL ?? episode.audioURL
        updatePreferences(preferences)
        wantsPlay = autoplay; restoring = true; buffering = true
        let generation = session.switchTo(episode.id)
        let item = AVPlayerItem(url: sourceURL!); item.audioTimePitchAlgorithm = .spectral
        av.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.session.accepts(episodeID: episode.id, generation: generation) else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite && seconds > 0 { self.duration = seconds }
                    let target = self.duration > 0 ? min(position, max(0, self.duration - 0.2)) : position
                    self.av.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        Task { @MainActor in
                            guard let self, finished, self.session.accepts(episodeID: episode.id, generation: generation) else { return }
                            self.restoring = false; self.buffering = false; self.position = target
                            if self.wantsPlay { self.resume() }; self.publishNowPlaying()
                        }
                    }
                case .failed:
                    self.buffering = false; self.wantsPlay = false; self.isPlaying = false
                    self.onError?(item.error?.localizedDescription ?? "音频无法播放")
                default: break
                }
            }
        }
        playbackObserver = av.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.session.accepts(episodeID: episode.id, generation: generation) else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.buffering = self.wantsPlay && (self.restoring || self.activationPending || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                self.publishNowPlaying()
            }
        }
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.restoring, self.session.accepts(episodeID: episode.id, generation: generation), time.seconds.isFinite else { return }
                self.position = max(0, time.seconds)
                if let seconds = self.av.currentItem?.duration.seconds, seconds.isFinite && seconds > 0 { self.duration = seconds }
                if Date().timeIntervalSince(self.lastCheckpoint) >= 10 { self.save() }
                self.publishNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session.accepts(episodeID: episode.id, generation: generation) else { return }
                self.position = self.duration; self.isPlaying = false; self.wantsPlay = false; self.save(finished: true); self.onNext?()
            }
        }
        fetchArtwork(episode.artworkURL ?? show.artworkURL, episodeID: episode.id, generation: generation)
        publishNowPlaying()
    }
    func resume() {
        guard let episode, authorize?(episode.id, .playback) == true else { pause(); return }
        let wasAlreadyPlaying = isPlaying
        wantsPlay = true
        guard !restoring, !activationPending else { return }
        audioActivationGeneration &+= 1
        let activation = audioActivationGeneration
        activationPending = true; buffering = true
        // System audio-session negotiation can block for seconds. Keep it off the UI thread.
        audioSessionQueue.async { [weak self] in
            let result = Result {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
                try audio.setActive(true)
            }
            Task { @MainActor in
                guard let self, self.audioActivationGeneration == activation, self.episode?.id == episode.id, self.wantsPlay else { return }
                self.activationPending = false
                switch result {
                case .success:
                    if self.duration > 0 && self.position >= self.duration - 0.5 { self.seek(0) }
                    if !wasAlreadyPlaying { self.onStarted?(episode.id) }
                    self.av.playImmediately(atRate: self.speed); self.isPlaying = true; self.buffering = false; self.publishNowPlaying()
                case .failure(let error):
                    self.wantsPlay = false; self.isPlaying = false; self.buffering = false
                    self.onError?("音频会话失败：\(error.localizedDescription)")
                }
            }
        }
    }
    func pause() {
        audioActivationGeneration &+= 1; activationPending = false
        wantsPlay = false; interruptionRecovery.userPausedOrRouteLost()
        av.pause(); isPlaying = false; buffering = false; save(); publishNowPlaying()
        audioSessionQueue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func toggle() { isPlaying || wantsPlay ? pause() : resume() }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, let id = episode?.id, authorize?(id, .playback) == true else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        let generation = session.generation
        av.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.session.accepts(episodeID: id, generation: generation) else { return }
                self.position = target; self.save(); self.publishNowPlaying()
            }
        }
    }
    func skip(forward: Bool) { seek(position + (forward ? preferences.forwardSeconds : -preferences.backwardSeconds)) }
    func setSpeed(_ value: Float) { speed = min(3, max(0.75, value)); if isPlaying { av.rate = speed }; publishNowPlaying() }
    func updatePreferences(_ value: PlayerPreferences) {
        preferences = value; setSpeed(value.speed)
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: value.forwardSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: value.backwardSeconds)]
    }
    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if sleepDeadline != nil {
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let end = self.sleepDeadline, end <= Date() else { return }
                    self.pause(); self.sleepDeadline = nil; self.sleepTimer?.invalidate(); self.sleepTimer = nil
                }
            }
        }
    }
    func save(finished: Bool = false) {
        guard !restoring, let id = episode?.id, position.isFinite else { return }
        onProgress?(id, position, duration, finished); lastCheckpoint = Date()
    }
    func unload() {
        audioActivationGeneration &+= 1; activationPending = false
        save(); av.pause(); interruptionRecovery.userPausedOrRouteLost(); wantsPlay = false; isPlaying = false; restoring = false; buffering = false
        _ = session.switchTo(nil)
        if let timeObserver { av.removeTimeObserver(timeObserver); self.timeObserver = nil }
        statusObserver = nil; playbackObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        av.replaceCurrentItem(with: nil); episode = nil; show = nil; artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func interruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            audioActivationGeneration &+= 1; activationPending = false; buffering = false
            interruptionRecovery.began(wasPlaying: isPlaying || wantsPlay)
            av.pause(); isPlaying = false; wantsPlay = false; save(); publishNowPlaying()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let contentAllowed = episode.map { authorize?($0.id, .playback) == true } ?? false
            let shouldResume = interruptionRecovery.ended(systemAllowsResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume), contentAllowed: contentAllowed)
            if shouldResume { resume() }
        }
    }
    private func resetMediaServices() {
        guard let episode, let show else { av = AVPlayer(); return }
        let saved = position; let local = sourceURL?.isFileURL == true ? sourceURL : nil
        unload(); av = AVPlayer()
        load(episode, show: show, localURL: local, position: saved, preferences: preferences, autoplay: false)
        onError?("系统音频服务已重置，播放位置已保留，请点击播放继续。")
    }
    private func configureRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]; c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(forward: true) }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(forward: false) }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onNext?() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onPrevious?() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime; Task { @MainActor in self?.seek(seconds) }; return .success
        }
    }
    private func publishNowPlaying() {
        guard let episode else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: episode.title, MPMediaItemPropertyAlbumTitle: show?.title ?? "", MPMediaItemPropertyArtist: show?.author ?? "", MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0, MPNowPlayingInfoPropertyDefaultPlaybackRate: speed]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func fetchArtwork(_ url: URL?, episodeID: String, generation: UInt64) {
        guard let url, (try? PublicURL.validate(url)) != nil else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), data.count < 5_000_000, let image = UIImage(data: data),
                  let self, self.session.accepts(episodeID: episodeID, generation: generation) else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }; self.publishNowPlaying()
        }
    }
}
