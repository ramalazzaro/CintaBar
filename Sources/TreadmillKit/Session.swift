/// Elapsed time and distance of the current workout, and what the treadmill counted during it.
///
/// Most of it is counted by the treadmill itself. A workout can outlast those counts: a pause
/// stood in for by stopping the belt is, to many treadmills, the end of their workout. The
/// session is held meanwhile, and then carries on from where it was.
public struct Session: Equatable, Sendable {
    /// Seconds, on the treadmill's own clock.
    public var elapsed: Int { clock.total }
    /// Kilometers.
    public private(set) var distance = 0.0
    /// Kilocalories, by the treadmill's own estimate. Zero until it reports some.
    public var calories: Double { energy.total }
    /// Steps, by the treadmill's own count. Zero until it reports some.
    public var steps: Int { stepCount.total }

    /// Whether the session is held where it is, while the belt is stopped in place of a pause.
    ///
    /// Nothing the treadmill reports meanwhile adds to it: not a clock that keeps going, and not
    /// counts that go back to zero, which would otherwise mean a new workout. Once it's let go, the
    /// counts carry on from what the session had, wherever the treadmill picks its own up from.
    public var isHeld = false {
        didSet {
            guard oldValue, !isHeld else { return }
            // Where a treadmill picks its counts up from only shows once the belt runs again: some
            // start over from zero, some from where they had stopped their own count.
            clock.mayStartOver = true
            reportedDistance.mayStartOver = true
            energy.mayStartOver = true
            stepCount.mayStartOver = true
        }
    }

    private var clock = Count<Int>()
    private var reportedDistance = Count<Double>()
    private var energy = Count<Double>()
    private var stepCount = Count<Int>()

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
        // The clock went backwards outside a pause: a new workout started.
        if newElapsed < clock.reported, !isHeld, !clock.mayStartOver { self = Session() }
        let delta = clock.record(newElapsed, isHeld: isHeld)
        if let reported {
            reportedDistance.record(reported, isHeld: isHeld)
            distance = reportedDistance.total
        } else if (1...5).contains(delta) {  // A bigger jump means we connected mid-workout.
            distance += speed * Double(delta) / 3600
        }
    }

    /// Records the totals the treadmill keeps itself, leaving alone whichever it didn't mention.
    ///
    /// Unlike the distance, they're never estimated here: that takes knowing who is on the belt.
    public mutating func record(calories: Double?, steps: Int?) {
        if let calories { energy.record(calories, isHeld: isHeld) }
        if let steps { stepCount.record(steps, isHeld: isHeld) }
    }

    /// One of the treadmill's own counts, and what the session made of it.
    private struct Count<Value: AdditiveArithmetic & Comparable & Sendable>: Equatable, Sendable {
        /// The treadmill's last report.
        private(set) var reported = Value.zero
        /// What the session counted that the treadmill's report doesn't include: what the total
        /// was when the treadmill's count last went its own way, less what it reported then.
        private var carried = Value.zero
        /// Whether the next report is the first after a hold, which is wherever the treadmill
        /// picks its count up from: zero, or the value it had paused its own count at.
        var mayStartOver = false

        var total: Value { carried + reported }

        /// Takes a report, and returns how far it moved the total.
        @discardableResult
        mutating func record(_ value: Value, isHeld: Bool) -> Value {
            let before = total
            // Held, the total stands whatever is reported, and so it does on the first report
            // after the hold: the count carries on from there.
            if isHeld || mayStartOver { carried = before - value }
            mayStartOver = false
            reported = value
            return total - before
        }
    }
}
