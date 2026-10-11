/// Elapsed time and distance of the current workout.
public struct Session: Equatable, Sendable {
    /// Seconds, on the treadmill's own clock.
    public private(set) var elapsed = 0
    /// Kilometers.
    public private(set) var distance = 0.0

    public init() {}

    /// Records a telemetry sample.
    ///
    /// When the treadmill doesn't report a distance, it's integrated from the speed over the
    /// treadmill's own clock, so pauses and sampling jitter don't skew it.
    ///
    /// - Parameters:
    ///   - newElapsed: Seconds since the workout started, as reported by the treadmill.
    ///   - speed: Current belt speed in km/h.
    ///   - reported: Total distance in kilometers, if the treadmill reports one.
    public mutating func record(elapsed newElapsed: Int, speed: Double, distance reported: Double? = nil) {
        let delta = newElapsed - elapsed
        if delta < 0 { distance = 0 }  // The clock went backwards: a new workout started.
        elapsed = newElapsed
        if let reported {
            distance = reported
        } else if (1...5).contains(delta) {  // A bigger jump means we connected mid-workout.
            distance += speed * Double(delta) / 3600
        }
    }
}
