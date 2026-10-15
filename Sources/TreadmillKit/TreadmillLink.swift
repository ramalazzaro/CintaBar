import Foundation

/// How ``Treadmill`` reaches the machine. The app provides a Bluetooth link, and a simulated one
/// for working on the user interface without hardware.
///
/// A link owns discovery, the connection and the wire protocol. It reports back through
/// ``eventHandler``, always on the main actor.
@MainActor
public protocol TreadmillLink: AnyObject {
    /// Where the link reports to.
    ///
    /// Whoever sets this only starts listening then, and a link usually knows something by that
    /// point. So setting a handler has the link report its current ``LinkEvent/connection(_:)``
    /// at once, rather than leaving the listener on a guess until the next change.
    var eventHandler: (@MainActor (LinkEvent) -> Void)? { get set }

    /// Looks for nearby treadmills for a while, reporting them as ``LinkEvent/candidates(_:)``.
    func search()
    /// Connects to one of the candidates. Once it proves usable, it's remembered for next time.
    func connect(to candidateID: UUID)
    /// Closes the connection without forgetting the treadmill.
    func disconnect()
    /// Drops the remembered treadmill and searches for another one.
    func forget()
    /// Switches protocol on a treadmill that offers more than one, reconnecting if needed.
    func use(_ wireProtocol: WireProtocol)
    func send(_ command: TreadmillCommand)
    /// Keeps what ``Treadmill`` learned about the connected treadmill: whether it ignores a pause.
    ///
    /// The model has nowhere to keep it, and can't tell one treadmill from another. The link
    /// files it with the treadmill and protocol in use, and hands it back as
    /// ``LinkEvent/ignoresPause(_:)`` every time that treadmill becomes ready again.
    func remember(ignoresPause: Bool)
}

public enum LinkEvent: Equatable, Sendable {
    case connection(Connection)
    case candidates([Candidate])
    /// The protocols the connected treadmill offers, and the one in use.
    case protocols(available: [WireProtocol], active: WireProtocol?)
    /// Supported speeds, in km/h.
    case speedRange(ClosedRange<Double>)
    /// Supported inclines and the step between them: levels for FitShow, percent for FTMS.
    case inclineRange(ClosedRange<Double>, step: Double)
    case sample(Sample)
    /// What ``TreadmillLink/remember(ignoresPause:)`` last kept for this treadmill, `false` if
    /// nothing. Sent just before every ``Connection/ready(name:)``.
    case ignoresPause(Bool)
}

public enum TreadmillCommand: Equatable, Sendable {
    /// Starts the belt, or resumes it after a pause.
    case start
    case pause
    case stop
    /// The speed (km/h) and incline wanted. Both are always given; a link sends what changed.
    case target(speed: Double, incline: Double)
}

public enum Connection: Equatable, Sendable {
    /// The link can't be used right now.
    case unavailable(Unavailability)
    case searching
    case searchEnded
    /// A connection request is pending. It completes whenever the treadmill powers on.
    case waiting(name: String)
    case ready(name: String)

    public enum Unavailability: Equatable, Sendable {
        case poweredOff, unauthorized, unsupported, unknown
        /// macOS is asking the user for Bluetooth permission, and nothing works until they answer.
        case permissionPending
    }
}

public enum WireProtocol: String, CaseIterable, Identifiable, Sendable {
    // Listed first so it wins when a treadmill offers both: it's a published standard.
    case ftms = "FTMS"
    case fitShow = "FitShow"

    public var id: Self { self }
}

/// A device seen while searching.
public struct Candidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// Whether its name or its advertised services say it's a treadmill.
    public let isLikelyTreadmill: Bool

    public init(id: UUID, name: String, isLikelyTreadmill: Bool) {
        self.id = id
        self.name = name
        self.isLikelyTreadmill = isLikelyTreadmill
    }
}

/// One report from the treadmill. Anything it didn't mention is `nil`.
public struct Sample: Equatable, Sendable {
    public var belt: BeltState?
    /// km/h.
    public var speed: Double?
    public var incline: Double?
    /// Seconds since the workout started.
    public var elapsed: Int?
    /// Kilometers since the workout started.
    public var distance: Double?
    /// Kilocalories since the workout started, by the treadmill's own estimate.
    public var calories: Double?
    /// Steps since the workout started, by the treadmill's own count.
    public var steps: Int?
    /// Beats per minute. Zero says the treadmill has no reading, which isn't the same as not
    /// mentioning it: it clears the last one.
    public var heartRate: Int?

    public init(
        belt: BeltState? = nil, speed: Double? = nil, incline: Double? = nil, elapsed: Int? = nil,
        distance: Double? = nil, calories: Double? = nil, steps: Int? = nil, heartRate: Int? = nil
    ) {
        self.belt = belt
        self.speed = speed
        self.incline = incline
        self.elapsed = elapsed
        self.distance = distance
        self.calories = calories
        self.steps = steps
        self.heartRate = heartRate
    }
}
