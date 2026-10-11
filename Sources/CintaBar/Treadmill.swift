import CoreBluetooth
import OSLog
import Observation
import TreadmillKit

/// The treadmill: finds the peripheral, keeps the connection alive, and translates commands from
/// the menu into whichever protocol the treadmill speaks.
@Observable
final class Treadmill: NSObject {
    enum Connection: Equatable {
        /// Bluetooth can't be used right now.
        case unavailable(CBManagerState)
        case searching
        case searchEnded
        /// A connection request is pending. It completes whenever the treadmill powers on.
        case waiting(name: String)
        case ready(name: String)
    }

    enum WireProtocol: String, CaseIterable, Identifiable {
        // Listed first so it wins when a treadmill offers both: it's a published standard.
        case ftms = "FTMS"
        case fitShow = "FitShow"

        var id: Self { self }
    }

    /// A peripheral seen while searching.
    struct Candidate: Identifiable {
        let peripheral: CBPeripheral
        let name: String
        /// Whether its name or its advertised services say it's a treadmill.
        let isLikelyTreadmill: Bool

        var id: UUID { peripheral.identifier }
    }

    /// A value asked for from the menu.
    ///
    /// It stands until the treadmill reaches it or it expires. After that the treadmill's own
    /// report wins, because the console and the remote can change the same value.
    private struct Request {
        let value: Double
        private let deadline: ContinuousClock.Instant

        init(_ value: Double, validFor duration: Duration = .seconds(10)) {
            self.value = value
            deadline = .now + duration
        }

        var isExpired: Bool { .now > deadline }

        func isSettled(by reported: Double) -> Bool { abs(reported - value) < 0.05 || isExpired }
    }

    private enum DefaultsKey {
        static let peripheral = "peripheralIdentifier"
        static let wireProtocol = "preferredProtocol"
    }

    // MARK: - State

    private(set) var connection = Connection.unavailable(.unknown)
    private(set) var belt = BeltState.idle
    /// Belt speed in km/h, as reported by the treadmill.
    private(set) var speed = 0.0
    /// Incline as reported by the treadmill: a level for FitShow, percent for FTMS.
    private(set) var incline = 0.0
    private(set) var session = Session()
    /// The speeds the treadmill supports, in km/h.
    private(set) var speedRange = Treadmill.defaultSpeedRange
    private(set) var inclineRange = 0.0...0.0
    private(set) var inclineStep = 1.0
    /// Peripherals found by the current search.
    private(set) var candidates: [Candidate] = []
    /// The protocols the connected treadmill offers.
    private(set) var availableProtocols: [WireProtocol] = []
    private(set) var activeProtocol: WireProtocol?

    private var requestedSpeed: Request?
    private var requestedIncline: Request?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var rejected: Set<UUID> = []
    @ObservationIgnored private var searchTimer: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var outbox: [(key: String?, data: Data)] = []
    @ObservationIgnored private var lastWrite = ContinuousClock.now
    @ObservationIgnored private var speedAfterStart: Request?
    @ObservationIgnored private var ftmsBelt = FTMS.BeltTracker()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CintaBar", category: "bluetooth")

    private static let services = WireProtocol.allCases.flatMap(\.services)
    /// Deliberately low: it only applies until the treadmill reports what it supports.
    private static let defaultSpeedRange = 1.0...6.0
    /// FitShow modules drop frames that arrive back to back, so writes are spaced out.
    private static let writeSpacing = Duration.milliseconds(250)
    private static let maximumUnlikelyCandidates = 10

    override init() {
        super.init()
        // A nil queue delivers delegate callbacks on the main queue.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isReady: Bool {
        if case .ready = connection { true } else { false }
    }

    var isMoving: Bool { belt == .running || belt == .stopping }
    var targetSpeed: Double { requestedSpeed?.value ?? speed }
    var targetIncline: Double { requestedIncline?.value ?? incline }

    // MARK: - Commands

    /// Starts the belt, or resumes it after a pause. The treadmill runs its own countdown first.
    ///
    /// - Parameter speed: The speed to go to once the belt is moving, in km/h. Pass `nil` to stay
    ///   at the speed the treadmill starts with.
    func start(at speed: Double? = nil) {
        guard isReady else { return }
        speedAfterStart = speed.map { Request(clamp($0), validFor: .seconds(20)) }
        switch activeProtocol {
        case .fitShow:
            send(FitShow.start)
        case .ftms:
            send(FTMS.requestControl)
            send(FTMS.startOrResume)
            ftmsBelt.startRequested()
            update(belt: ftmsBelt.state)
        case nil:
            break
        }
    }

    func pause() {
        guard isReady else { return }
        switch activeProtocol {
        case .fitShow: send(FitShow.pause)
        case .ftms: send(FTMS.pause)
        case nil: break
        }
    }

    /// Stops the belt. This jumps the queue: nothing should delay a stop.
    func stop() {
        guard isReady else { return }
        speedAfterStart = nil
        outbox.removeAll()
        switch activeProtocol {
        case .fitShow:
            send(FitShow.stop, immediately: true)
        case .ftms:
            send(FTMS.stop, immediately: true)
            ftmsBelt.startCancelled()
            update(belt: ftmsBelt.state)
        case nil:
            break
        }
    }

    /// Sets the belt speed in km/h, clamped to what the treadmill supports.
    func setSpeed(_ speed: Double) {
        guard isReady, belt == .running else { return }
        let speed = clamp(speed)
        requestedSpeed = Request(speed)
        switch activeProtocol {
        case .fitShow: sendFitShowTarget()
        case .ftms: send(FTMS.setSpeed(speed), replacing: "speed")
        case nil: break
        }
    }

    func setIncline(_ incline: Double) {
        guard isReady, belt == .running else { return }
        let incline = min(max(incline, inclineRange.lowerBound), inclineRange.upperBound)
        requestedIncline = Request(incline)
        switch activeProtocol {
        case .fitShow: sendFitShowTarget()
        case .ftms: send(FTMS.setIncline(incline), replacing: "incline")
        case nil: break
        }
    }

    /// Switches protocol on a treadmill that offers more than one, and remembers the choice.
    func use(_ wireProtocol: WireProtocol) {
        defaults.set(wireProtocol.rawValue, forKey: DefaultsKey.wireProtocol)
        guard wireProtocol != activeProtocol else { return }
        disconnect()
        resume()
    }

    /// Connects to a treadmill picked from ``candidates``. It's remembered once it proves usable.
    func connect(to candidate: Candidate) {
        connect(to: candidate.peripheral, name: candidate.name)
    }

    /// Scans for nearby treadmills for a limited time, since scanning keeps the radio busy.
    func search() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        // Peripherals another app is already connected to don't advertise, so ask for those too.
        candidates = central.retrieveConnectedPeripherals(withServices: Self.services)
            .filter { !rejected.contains($0.identifier) }
            .map { Candidate(peripheral: $0, name: $0.name ?? "Treadmill", isLikelyTreadmill: true) }
        connection = .searching
        central.scanForPeripherals(withServices: Self.services)

        searchTimer?.cancel()
        searchTimer = Task {
            do {
                // Scanning by service is the recommended practice, but many FitShow modules don't
                // advertise theirs. Widen the scan and let the user pick by name instead.
                try await Task.sleep(for: .seconds(5))
                central.scanForPeripherals(withServices: nil)
                try await Task.sleep(for: .seconds(25))
                central.stopScan()
                connection = .searchEnded
            } catch {
                // Cancelled: a treadmill was chosen, or Bluetooth went away.
            }
        }
    }

    /// Drops the remembered treadmill and looks for another one.
    func forget() {
        defaults.removeObject(forKey: DefaultsKey.peripheral)
        disconnect()
        search()
    }

    /// Unsubscribes and closes the connection, as Apple recommends once it's no longer needed.
    func disconnect() {
        guard let peripheral else { return }
        let characteristics = peripheral.services?.flatMap { $0.characteristics ?? [] } ?? []
        for characteristic in characteristics where characteristic.isNotifying {
            peripheral.setNotifyValue(false, for: characteristic)
        }
        central.cancelPeripheralConnection(peripheral)
        reset()
    }

    // MARK: - Connection

    /// Follows Apple's reconnection order: a known peripheral first, scanning as the last resort.
    private func resume() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        let saved = defaults.string(forKey: DefaultsKey.peripheral).flatMap(UUID.init)
        if let saved, let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(to: known, name: known.name ?? "treadmill")
        } else {
            search()
        }
    }

    private func connect(to chosen: CBPeripheral, name: String) {
        searchTimer?.cancel()
        central.stopScan()
        candidates = []
        peripheral = chosen
        chosen.delegate = self
        connection = .waiting(name: name)
        // Connection requests don't time out, so this one waits for the treadmill to power on.
        central.connect(chosen)
    }

    private func becomeReady() {
        guard let peripheral, !isReady else { return }
        defaults.set(peripheral.identifier.uuidString, forKey: DefaultsKey.peripheral)
        connection = .ready(name: peripheral.name ?? "Treadmill")
        log.notice("Ready over \(self.activeProtocol?.rawValue ?? "?", privacy: .public)")

        if activeProtocol == .fitShow {
            // The same handshake the vendor's app performs.
            send(FitShow.userProfile())
            send(FitShow.syncClock())
            send(FitShow.querySpeedRange)
            send(FitShow.queryInclineRange)
        }
        runPump()
    }

    private func reset() {
        searchTimer?.cancel()
        pump?.cancel()
        peripheral = nil
        writeCharacteristic = nil
        outbox = []
        speedAfterStart = nil
        ftmsBelt = FTMS.BeltTracker()
        candidates = []
        availableProtocols = []
        activeProtocol = nil
        requestedSpeed = nil
        requestedIncline = nil
        // The next treadmill may be a different one, so don't carry these limits over.
        speedRange = Self.defaultSpeedRange
        inclineRange = 0...0
        inclineStep = 1
        update(belt: .idle, speed: 0, incline: 0)
    }

    // MARK: - Transport

    /// Queues a write.
    ///
    /// - Parameters:
    ///   - key: Drops any queued write with the same key, so a burst of changes sends only the last.
    ///   - immediately: Skips the queue and the spacing between writes.
    private func send(_ data: Data, replacing key: String? = nil, immediately: Bool = false) {
        if let key { outbox.removeAll { $0.key == key } }
        outbox.insert((key, data), at: immediately ? outbox.startIndex : outbox.endIndex)
        if immediately || lastWrite.duration(to: .now) >= Self.writeSpacing { flush() }
    }

    private func sendFitShowTarget() {
        send(FitShow.target(speed: targetSpeed, incline: Int(targetIncline)), replacing: "target")
    }

    /// Writes the next queued frame, if the peripheral can take it.
    private func flush() {
        guard let peripheral, let writeCharacteristic, let next = outbox.first else { return }
        let withoutResponse = writeCharacteristic.properties.contains(.writeWithoutResponse)
        // Writes without a response have no other flow control. The time limit is a way out for
        // peripherals that never report being ready.
        if withoutResponse, !peripheral.canSendWriteWithoutResponse,
            lastWrite.duration(to: .now) < .seconds(1)
        {
            return
        }
        outbox.removeFirst()
        lastWrite = .now
        log.debug("→ \(next.data.hexDescription, privacy: .public)")
        peripheral.writeValue(
            next.data, for: writeCharacteristic, type: withoutResponse ? .withoutResponse : .withResponse)
    }

    /// Drains the outbox one frame at a time and, for FitShow, polls the status in between.
    private func runPump() {
        pump?.cancel()
        pump = Task {
            var tick = 0
            while true {
                do {
                    try await Task.sleep(for: Self.writeSpacing, tolerance: .milliseconds(50))
                } catch {
                    return
                }
                tick += 1
                // FitShow treadmills don't notify on their own. Ask more often while the belt is
                // active, when the numbers are changing.
                if activeProtocol == .fitShow, outbox.isEmpty, tick.isMultiple(of: belt == .idle ? 4 : 2) {
                    outbox.append((nil, FitShow.queryStatus))
                }
                flush()
            }
        }
    }

    // MARK: - Telemetry

    private func apply(_ reply: FitShow.Reply) {
        switch reply {
        case .speedRange(let range):
            speedRange = range
        case .inclineRange(let range):
            inclineRange = Double(range.lowerBound)...Double(range.upperBound)
            inclineStep = 1
        case .status(let belt, let speed, let incline, let elapsed):
            update(belt: belt, speed: speed, incline: Double(incline))
            if let elapsed { record(elapsed: elapsed, distance: nil) }
        }
    }

    private func apply(_ data: FTMS.TreadmillData) {
        if let speed = data.speed {
            ftmsBelt.record(speed: speed)
            update(belt: ftmsBelt.state, speed: speed, incline: data.incline ?? incline)
        }
        if let elapsed = data.elapsed { record(elapsed: elapsed, distance: data.distance) }
    }

    /// Stores what the treadmill reported, touching only what changed so views don't redraw for
    /// every identical sample.
    private func update(belt newBelt: BeltState, speed newSpeed: Double? = nil, incline newIncline: Double? = nil) {
        let wasRunning = belt == .running
        if belt != newBelt { belt = newBelt }
        if let newSpeed, speed != newSpeed { speed = newSpeed }
        if let newIncline, incline != newIncline { incline = newIncline }

        if requestedSpeed?.isSettled(by: speed) == true { requestedSpeed = nil }
        if requestedIncline?.isSettled(by: incline) == true { requestedIncline = nil }
        if belt == .running, !wasRunning, let pending = speedAfterStart {
            speedAfterStart = nil
            if !pending.isExpired { setSpeed(pending.value) }
        }
    }

    private func record(elapsed: Int, distance: Double?) {
        var updated = session
        updated.record(elapsed: elapsed, speed: speed, distance: distance)
        if updated != session { session = updated }
    }

    private func clamp(_ speed: Double) -> Double {
        (min(max(speed, speedRange.lowerBound), speedRange.upperBound) * 10).rounded() / 10
    }
}

// MARK: - CBCentralManagerDelegate

extension Treadmill: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.notice("Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn {
            resume()
        } else {
            // Peripherals are invalid from here on, so there's nothing to disconnect.
            reset()
            connection = .unavailable(central.state)
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard !rejected.contains(peripheral.identifier),
            !candidates.contains(where: { $0.id == peripheral.identifier }),
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        else { return }

        // FitShow modules name themselves "FS-" followed by an identifier.
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isLikely = name.uppercased().hasPrefix("FS-") || advertised.contains(where: Self.services.contains)
        log.info("Saw \(name, privacy: .public), \(isLikely ? "likely" : "unlikely", privacy: .public) a treadmill")

        // Earbuds and the like advertise from several addresses under one name; list them once.
        let others = candidates.filter { !$0.isLikelyTreadmill }
        let isNewOther = others.count < Self.maximumUnlikelyCandidates && !others.contains { $0.name == name }
        if isLikely || isNewOther {
            candidates.append(Candidate(peripheral: peripheral, name: name, isLikelyTreadmill: isLikely))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.notice("Connected to \(peripheral.name ?? "?", privacy: .public)")
        peripheral.discoverServices(Self.services)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        connectionEnded(with: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        connectionEnded(with: peripheral, error: error)
    }

    private func connectionEnded(with gone: CBPeripheral, error: (any Error)?) {
        // Disconnections this app asked for have already cleared `peripheral`.
        guard gone === peripheral else { return }
        log.notice("Connection ended: \(error?.localizedDescription ?? "no error", privacy: .public)")
        reset()
        resume()
    }
}

// MARK: - CBPeripheralDelegate

extension Treadmill: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            // Usually the link dropped mid-discovery; the disconnection callback takes it from here.
            log.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let offered = peripheral.services ?? []
        availableProtocols = WireProtocol.allCases.filter { candidate in
            offered.contains { candidate.services.contains($0.uuid) }
        }
        let preferred = defaults.string(forKey: DefaultsKey.wireProtocol).flatMap(WireProtocol.init)
        guard let chosen = availableProtocols.first(where: { $0 == preferred }) ?? availableProtocols.first,
            let service = offered.first(where: { chosen.services.contains($0.uuid) })
        else {
            log.notice("\(peripheral.name ?? "?", privacy: .public) offers no supported service")
            rejected.insert(peripheral.identifier)
            forget()
            return
        }
        activeProtocol = chosen
        // Discover only what's used.
        peripheral.discoverCharacteristics(chosen.characteristics, for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?
    ) {
        for characteristic in service.characteristics ?? [] {
            let identifier = characteristic.uuid.uuidString
            switch activeProtocol {
            case .fitShow:
                if FitShow.writeCharacteristics.contains(identifier) { writeCharacteristic = characteristic }
                // Some modules use one characteristic for both directions.
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            case .ftms:
                switch identifier {
                case FTMS.controlPoint:
                    writeCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FTMS.treadmillData, FTMS.machineStatus:
                    peripheral.setNotifyValue(true, for: characteristic)
                case FTMS.speedRange, FTMS.inclineRange:
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            case nil:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            log.error("Subscribing failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard characteristic.isNotifying else { return }
        if activeProtocol == .ftms, characteristic.uuid.uuidString == FTMS.controlPoint {
            send(FTMS.requestControl)
        }
        becomeReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let identifier = characteristic.uuid.uuidString
        log.debug("← \(identifier, privacy: .public) \(data.hexDescription, privacy: .public)")

        switch (activeProtocol, identifier) {
        case (.fitShow, _):
            if let reply = FitShow.parse(data) { apply(reply) }
        case (.ftms, FTMS.treadmillData):
            if let parsed = FTMS.parseTreadmillData(data) { apply(parsed) }
        case (.ftms, FTMS.machineStatus):
            if let event = FTMS.parseStatus(data) {
                ftmsBelt.record(event)
                update(belt: ftmsBelt.state)
            }
        case (.ftms, FTMS.controlPoint):
            if FTMS.isStartRejection(data) {
                ftmsBelt.startCancelled()
                update(belt: ftmsBelt.state)
            }
        case (.ftms, FTMS.speedRange):
            if let supported = FTMS.parseSpeedRange(data), supported.range.upperBound > 0 {
                speedRange = supported.range
            }
        case (.ftms, FTMS.inclineRange):
            if let supported = FTMS.parseInclineRange(data) {
                inclineRange = supported.range
                inclineStep = max(supported.step, 0.5)
            }
        default:
            break
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard !invalidatedServices.isEmpty else { return }
        disconnect()
        resume()
    }
}

// MARK: - Helpers

extension Treadmill.WireProtocol {
    fileprivate var services: [CBUUID] {
        switch self {
        case .ftms: [CBUUID(string: FTMS.service)]
        case .fitShow: FitShow.services.map { CBUUID(string: $0) }
        }
    }

    fileprivate var characteristics: [CBUUID] {
        let identifiers =
            switch self {
            case .ftms:
                [FTMS.controlPoint, FTMS.treadmillData, FTMS.machineStatus, FTMS.speedRange, FTMS.inclineRange]
            case .fitShow:
                FitShow.writeCharacteristics + FitShow.notifyCharacteristics
            }
        return identifiers.map { CBUUID(string: $0) }
    }
}

extension Data {
    fileprivate var hexDescription: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
