import PodcastModels
import ContentFiltering
/// Models resumption intent separately from AVPlayer's automatic status changes.
public struct InterruptionRecovery: Sendable {
    private var resumeRequested = false
    public init() {}
    public mutating func began(wasPlaying: Bool) { resumeRequested = wasPlaying }
    public mutating func userPausedOrRouteLost() { resumeRequested = false }
    public mutating func ended(systemAllowsResume: Bool, contentAllowed: Bool) -> Bool {
        defer { resumeRequested = false }
        return resumeRequested && systemAllowsResume && contentAllowed
    }
}
