import Foundation

/// The proprietary protocol spoken by FitShow Bluetooth modules (GATT service `FFF0` or `FFE0`).
///
/// Every frame is `02 | command | parameters… | checksum | 03`, where the checksum is the XOR of
/// the command and parameter bytes. The treadmill only answers when asked, so its state has to be
/// polled with ``queryStatus``.
public enum FitShow {
    public static let services = ["FFF0", "FFE0"]
    public static let notifyCharacteristics = ["FFF1", "FFE4"]
    public static let writeCharacteristics = ["FFF2", "FFE1"]

    private enum Command {
        static let info: UInt8 = 0x50
        static let status: UInt8 = 0x51
        static let control: UInt8 = 0x53
    }

    private enum Info {
        static let model: UInt8 = 0x00
        static let speed: UInt8 = 0x02
        static let incline: UInt8 = 0x03
    }

    private enum Control {
        static let user: UInt8 = 0x00
        static let start: UInt8 = 0x01
        static let target: UInt8 = 0x02
        static let stop: UInt8 = 0x03
        static let pause: UInt8 = 0x06
    }

    private enum Status: UInt8 {
        case idle = 0
        case ended = 1
        case countdown = 2
        case running = 3
        case stopping = 4
        case fault = 5
        case safetyKey = 6
        case calibrating = 7
        case paused = 10

        /// Only these states carry speed, incline and elapsed time.
        var hasTelemetry: Bool { [.ended, .running, .stopping, .paused].contains(self) }
    }

    // MARK: - Commands

    public static let queryStatus = frame([Command.status])
    public static let querySpeedRange = frame([Command.info, Info.speed])
    public static let queryInclineRange = frame([Command.info, Info.incline])
    public static let stop = frame([Command.control, Control.stop])
    public static let pause = frame([Command.control, Control.pause])

    /// Starts a free workout, or resumes a paused one. The treadmill runs its own countdown first.
    ///
    /// The parameters are a 32-bit workout identifier, the mode (0 is free running), and the
    /// program segment count and target, all unused here.
    public static let start = frame([Command.control, Control.start, 0, 0, 0, 0, 0, 0, 0, 0])

    /// Sets the speed in km/h and the incline level. The protocol always sends both together.
    public static func target(speed: Double, incline: Int) -> Data {
        frame([
            Command.control, Control.target,
            UInt8(clamping: Int((speed * 10).rounded())),
            UInt8(bitPattern: Int8(clamping: incline)),
        ])
    }

    /// The user profile the vendor's app sends on connecting, which the treadmill uses to estimate
    /// calories.
    ///
    /// The parameters are a 16-bit user identifier, a byte of unknown meaning that existing
    /// implementations send as 110, the age, and the weight.
    public static func userProfile(age: Int = 30, weightInKilograms: Int = 70) -> Data {
        frame([Command.control, Control.user, 0, 0, 110, UInt8(clamping: age), UInt8(clamping: weightInKilograms)])
    }

    /// Sets the treadmill's clock, the second step of the vendor app's handshake.
    public static func syncClock(to date: Date = .now, calendar: Calendar = .current) -> Data {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let fields = [
            (parts.year ?? 2000) - 2000, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
        ]
        return frame([Command.info, Info.model] + fields.map { UInt8(clamping: $0) })
    }

    // MARK: - Replies

    public enum Reply: Equatable, Sendable {
        /// The supported speeds, in km/h.
        case speedRange(ClosedRange<Double>)
        /// The supported incline levels; `0...0` when the incline isn't motorized.
        case inclineRange(ClosedRange<Int>)
        /// Speed is in km/h. `elapsed` is in seconds and only present during a workout, as are the
        /// treadmill's own totals: `calories` in kcal, and `steps`. `heartRate` is in beats per
        /// minute, and zero when there's no reading.
        case status(
            belt: BeltState, speed: Double, incline: Int, elapsed: Int?, calories: Double? = nil, steps: Int? = nil,
            heartRate: Int = 0)
    }

    /// Decodes a notification from the treadmill.
    ///
    /// - Returns: `nil` for corrupt frames and for replies this app has no use for.
    public static func parse(_ data: Data) -> Reply? {
        guard let payload = payload(of: data), payload.count >= 2 else { return nil }
        let parameters = payload.dropFirst(2).map { $0 }

        switch (payload[0], payload[1]) {
        case (Command.info, Info.speed):
            // Maximum first, then minimum, both in tenths of a km/h.
            guard parameters.count >= 2, parameters[1] > 0, parameters[0] >= parameters[1] else { return nil }
            return .speedRange(Double(parameters[1]) / 10...Double(parameters[0]) / 10)

        case (Command.info, Info.incline):
            // A treadmill without a motorized incline answers with no parameters.
            guard parameters.count >= 2, parameters[0] >= parameters[1] else { return .inclineRange(0...0) }
            return .inclineRange(Int(parameters[1])...Int(parameters[0]))

        case (Command.status, let code):
            let status = Status(rawValue: code) ?? .idle
            let belt: BeltState =
                switch status {
                case .idle, .ended: .idle
                case .countdown: .countdown(parameters.first.map(Int.init) ?? 0)
                case .running: .running
                case .stopping: .stopping
                case .fault: .fault(parameters.first.map(Int.init) ?? 0)
                case .safetyKey: .safetyKey
                case .calibrating: .calibrating
                case .paused: .paused
                }
            guard status.hasTelemetry, parameters.count >= 4 else {
                return .status(belt: belt, speed: 0, incline: 0, elapsed: nil)
            }
            func word(at index: Int) -> Int { Int(parameters[index]) | Int(parameters[index + 1]) << 8 }
            // A full frame goes on with the distance, calories, steps and heart rate. The distance
            // is left for `Session` to integrate, because implementations disagree on its unit.
            let isFull = parameters.count >= 11
            return .status(
                belt: belt,
                speed: Double(parameters[0]) / 10,
                incline: Int(Int8(bitPattern: parameters[1])),
                elapsed: word(at: 2),
                // In tenths, going by the one implementation known to show the treadmill's figure.
                calories: isFull ? Double(word(at: 6)) / 10 : nil,
                steps: isFull ? word(at: 8) : nil,
                heartRate: isFull ? Int(parameters[10]) : 0
            )

        default:
            return nil
        }
    }

    // MARK: - Framing

    static func frame(_ payload: [UInt8]) -> Data {
        Data([0x02] + payload + [payload.reduce(0, ^), 0x03])
    }

    /// The command and parameter bytes of a frame, or `nil` if its markers or checksum are wrong.
    static func payload(of frame: Data) -> [UInt8]? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 4, bytes.first == 0x02, bytes.last == 0x03 else { return nil }
        let payload = Array(bytes[1..<bytes.count - 2])
        return payload.reduce(0, ^) == bytes[bytes.count - 2] ? payload : nil
    }
}
