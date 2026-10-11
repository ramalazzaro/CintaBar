import AppKit
import ServiceManagement
import TreadmillKit

/// The menu bar item and its menu.
///
/// It's built with AppKit rather than SwiftUI's `MenuBarExtra` so that rows can change while the
/// menu is open: AppKit redraws a menu item whose title changes and leaves the rest alone, whereas
/// SwiftUI rebuilds the whole menu, which closes any open submenu. Only a change to the menu's
/// *structure*, such as the belt stopping, rebuilds it here.
final class StatusMenuController: NSObject, NSMenuDelegate {
    /// What the menu bar item can show next to its icon.
    enum LabelField: String, CaseIterable {
        case speed, time, distance

        var title: String {
            switch self {
            case .speed: "Speed"
            case .time: "Time"
            case .distance: "Distance"
            }
        }
    }

    private let treadmill: Treadmill
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var isMenuOpen = false
    /// What the menu's items were built from. A change to any of it needs a rebuild.
    private var builtFor: Layout?
    private var headlineItem: NSMenuItem?
    private var sessionItem: NSMenuItem?
    private var presetItems: [PresetItem] = []
    /// Candidates already in the menu, and where the next "Connect to …" row goes. Devices turn
    /// up one at a time during a search, and each is slotted in without rebuilding the menu.
    private var shownCandidates: [Candidate] = []
    private var nextCandidateIndex = 0
    private var otherDevicesMenu: NSMenu?

    private static let labelFieldsKey = "menuBarFields"

    /// Everything that decides which items the menu has, as opposed to what they say.
    private struct Layout: Equatable {
        let connection: Connection
        let phase: Phase
        let showsSession: Bool
        let availableProtocols: [WireProtocol]
        let activeProtocol: WireProtocol?
        let speedRange: ClosedRange<Double>
        let inclineRange: ClosedRange<Double>
        let inclineStep: Double
        let labelFields: [LabelField]

        enum Phase {
            case idle, countdown, running, stopping, paused, safetyKey, calibrating, fault
        }
    }

    private struct PresetItem {
        let item: NSMenuItem
        let value: Double
        let axis: Axis

        enum Axis { case speed, incline }
    }

    /// The closure behind a menu item, kept in its `representedObject`.
    private final class Handler {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    init(treadmill: Treadmill) {
        self.treadmill = treadmill
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.walk.treadmill", accessibilityDescription: "CintaBar")
            // Monospaced digits keep the item from jiggling as the numbers change.
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        observe()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - Updating

    /// Re-renders on every change to the model, then arms itself again.
    private func observe() {
        withObservationTracking {
            _ = layout
            _ = headline
            _ = sessionSummary
            _ = labelText
            _ = treadmill.candidates
            _ = treadmill.targetSpeed
            _ = treadmill.targetIncline
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        updateButton()
        guard isMenuOpen else { return }
        guard layout == builtFor else {
            rebuild()
            return
        }
        headlineItem?.title = headline
        sessionItem?.title = sessionSummary
        updatePresetStates()
        for candidate in treadmill.candidates where !shownCandidates.contains(candidate) {
            insert(candidate)
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let text = labelText
        if button.title != text { button.title = text }
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    private func updatePresetStates() {
        for preset in presetItems {
            let current = preset.axis == .speed ? treadmill.targetSpeed : treadmill.targetIncline
            preset.item.state = abs(current - preset.value) < 0.05 ? .on : .off
        }
    }

    // MARK: - Building

    private func rebuild() {
        menu.removeAllItems()
        presetItems = []

        headlineItem = menu.addItem(label: headline)
        sessionItem = treadmill.session.elapsed > 0 ? menu.addItem(label: sessionSummary) : nil
        menu.addItem(.separator())
        if treadmill.isReady {
            addControls()
            menu.addItem(.separator())
        }
        addDeviceItems()
        addPreferences()
        menu.addItem(.separator())
        menu.addItem(item("Quit CintaBar", key: "q") { NSApp.terminate(nil) })

        builtFor = layout
    }

    private func addControls() {
        let treadmill = treadmill
        switch treadmill.belt {
        case .idle, .safetyKey, .fault:
            menu.addItem(item("Start") { treadmill.start() })
            let startAt = menu.addSubmenu("Start At")
            for preset in speedPresets {
                startAt.addItem(item(format(speed: preset)) { treadmill.start(at: preset) })
            }
        case .running:
            // Stop comes first so it's the closest item to the pointer when the menu opens.
            menu.addItem(item("Stop") { treadmill.stop() })
            menu.addItem(item("Pause") { treadmill.pause() })
            menu.addItem(.separator())
            menu.addItem(item("Faster (+\(format(speed: 0.5)))") { treadmill.setSpeed(treadmill.targetSpeed + 0.5) })
            menu.addItem(item("Slower (−\(format(speed: 0.5)))") { treadmill.setSpeed(treadmill.targetSpeed - 0.5) })
            let speed = menu.addSubmenu("Speed")
            speed.addItem(item("Increase by \(format(speed: 0.1))") { treadmill.setSpeed(treadmill.targetSpeed + 0.1) })
            speed.addItem(item("Decrease by \(format(speed: 0.1))") { treadmill.setSpeed(treadmill.targetSpeed - 0.1) })
            speed.addItem(.separator())
            for preset in speedPresets {
                let presetItem = item(format(speed: preset)) { treadmill.setSpeed(preset) }
                presetItems.append(PresetItem(item: presetItem, value: preset, axis: .speed))
                speed.addItem(presetItem)
            }
            if treadmill.inclineRange.upperBound > treadmill.inclineRange.lowerBound {
                let incline = menu.addSubmenu("Incline")
                for preset in inclinePresets {
                    let presetItem = item(preset.formatted()) { treadmill.setIncline(preset) }
                    presetItems.append(PresetItem(item: presetItem, value: preset, axis: .incline))
                    incline.addItem(presetItem)
                }
            }
            updatePresetStates()
        case .paused:
            menu.addItem(item("Resume") { treadmill.start() })
            menu.addItem(item("Stop") { treadmill.stop() })
        case .countdown:
            menu.addItem(item("Stop") { treadmill.stop() })
        case .stopping, .calibrating:
            break
        }
    }

    private func addDeviceItems() {
        let treadmill = treadmill
        switch treadmill.connection {
        case .searching, .searchEnded:
            shownCandidates = []
            otherDevicesMenu = nil
            nextCandidateIndex = menu.numberOfItems
            for candidate in treadmill.candidates {
                insert(candidate)
            }
            if treadmill.connection == .searchEnded {
                menu.addItem(item("Search Again") { treadmill.search() })
            }
            menu.addItem(.separator())
        case .waiting(let name), .ready(let name):
            if treadmill.availableProtocols.count > 1 {
                let submenu = menu.addSubmenu("Protocol")
                for wireProtocol in treadmill.availableProtocols {
                    let choice = item(wireProtocol.rawValue) { treadmill.use(wireProtocol) }
                    choice.state = wireProtocol == treadmill.activeProtocol ? .on : .off
                    submenu.addItem(choice)
                }
            }
            menu.addItem(item("Forget \(name)") { treadmill.forget() })
            menu.addItem(.separator())
        case .unavailable:
            break
        }
    }

    /// Slots a found device into the menu, leaving every other item alone.
    private func insert(_ candidate: Candidate) {
        let treadmill = treadmill
        if candidate.isLikelyTreadmill {
            let row = item("Connect to \(candidate.name)") { treadmill.connect(to: candidate) }
            menu.insertItem(row, at: nextCandidateIndex)
            nextCandidateIndex += 1
        } else {
            // A treadmill that advertises nothing recognizable can still be picked by name. The
            // submenu sits right after the likely treadmills, which keep being inserted above it.
            let submenu = otherDevicesMenu ?? menu.addSubmenu("Other Devices", at: nextCandidateIndex)
            otherDevicesMenu = submenu
            submenu.addItem(item(candidate.name) { treadmill.connect(to: candidate) })
        }
        shownCandidates.append(candidate)
    }

    private func addPreferences() {
        let shows = menu.addSubmenu("Show in Menu Bar")
        for field in LabelField.allCases {
            let choice = item(field.title) { [weak self] in self?.toggle(field) }
            choice.state = labelFields.contains(field) ? .on : .off
            shows.addItem(choice)
        }

        let login = item("Open at Login") { [weak self] in self?.toggleOpensAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
    }

    private func item(_ title: String, key: String = "", action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runHandler(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = Handler(action)
        return item
    }

    @objc private func runHandler(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.run()
    }

    // MARK: - State

    private var layout: Layout {
        let phase: Layout.Phase =
            switch treadmill.belt {
            case .idle: .idle
            case .countdown: .countdown
            case .running: .running
            case .stopping: .stopping
            case .paused: .paused
            case .safetyKey: .safetyKey
            case .calibrating: .calibrating
            case .fault: .fault
            }
        return Layout(
            connection: treadmill.connection, phase: phase, showsSession: treadmill.session.elapsed > 0,
            availableProtocols: treadmill.availableProtocols,
            activeProtocol: treadmill.activeProtocol, speedRange: treadmill.speedRange,
            inclineRange: treadmill.inclineRange, inclineStep: treadmill.inclineStep, labelFields: labelFields)
    }

    private var likelyTreadmills: [Candidate] { treadmill.candidates.filter(\.isLikelyTreadmill) }

    /// The fields shown in the menu bar, in a fixed order. Speed by default.
    private var labelFields: [LabelField] {
        get {
            guard let saved = defaults.array(forKey: Self.labelFieldsKey) as? [String] else { return [.speed] }
            return LabelField.allCases.filter { saved.contains($0.rawValue) }
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: Self.labelFieldsKey) }
    }

    private func toggle(_ field: LabelField) {
        var fields = labelFields
        if let index = fields.firstIndex(of: field) {
            fields.remove(at: index)
        } else {
            fields.append(field)
        }
        labelFields = LabelField.allCases.filter(fields.contains)
        refresh()
    }

    private func toggleOpensAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration needs the user's approval; send them where they can give it.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - Text

    private var labelText: String {
        var parts: [String] = []
        for field in labelFields {
            switch field {
            case .speed where treadmill.isMoving:
                parts.append(format(speed: treadmill.speed))
            case .time where treadmill.session.elapsed > 0:
                parts.append(format(elapsed: treadmill.session.elapsed))
            case .distance where treadmill.session.elapsed > 0:
                parts.append(format(distance: treadmill.session.distance))
            default:
                break
            }
        }
        return parts.joined(separator: " · ")
    }

    private var headline: String {
        switch treadmill.connection {
        case .unavailable(.poweredOff):
            "Bluetooth is off"
        case .unavailable(.unauthorized):
            "Allow Bluetooth for CintaBar in System Settings › Privacy & Security"
        case .unavailable(.unsupported):
            "This Mac doesn’t support Bluetooth LE"
        case .unavailable(.unknown):
            "Bluetooth isn’t available"
        case .searching where likelyTreadmills.isEmpty:
            "Searching for treadmills…"
        case .searchEnded where likelyTreadmills.isEmpty:
            "No treadmill found"
        case .searching, .searchEnded:
            "Choose your treadmill"
        case .waiting(let name):
            "Waiting for \(name)…"
        case .ready(let name):
            switch treadmill.belt {
            case .idle: "\(name) is ready"
            case .countdown(let remaining): remaining > 0 ? "Starting in \(remaining)…" : "Starting…"
            case .running: format(speed: treadmill.speed)
            case .stopping: "Stopping…"
            case .paused: "Paused"
            case .safetyKey: "Safety key removed"
            case .calibrating: "Calibrating…"
            case .fault(let code): "Treadmill error E\(code)"
            }
        }
    }

    private var sessionSummary: String {
        "\(format(elapsed: treadmill.session.elapsed)) · \(format(distance: treadmill.session.distance))"
    }

    private func format(speed: Double) -> String {
        Measurement(value: speed, unit: UnitSpeed.kilometersPerHour)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    private func format(distance: Double) -> String {
        Measurement(value: distance, unit: UnitLength.kilometers)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    private func format(elapsed: Int) -> String {
        Duration.seconds(elapsed).formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    // MARK: - Presets

    /// Every half km/h the treadmill supports, or every whole one when that would make the menu
    /// too long.
    private var speedPresets: [Double] {
        let range = treadmill.speedRange
        let step = range.upperBound - range.lowerBound > 10 ? 1.0 : 0.5
        let first = (range.lowerBound / step).rounded(.up) * step
        return Array(stride(from: first, through: range.upperBound, by: step))
    }

    private var inclinePresets: [Double] {
        Array(
            stride(
                from: treadmill.inclineRange.lowerBound, through: treadmill.inclineRange.upperBound,
                by: treadmill.inclineStep))
    }
}

extension NSMenu {
    /// Adds a row of text that can't be chosen.
    @discardableResult
    fileprivate func addItem(label title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }

    /// Adds a submenu, at the end unless an index is given.
    fileprivate func addSubmenu(_ title: String, at index: Int? = nil) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        insertItem(item, at: index ?? numberOfItems)
        return submenu
    }
}
