/// Watches for a belt that runs faster than the app asked it to.
///
/// One is made for every speed the app sends, and it judges each speed reported after that. The
/// belt is a runaway when it's clearly above both the speed asked for and the slowest it has been
/// since: a belt that speeds up when asked to slow down, or one that shoots past a speed a little
/// above its own. A speed changed from the console is nobody's runaway, so nothing is watched
/// until the app asks for one.
///
/// It only knows what the treadmill reports. Firmware that takes km/h for mph also reports the
/// number it was given, and gets past it.
struct RunawayGuard: Equatable, Sendable {
    /// How far above what it should be doing the belt has to be, in km/h.
    ///
    /// Wide enough for a belt that overshoots as it ramps, a report rounded in another unit and a
    /// press or two of the console's own buttons. Narrow enough that a belt heading for its
    /// maximum crosses it within a couple of seconds.
    static let margin = 1.0

    /// How long the guard stays armed once the belt reaches the speed asked for.
    ///
    /// It can't stand down right then: a belt on its way to the maximum passes through the speed
    /// asked for, and for one report looks like a belt that got there. Ten seconds lets one that
    /// gains as little as 0.1 km/h each second cross the margin, a quarter of the slowest ramp
    /// `Treadmill.Target` allows for. The price is a false alarm for whoever speeds up from the
    /// console within those ten seconds of using the app, and the warning lets them wave it off.
    static let grace = Duration.seconds(10)

    /// Seconds the user gets to answer the warning before the belt is stopped for them.
    static let countdown = 5

    /// The speed the app asked for, in km/h.
    let requested: Double
    /// The slowest the belt has been since. It only goes down, so a belt asked to slow down is
    /// held to how far it got, not to where it started.
    private var slowest: Double

    /// - Parameters:
    ///   - requested: The speed being sent, in km/h.
    ///   - speed: The speed the belt reports as it's sent.
    init(requested: Double, from speed: Double) {
        self.requested = requested
        slowest = speed
    }

    /// Takes a reported speed, in km/h, and says whether it's a runaway.
    mutating func isRunaway(_ speed: Double) -> Bool {
        slowest = min(slowest, speed)
        return speed > max(requested, slowest) + Self.margin
    }
}

/// What the runaway guard has to tell the user.
public enum Runaway: Equatable, Sendable {
    /// The belt is running clearly faster than the `requested` km/h. While `secondsUntilStop`
    /// counts down, the belt gets stopped when it runs out; `nil` leaves it to the user.
    case warning(requested: Double, secondsUntilStop: Int?)
    /// The link went down with the warning up, so nothing can be sent to the treadmill.
    case unreachable
    /// Nobody answered the warning, and the belt was told to stop.
    case stopped(requested: Double)
}
