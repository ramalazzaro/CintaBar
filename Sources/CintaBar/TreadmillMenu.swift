import ServiceManagement
import SwiftUI
import TreadmillKit

/// The menu bar item: the icon, plus the speed while the belt is moving.
struct MenuBarLabel: View {
    let treadmill: Treadmill

    var body: some View {
        Image(systemName: "figure.walk.treadmill")
            .accessibilityLabel("CintaBar")
        if treadmill.isMoving {
            Text(treadmill.speed, format: .number.precision(.fractionLength(1)))
        }
    }
}

/// The menu shown when the menu bar item is clicked.
struct TreadmillMenu: View {
    let treadmill: Treadmill
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(headline)
        if treadmill.session.elapsed > 0 {
            Text(sessionSummary)
        }
        Divider()

        if treadmill.isReady {
            controls
            Divider()
        }
        deviceItems

        Toggle(
            "Open at Login",
            isOn: Binding {
                opensAtLogin
            } set: {
                setOpensAtLogin($0)
            })
        Divider()
        Button("Quit CintaBar") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - Sections

    @ViewBuilder private var controls: some View {
        switch treadmill.belt {
        case .idle, .safetyKey, .fault:
            Button("Start") { treadmill.start() }
            Menu("Start At") {
                ForEach(speedPresets, id: \.self) { preset in
                    Button(format(speed: preset)) { treadmill.start(at: preset) }
                }
            }
        case .running:
            // Stop comes first so it's the closest item to the pointer when the menu opens.
            Button("Stop") { treadmill.stop() }
            Button("Pause") { treadmill.pause() }
            Divider()
            Button("Faster (+\(format(speed: 0.5)))") { treadmill.setSpeed(treadmill.targetSpeed + 0.5) }
            Button("Slower (−\(format(speed: 0.5)))") { treadmill.setSpeed(treadmill.targetSpeed - 0.5) }
            Menu("Speed") {
                Button("Increase by \(format(speed: 0.1))") { treadmill.setSpeed(treadmill.targetSpeed + 0.1) }
                Button("Decrease by \(format(speed: 0.1))") { treadmill.setSpeed(treadmill.targetSpeed - 0.1) }
                Divider()
                ForEach(speedPresets, id: \.self) { preset in
                    Toggle(format(speed: preset), isOn: isCurrent(preset, treadmill.targetSpeed, treadmill.setSpeed))
                }
            }
            if treadmill.inclineRange.upperBound > treadmill.inclineRange.lowerBound {
                Menu("Incline") {
                    ForEach(inclinePresets, id: \.self) { preset in
                        Toggle(
                            preset.formatted(), isOn: isCurrent(preset, treadmill.targetIncline, treadmill.setIncline))
                    }
                }
            }
        case .paused:
            Button("Resume") { treadmill.start() }
            Button("Stop") { treadmill.stop() }
        case .countdown:
            Button("Stop") { treadmill.stop() }
        case .stopping, .calibrating:
            EmptyView()
        }
    }

    private var likelyTreadmills: [Treadmill.Candidate] { treadmill.candidates.filter(\.isLikelyTreadmill) }
    private var otherDevices: [Treadmill.Candidate] { treadmill.candidates.filter { !$0.isLikelyTreadmill } }

    @ViewBuilder private var deviceItems: some View {
        switch treadmill.connection {
        case .searching, .searchEnded:
            ForEach(likelyTreadmills) { candidate in
                Button("Connect to \(candidate.name)") { treadmill.connect(to: candidate) }
            }
            // A treadmill that advertises nothing recognizable can still be picked by name.
            if !otherDevices.isEmpty {
                Menu("Other Devices") {
                    ForEach(otherDevices) { candidate in
                        Button(candidate.name) { treadmill.connect(to: candidate) }
                    }
                }
            }
            if treadmill.connection == .searchEnded {
                Button("Search Again") { treadmill.search() }
            }
            Divider()
        case .waiting(let name), .ready(let name):
            if treadmill.availableProtocols.count > 1 {
                Picker(
                    "Protocol",
                    selection: Binding {
                        treadmill.activeProtocol
                    } set: {
                        $0.map(treadmill.use)
                    }
                ) {
                    ForEach(treadmill.availableProtocols) { wireProtocol in
                        Text(wireProtocol.rawValue).tag(Optional(wireProtocol))
                    }
                }
            }
            Button("Forget \(name)") { treadmill.forget() }
            Divider()
        case .unavailable:
            EmptyView()
        }
    }

    // MARK: - Text

    private var headline: String {
        switch treadmill.connection {
        case .unavailable(.poweredOff):
            "Bluetooth is off"
        case .unavailable(.unauthorized):
            "Allow Bluetooth for CintaBar in System Settings › Privacy & Security"
        case .unavailable(.unsupported):
            "This Mac doesn’t support Bluetooth LE"
        case .unavailable:
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
        let elapsed = treadmill.session.elapsed
        let time = Duration.seconds(elapsed)
            .formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
        let distance = Measurement(value: treadmill.session.distance, unit: UnitLength.kilometers)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
        return "\(time) · \(distance)"
    }

    private func format(speed: Double) -> String {
        Measurement(value: speed, unit: UnitSpeed.kilometersPerHour)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
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

    /// A binding that checks the menu item matching the current value and sets it when chosen.
    private func isCurrent(_ preset: Double, _ current: Double, _ choose: @escaping (Double) -> Void) -> Binding<Bool> {
        Binding {
            abs(current - preset) < 0.05
        } set: { _ in
            choose(preset)
        }
    }

    // MARK: - Login item

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration needs the user's approval; send them where they can give it.
            SMAppService.openSystemSettingsLoginItems()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
