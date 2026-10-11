/// What the belt is doing, as reported by the treadmill.
public enum BeltState: Equatable, Sendable {
    case idle
    /// Counting down before the belt moves. Zero when the treadmill doesn't say how long is left.
    case countdown(Int)
    case running
    case stopping
    case paused
    /// The safety key is missing.
    case safetyKey
    case calibrating
    /// The treadmill reported an error with this code.
    case fault(Int)
}
