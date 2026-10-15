import CoreBluetooth
import OSLog
import TreadmillKit

/// Reaches the treadmill over Core Bluetooth and speaks whichever protocol it offers.
final class BluetoothLink: NSObject, TreadmillLink {
    /// The model wires this up after the link exists, so whatever the link learned while starting
    /// up would be lost. Setting it reports the connection as it stands.
    var eventHandler: (@MainActor (LinkEvent) -> Void)? {
        didSet { if eventHandler != nil { emit(.connection(connection)) } }
    }

    private enum DefaultsKey {
        static let peripheral = "peripheralIdentifier"
        static let wireProtocol = "preferredProtocol"
        /// Every treadmill found to ignore a pause, as its identifier and the protocol it was using.
        static let ignoringPause = "treadmillsIgnoringPause"
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// Every peripheral seen or retrieved, so a candidate can be connected to by identifier.
    private var known: [UUID: CBPeripheral] = [:]
    private var rejected: Set<UUID> = []
    private var connection = Connection.unavailable(.unknown) {
        didSet { if connection != oldValue { emit(.connection(connection)) } }
    }
    private var candidates: [Candidate] = [] {
        didSet { if candidates != oldValue { emit(.candidates(candidates)) } }
    }
    private var activeProtocol: WireProtocol?
    private var isReady = false
    private var inclineIsMotorized = false
    /// Whether the last FitShow status said the belt was idle, when polling can be lazier.
    private var beltIsIdle = true
    private var resumeAfterDisconnect = false
    private var searchTimer: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var outbox: [(key: String?, data: Data)] = []
    private var lastWrite = ContinuousClock.now
    private var ftmsBelt = FTMS.BeltTracker()
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CintaBar", category: "bluetooth")

    private static let services = WireProtocol.allCases.flatMap(\.services)
    /// How often the pump sends the next queued write.
    private static let pumpInterval = Duration.milliseconds(250)
    /// FitShow modules drop frames that arrive back to back, so writes are kept at least this
    /// far apart. It's shorter than the pump interval so timer jitter never skips a turn.
    private static let minimumWriteGap = Duration.milliseconds(150)
    private static let maximumUnlikelyCandidates = 10

    override init() {
        super.init()
        // A nil queue delivers delegate callbacks on the main queue.
        central = CBCentralManager(delegate: self, queue: nil)
        // The manager reports nothing until its state is known, which can be as late as the user
        // answering the permission prompt. Say what's known meanwhile.
        connection = .unavailable(unavailability(of: central.state))
    }

    // MARK: - TreadmillLink

    /// Scans for a limited time, since scanning keeps the radio busy.
    func search() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        // Peripherals another app is already connected to don't advertise, so ask for those too.
        let connected = central.retrieveConnectedPeripherals(withServices: Self.services)
            .filter { !rejected.contains($0.identifier) }
        for found in connected { known[found.identifier] = found }
        candidates = connected.map {
            Candidate(id: $0.identifier, name: $0.name ?? "Treadmill", isLikelyTreadmill: true)
        }
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

    func connect(to candidateID: UUID) {
        guard let chosen = known[candidateID] else { return }
        connect(to: chosen, name: candidates.first { $0.id == candidateID }?.name ?? chosen.name ?? "Treadmill")
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

    func forget() {
        defaults.removeObject(forKey: DefaultsKey.peripheral)
        disconnect()
        search()
    }

    func use(_ wireProtocol: WireProtocol) {
        defaults.set(wireProtocol.rawValue, forKey: DefaultsKey.wireProtocol)
        guard wireProtocol != activeProtocol, let current = peripheral else { return }
        let name = current.name ?? "Treadmill"
        disconnect()
        connection = .waiting(name: name)
        // Reconnect once the old link is down, so the two requests don't trip over each other.
        // The fallback covers a cancelled connection attempt, which reports nothing.
        resumeAfterDisconnect = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            if resumeAfterDisconnect {
                resumeAfterDisconnect = false
                resume()
            }
        }
    }

    func send(_ command: TreadmillCommand) {
        guard isReady, let activeProtocol else { return }
        switch (command, activeProtocol) {
        case (.start, .fitShow):
            write(FitShow.start)
        case (.start, .ftms):
            write(FTMS.requestControl)
            write(FTMS.startOrResume)
            ftmsBelt.startRequested()
            emit(.sample(Sample(belt: ftmsBelt.state)))
        case (.pause, .fitShow):
            write(FitShow.pause)
        case (.pause, .ftms):
            write(FTMS.pause)
        case (.stop, .fitShow):
            // A stop jumps the queue: nothing should delay it.
            outbox.removeAll()
            write(FitShow.stop, immediately: true)
        case (.stop, .ftms):
            outbox.removeAll()
            write(FTMS.stop, immediately: true)
            ftmsBelt.startCancelled()
            emit(.sample(Sample(belt: ftmsBelt.state)))
        case (.target(let speed, let incline), .fitShow):
            write(FitShow.target(speed: speed, incline: Int(incline.rounded())), replacing: "target")
        case (.target(let speed, let incline), .ftms):
            // Both go out every time: the belt resets its targets on its own, so remembering what
            // was last sent would only guess wrong.
            write(FTMS.setSpeed(speed), replacing: "speed")
            if inclineIsMotorized { write(FTMS.setIncline(incline), replacing: "incline") }
        }
    }

    /// Files the answer under the protocol as well as the treadmill: it's down to how the firmware
    /// implements each, and one may honor a pause that the other ignores.
    func remember(ignoresPause: Bool) {
        guard let filing = pauseFiling else { return }
        var ignoring = Set(defaults.stringArray(forKey: DefaultsKey.ignoringPause) ?? [])
        if ignoresPause {
            ignoring.insert(filing)
        } else {
            ignoring.remove(filing)
        }
        defaults.set(ignoring.sorted(), forKey: DefaultsKey.ignoringPause)
        log.notice("Remembered that it \(ignoresPause ? "ignores" : "honors", privacy: .public) a pause")
    }

    // MARK: - Connection

    private func emit(_ event: LinkEvent) {
        eventHandler?(event)
    }

    /// Follows Apple's reconnection order: a known peripheral first, scanning as the last resort.
    private func resume() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        let saved = defaults.string(forKey: DefaultsKey.peripheral).flatMap(UUID.init)
        if let saved, let remembered = central.retrievePeripherals(withIdentifiers: [saved]).first {
            known[saved] = remembered
            connect(to: remembered, name: remembered.name ?? "treadmill")
        } else {
            search()
        }
    }

    private func connect(to chosen: CBPeripheral, name: String) {
        searchTimer?.cancel()
        resumeAfterDisconnect = false
        central.stopScan()
        candidates = []
        peripheral = chosen
        chosen.delegate = self
        connection = .waiting(name: name)
        // Connection requests don't time out, so this one waits for the treadmill to power on.
        central.connect(chosen)
    }

    private func becomeReady() {
        guard let peripheral, !isReady, let activeProtocol else { return }
        isReady = true
        defaults.set(peripheral.identifier.uuidString, forKey: DefaultsKey.peripheral)
        log.notice("Ready over \(activeProtocol.rawValue, privacy: .public)")

        if activeProtocol == .fitShow {
            // The same handshake the vendor's app performs.
            write(FitShow.userProfile())
            write(FitShow.syncClock())
            write(FitShow.querySpeedRange)
            write(FitShow.queryInclineRange)
        }
        runPump()
        let ignoring = defaults.stringArray(forKey: DefaultsKey.ignoringPause) ?? []
        emit(.ignoresPause(pauseFiling.map(ignoring.contains) ?? false))
        connection = .ready(name: peripheral.name ?? "Treadmill")
    }

    /// How the connected treadmill and protocol are filed among those that ignore a pause.
    private var pauseFiling: String? {
        guard let peripheral, let activeProtocol else { return nil }
        return "\(peripheral.identifier.uuidString) \(activeProtocol.rawValue)"
    }

    private func reset() {
        searchTimer?.cancel()
        pump?.cancel()
        peripheral = nil
        writeCharacteristic = nil
        outbox = []
        isReady = false
        inclineIsMotorized = false
        beltIsIdle = true
        ftmsBelt = FTMS.BeltTracker()
        candidates = []
        activeProtocol = nil
        emit(.protocols(available: [], active: nil))
    }

    private func connectionEnded(with gone: CBPeripheral, error: (any Error)?) {
        if gone === peripheral {
            log.notice("Connection ended: \(error?.localizedDescription ?? "no error", privacy: .public)")
            reset()
            resume()
        } else if resumeAfterDisconnect {
            // The disconnection `use(_:)` asked for.
            resumeAfterDisconnect = false
            resume()
        }
    }

    // MARK: - Transport

    /// Queues a write.
    ///
    /// - Parameters:
    ///   - key: Drops any queued write with the same key, so a burst of changes sends only the last.
    ///   - immediately: Skips the queue and the gap between writes.
    private func write(_ data: Data, replacing key: String? = nil, immediately: Bool = false) {
        if let key { outbox.removeAll { $0.key == key } }
        outbox.insert((key, data), at: immediately ? outbox.startIndex : outbox.endIndex)
        flush(ignoringGap: immediately)
    }

    /// Writes the next queued frame, if it's time and the peripheral can take it. Whatever stays
    /// queued goes out on a later turn of the pump.
    private func flush(ignoringGap: Bool = false) {
        guard let peripheral, let writeCharacteristic, let next = outbox.first else { return }
        let sinceLastWrite = lastWrite.duration(to: .now)
        guard ignoringGap || sinceLastWrite >= Self.minimumWriteGap else { return }

        let withoutResponse = writeCharacteristic.properties.contains(.writeWithoutResponse)
        // Writes without a response have no other flow control. The time limit is a way out for
        // peripherals that never report being ready.
        if withoutResponse, !peripheral.canSendWriteWithoutResponse, sinceLastWrite < .seconds(1) {
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
                    try await Task.sleep(for: Self.pumpInterval, tolerance: .milliseconds(50))
                } catch {
                    return
                }
                tick += 1
                // FitShow treadmills don't notify on their own. Ask more often while the belt is
                // active, when the numbers are changing.
                if activeProtocol == .fitShow, outbox.isEmpty, tick.isMultiple(of: beltIsIdle ? 4 : 2) {
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
            emit(.speedRange(range))
        case .inclineRange(let range):
            inclineIsMotorized = range.upperBound > range.lowerBound
            emit(.inclineRange(Double(range.lowerBound)...Double(range.upperBound), step: 1))
        case .status(let belt, let speed, let incline, let elapsed, let calories, let steps, let heartRate):
            beltIsIdle = belt == .idle
            let sample = Sample(
                belt: belt, speed: speed, incline: Double(incline), elapsed: elapsed, calories: calories,
                steps: steps, heartRate: heartRate)
            emit(.sample(sample))
        }
    }

    private func apply(_ data: FTMS.TreadmillData) {
        var sample = Sample(
            speed: data.speed, incline: data.incline, elapsed: data.elapsed, distance: data.distance,
            calories: data.calories, steps: data.steps, heartRate: data.heartRate)
        if let speed = data.speed {
            ftmsBelt.record(speed: speed)
            sample.belt = ftmsBelt.state
        }
        if sample != Sample() { emit(.sample(sample)) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.notice("Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn {
            resume()
        } else {
            // Peripherals are invalid from here on, so there's nothing to disconnect.
            reset()
            connection = .unavailable(unavailability(of: central.state))
        }
    }

    /// Why a manager that isn't powered on can't be used.
    ///
    /// The manager stays in `.unknown` for as long as the permission prompt is unanswered, which
    /// reads like a broken Bluetooth unless the authorization is checked too.
    private func unavailability(of state: CBManagerState) -> Connection.Unavailability {
        switch state {
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown, .resetting: CBManager.authorization == .notDetermined ? .permissionPending : .unknown
        default: .unknown
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
            known[peripheral.identifier] = peripheral
            candidates.append(Candidate(id: peripheral.identifier, name: name, isLikelyTreadmill: isLikely))
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
}

// MARK: - CBPeripheralDelegate

extension BluetoothLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            // Usually the link dropped mid-discovery; the disconnection callback takes it from here.
            log.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let offered = peripheral.services ?? []
        let available = WireProtocol.allCases.filter { candidate in
            offered.contains { candidate.services.contains($0.uuid) }
        }
        let preferred = defaults.string(forKey: DefaultsKey.wireProtocol).flatMap(WireProtocol.init)
        guard let chosen = available.first(where: { $0 == preferred }) ?? available.first,
            let service = offered.first(where: { chosen.services.contains($0.uuid) })
        else {
            log.notice("\(peripheral.name ?? "?", privacy: .public) offers no supported service")
            rejected.insert(peripheral.identifier)
            forget()
            return
        }
        activeProtocol = chosen
        emit(.protocols(available: available, active: chosen))
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
            write(FTMS.requestControl)
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
                emit(.sample(Sample(belt: ftmsBelt.state)))
            }
        case (.ftms, FTMS.controlPoint):
            if FTMS.isStartRejection(data) {
                ftmsBelt.startCancelled()
                emit(.sample(Sample(belt: ftmsBelt.state)))
            }
        case (.ftms, FTMS.speedRange):
            if let supported = FTMS.parseSpeedRange(data), supported.range.upperBound > 0 {
                emit(.speedRange(supported.range))
            }
        case (.ftms, FTMS.inclineRange):
            if let supported = FTMS.parseInclineRange(data) {
                inclineIsMotorized = supported.range.upperBound > supported.range.lowerBound
                emit(.inclineRange(supported.range, step: max(supported.step, 0.5)))
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

extension WireProtocol {
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
