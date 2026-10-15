import Foundation

/// The Bluetooth SIG Fitness Machine Service (GATT service `1826`), which newer FitShow modules
/// offer alongside or instead of the proprietary protocol.
///
/// Unlike ``FitShow``, the treadmill pushes telemetry on its own. Commands go to the control
/// point, which must be asked for control before it accepts anything else.
public enum FTMS {
    public static let service = "1826"
    public static let treadmillData = "2ACD"
    public static let controlPoint = "2AD9"
    public static let machineStatus = "2ADA"
    public static let speedRange = "2AD4"
    public static let inclineRange = "2AD5"

    private enum Opcode {
        static let requestControl: UInt8 = 0x00
        static let setTargetSpeed: UInt8 = 0x02
        static let setTargetIncline: UInt8 = 0x03
        static let startOrResume: UInt8 = 0x07
        static let stopOrPause: UInt8 = 0x08
        static let response: UInt8 = 0x80
    }

    // MARK: - Control point

    public static let requestControl = Data([Opcode.requestControl])
    public static let startOrResume = Data([Opcode.startOrResume])
    public static let stop = Data([Opcode.stopOrPause, 0x01])
    public static let pause = Data([Opcode.stopOrPause, 0x02])

    /// Sets the target speed in km/h.
    public static func setSpeed(_ speed: Double) -> Data {
        let raw = UInt16(clamping: Int((speed * 100).rounded()))
        return Data([Opcode.setTargetSpeed, UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    /// Sets the target incline in percent.
    public static func setIncline(_ incline: Double) -> Data {
        let raw = UInt16(bitPattern: Int16(clamping: Int((incline * 10).rounded())))
        return Data([Opcode.setTargetIncline, UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    /// Whether a control point indication says the treadmill refused to start.
    public static func isStartRejection(_ response: Data) -> Bool {
        let bytes = [UInt8](response)
        let success: UInt8 = 0x01
        return bytes.count >= 3 && bytes[0] == Opcode.response && bytes[1] == Opcode.startOrResume
            && bytes[2] != success
    }

    // MARK: - Telemetry

    /// One Treadmill Data notification. A treadmill may spread the fields over several of them.
    public struct TreadmillData: Equatable, Sendable {
        /// km/h.
        public var speed: Double?
        /// Kilometers.
        public var distance: Double?
        /// Percent.
        public var incline: Double?
        /// Seconds.
        public var elapsed: Int?
        /// Kilocalories since the workout started.
        public var calories: Double?
        /// Beats per minute. Zero means the field is there but the treadmill has no reading.
        public var heartRate: Int?
        /// Steps since the workout started. Not part of the standard; see where it's parsed.
        public var steps: Int?
    }

    public static func parseTreadmillData(_ data: Data) -> TreadmillData? {
        var reader = ByteReader(data)
        guard let flags = reader.unsigned(byteCount: 2) else { return nil }
        func has(_ bit: Int) -> Bool { flags & 1 << bit != 0 }

        // Fields appear in flag order. Bit 0 is inverted: clear means the speed is present.
        var parsed = TreadmillData()
        if !has(0) { parsed.speed = reader.unsigned(byteCount: 2).map { Double($0) / 100 } }
        if has(1) { reader.skip(2) }  // Average speed.
        if has(2) { parsed.distance = reader.unsigned(byteCount: 3).map { Double($0) / 1000 } }
        if has(3) {
            parsed.incline = reader.signed16().map { Double($0) / 10 }
            reader.skip(2)  // Ramp angle.
        }
        if has(4) { reader.skip(4) }  // Positive and negative elevation gain.
        if has(5) { reader.skip(1) }  // Instantaneous pace.
        if has(6) { reader.skip(1) }  // Average pace.
        if has(7) {
            // All ones means the treadmill doesn't count the energy spent.
            parsed.calories = reader.unsigned(byteCount: 2).flatMap { $0 == 0xFFFF ? nil : Double($0) }
            reader.skip(3)  // Energy per hour and per minute.
        }
        if has(8) { parsed.heartRate = reader.unsigned(byteCount: 1) }
        if has(9) { reader.skip(1) }  // Metabolic equivalent.
        if has(10) { parsed.elapsed = reader.unsigned(byteCount: 2) }
        if has(11) { reader.skip(2) }  // Remaining time.
        if has(12) { reader.skip(4) }  // Force on the belt and power output.

        // The specification ends here: it reserves bits 13 to 15. What follows is an assumption.
        //
        // The Noga FT-200 sets bit 13 on a notification of its own that carries three more bytes,
        // taken here for a step count, which is what at least one other vendor uses the bit for.
        // Nobody has checked that against a count that moves: the bytes were all zero when
        // captured. Only the first two are read. That's the same number as a 24-bit count for any
        // workout under 65,536 steps, and it holds if the third byte turns out to be something
        // else.
        if has(13) {
            parsed.steps = reader.unsigned(byteCount: 2)
            reader.skip(1)
        }
        return parsed
    }

    /// Decodes the Supported Speed Range characteristic into km/h.
    public static func parseSpeedRange(_ data: Data) -> (range: ClosedRange<Double>, step: Double)? {
        var reader = ByteReader(data)
        guard let minimum = reader.unsigned(byteCount: 2), let maximum = reader.unsigned(byteCount: 2),
            let step = reader.unsigned(byteCount: 2), maximum >= minimum
        else { return nil }
        return (Double(minimum) / 100...Double(maximum) / 100, Double(step) / 100)
    }

    /// Decodes the Supported Inclination Range characteristic into percent.
    public static func parseInclineRange(_ data: Data) -> (range: ClosedRange<Double>, step: Double)? {
        var reader = ByteReader(data)
        guard let minimum = reader.signed16(), let maximum = reader.signed16(),
            let step = reader.unsigned(byteCount: 2), maximum >= minimum
        else { return nil }
        return (Double(minimum) / 10...Double(maximum) / 10, Double(step) / 10)
    }

    // MARK: - Belt state

    /// A Fitness Machine Status notification this app cares about.
    public enum Event: Equatable, Sendable {
        case stopped, paused, started, safetyKey
    }

    public static func parseStatus(_ data: Data) -> Event? {
        switch (data.first, data.dropFirst().first) {
        case (0x02, 0x02): .paused
        case (0x02, _): .stopped
        case (0x03, _): .safetyKey
        case (0x04, _): .started
        default: nil
        }
    }

    /// Infers the belt state, which FTMS never reports directly, from speed samples and events.
    public struct BeltTracker: Equatable, Sendable {
        private var isMoving = false
        private var isStarting = false
        /// What a stationary belt means, going by the last event.
        private var resting = BeltState.idle

        public init() {}

        public var state: BeltState {
            if isMoving { .running } else if isStarting { .countdown(0) } else { resting }
        }

        public mutating func record(speed: Double) {
            isMoving = speed > 0
            if isMoving { isStarting = false }
        }

        public mutating func record(_ event: Event) {
            switch event {
            case .started: (resting, isStarting) = (.idle, true)
            case .stopped: (resting, isStarting) = (.idle, false)
            case .paused: (resting, isStarting) = (.paused, false)
            case .safetyKey: (resting, isStarting) = (.safetyKey, false)
            }
        }

        /// Call when a start command is sent, so the wait for the belt shows as a countdown.
        public mutating func startRequested() { (resting, isStarting) = (.idle, true) }

        /// Call when the start was refused or a stop was sent before the belt moved.
        public mutating func startCancelled() { isStarting = false }
    }
}
