import Foundation

/// How ``Treadmill`` reaches the machine. The app provides a Bluetooth link, and a simulated one
/// for working on the user interface without hardware.
///
/// A link owns discovery, the connection and the wire protocol. It reports back through
/// ``eventHandler``, always on the main actor.
@MainActor
public protocol TreadmillLink: AnyObject {
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

    public init(
        belt: BeltState? = nil, speed: Double? = nil, incline: Double? = nil, elapsed: Int? = nil,
        distance: Double? = nil
    ) {
        self.belt = belt
        self.speed = speed
        self.incline = incline
        self.elapsed = elapsed
        self.distance = distance
    }
}
