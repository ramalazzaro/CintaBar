import Foundation
import Observation

/// The treadmill as the user interface sees it: what it's doing, and the commands it takes.
///
/// It's protocol agnostic. A ``TreadmillLink`` does the talking and reports back with
/// ``LinkEvent``s.
@MainActor @Observable
public final class Treadmill {
    /// In effect until the treadmill reports what it supports. Deliberately low.
    public static let defaultSpeedRange = 1.0...6.0
    public static let kilometersPerMile = 1.609344
    /// How long a belt gets to show it's pausing before the treadmill is taken to ignore a pause:
    /// a few reports in either protocol, and time for a belt to start slowing down.
    public static let pauseTimeout = Duration.seconds(4)

    public private(set) var connection = Connection.unavailable(.unknown)
    /// Devices found by the current search.
    public private(set) var candidates: [Candidate] = []
    /// The protocols the connected treadmill offers.
    public private(set) var availableProtocols: [WireProtocol] = []
    public private(set) var activeProtocol: WireProtocol?
    /// The speeds the treadmill supports, in km/h.
    public private(set) var speedRange = Treadmill.defaultSpeedRange
    /// The inclines the treadmill supports; empty when the incline isn't motorized.
    public private(set) var inclineRange = 0.0...0.0
    public private(set) var inclineStep = 1.0

    /// What the belt is doing, as the treadmill reports it, except that a belt stopped in place of
    /// a pause is paused rather than idle.
    public private(set) var belt = BeltState.idle
    /// Belt speed in km/h, as reported by the treadmill.
    public private(set) var speed = 0.0
    /// Incline as reported by the treadmill: a level for FitShow, percent for FTMS.
    public private(set) var incline = 0.0
    /// Heart rate in beats per minute, or `nil` while the treadmill has no reading.
    public private(set) var heartRate: Int?
    public private(set) var session = Session()
    /// Whether the connected treadmill acknowledges a pause and keeps the belt running, as the
    /// Noga FT-200 does over FTMS. Such a treadmill is paused by stopping the belt; see ``pause()``.
    ///
    /// It's learned from the first pause, and the link remembers it for that treadmill.
    public private(set) var ignoresPause = false

    /// The fastest speed the app asks for, in km/h, or `nil` to go as fast as the treadmill does.
    ///
    /// It caps every speed sent from now on. It doesn't slow down a belt that's already faster,
    /// and the treadmill's own console isn't bound by it.
    public var speedLimit: Double?
    /// Whether a runaway warning nobody answers ends with the belt being stopped. Turning it off
    /// also calls off a countdown that's under way.
    public var stopsRunawayBelt = true {
        didSet {
            guard !stopsRunawayBelt, case .warning(let requested, _?) = runaway else { return }
            cancelCountdown()
            runaway = .warning(requested: requested, secondsUntilStop: nil)
        }
    }
    /// What the runaway guard has to say, until the user answers it or it stops being true.
    public private(set) var runaway: Runaway?

    /// The treadmills that take and report speed in mph, by name. The app saves it and hands it
    /// back at launch.
    ///
    /// It's a list rather than one switch so that forgetting a treadmill and choosing it again
    /// can't quietly turn the switch off, which would have the belt run 60% faster than asked.
    public var treadmillsSpeakingMiles: Set<String> = [] {
        didSet { updateUnit() }
    }

    /// Whether the connected treadmill takes and reports speed in mph, where both protocols say
    /// km/h. Nothing it reports gives that away, so the user has to say.
    ///
    /// Everything here stays in km/h either way: speeds are converted as they arrive from the
    /// link and as they leave for it.
    public var speaksMiles: Bool {
        get { unit != 1 }
        set {
            guard case .ready(let name) = connection else { return }
            if newValue {
                treadmillsSpeakingMiles.insert(name)
            } else {
                treadmillsSpeakingMiles.remove(name)
            }
        }
    }

    public var isReady: Bool {
        if case .ready = connection { true } else { false }
    }

    public var isMoving: Bool { belt == .running || belt == .stopping }
    /// The speed asked for, until the treadmill reaches it; then the speed it reports.
    public var targetSpeed: Double { requestedSpeed?.value ?? speed }
    public var targetIncline: Double { requestedIncline?.value ?? incline }

    /// One of the treadmill's speed units in km/h: a mile when it speaks mph, otherwise 1.
    private var unit = 1.0
    @ObservationIgnored private var reportedSpeedRange: ClosedRange<Double>?
    @ObservationIgnored private var requestedSpeed: Target?
    @ObservationIgnored private var requestedIncline: Target?
    @ObservationIgnored private var speedAfterStart: Target?
    @ObservationIgnored private var inclineAfterStart: Target?
    /// What the treadmill last said the belt was doing, which ``belt`` repeats unless a pause is
    /// being emulated.
    @ObservationIgnored private var reportedBelt = BeltState.idle
    @ObservationIgnored private var pauseCheck: PauseCheck?
    @ObservationIgnored private var pauseTimer: (@MainActor () -> Void)?
    @ObservationIgnored private var emulatedPause: EmulatedPause?
    @ObservationIgnored private var runawayGuard: RunawayGuard?
    @ObservationIgnored private var graceTimer: (@MainActor () -> Void)?
    @ObservationIgnored private var countdownTimer: (@MainActor () -> Void)?
    private let link: any TreadmillLink
    private let scheduler: Scheduler

    /// Runs `action` after `delay`, unless the closure it returns is called first.
    public typealias Scheduler =
        @MainActor (_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// A value asked for from the menu.
    ///
    /// It stands until the treadmill reaches it or it expires. After that the treadmill's own
    /// report wins, because the console and the remote can change the same value. The default
    /// allowance covers a belt ramping across its whole speed range.
    private struct Target {
        let value: Double
        private let deadline: ContinuousClock.Instant

        init(_ value: Double, validFor duration: Duration = .seconds(40)) {
            self.value = value
            deadline = .now + duration
        }

        var isExpired: Bool { .now > deadline }

        func isSettled(by reported: Double) -> Bool { abs(reported - value) < 0.05 || isExpired }
    }

    /// A pause sent to a treadmill that may ignore it, watched for the belt slowing down.
    private struct PauseCheck {
        /// The belt speed reported as the pause was sent, in km/h.
        var reportedSpeed: Double
        /// What to resume at, should the pause have to be emulated: km/h, and the incline.
        var speed: Double
        let incline: Double
        /// Whether the belt has been reported running since, no slower than it was.
        var keptGoing = false
    }

    /// A pause stood in for by stopping the belt, on a treadmill that ignores the real thing.
    private struct EmulatedPause {
        /// What resuming goes back to: the speed the belt had, in km/h, and its incline.
        var speed: Double
        let incline: Double
        /// Whether the belt has come to a stop since. Until it has, a running belt is slowing down.
        var hasStopped = false
        /// Whether the app asked to resume, and the belt is on its way.
        var isResuming = false
    }

    /// - Parameter scheduler: What the runaway guard and the pause check keep time with. Tests
    ///   pass their own, to move its clock by hand.
    public init(link: any TreadmillLink, scheduler: @escaping Scheduler = Treadmill.schedule) {
        self.link = link
        self.scheduler = scheduler
        link.eventHandler = { [weak self] event in self?.handle(event) }
    }

    /// The scheduler used outside tests.
    ///
    /// It's a task rather than a `Timer` because a timer waits for the run loop's default mode,
    /// and the main actor also runs while a menu is open or a window is modal.
    public static func schedule(
        after delay: Duration, _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task {
            try? await Task.sleep(for: delay, tolerance: .zero)
            if !Task.isCancelled { action() }
        }
        return { task.cancel() }
    }

    // MARK: - Commands

    /// Starts the belt, or resumes it after a pause. The treadmill runs its own countdown first.
    ///
    /// Resuming a pause that stopped the belt goes back to the speed and incline it had.
    ///
    /// - Parameter speed: The speed to go to once the belt is moving, in km/h. Pass `nil` to stay
    ///   at the speed the treadmill starts with, or to resume at the one it was paused at.
    public func start(at speed: Double? = nil) {
        guard isReady else { return }
        if let paused = emulatedPause {
            emulatedPause?.isResuming = true
            speedAfterStart = Target(clamp(speed ?? paused.speed), validFor: .seconds(20))
            inclineAfterStart = Target(paused.incline, validFor: .seconds(20))
        } else {
            speedAfterStart = speed.map { Target(clamp($0), validFor: .seconds(20)) }
            inclineAfterStart = nil
        }
        link.send(.start)
    }

    /// Pauses the belt.
    ///
    /// Some treadmills acknowledge a pause and keep the belt running, as the Noga FT-200 does over
    /// FTMS. So a pause is watched, and if the belt is still going as fast after ``pauseTimeout``,
    /// the treadmill is taken to ignore pausing and the link is asked to remember that. From then
    /// on, that pause included, the belt is stopped instead: ``belt`` reads paused once it has,
    /// the session is held, and ``start(at:)`` goes back to the speed and incline it had.
    public func pause() {
        // A pause still being checked, or emulated, is already on its way.
        guard isReady, belt == .running, pauseCheck == nil, emulatedPause == nil else { return }
        let (speed, incline) = (targetSpeed, targetIncline)
        if ignoresPause {
            emulatePause(speed: speed, incline: incline)
            return
        }
        link.send(.pause)
        cancelRequests()
        pauseCheck = PauseCheck(reportedSpeed: self.speed, speed: speed, incline: incline)
        pauseTimer = scheduler(Self.pauseTimeout) { [weak self] in self?.pauseCheckTimedOut() }
    }

    /// Stops the belt. It also answers a runaway warning, and nothing about one holds it up.
    public func stop() {
        guard isReady else { return }
        link.send(.stop)
        speedAfterStart = nil
        inclineAfterStart = nil
        cancelRequests()
        runaway = nil
        endPauseCheck()
        if emulatedPause != nil {
            // The treadmill took the belt stopping for the end of its workout, and now it is.
            emulatedPause = nil
            session = Session()
            showBelt()
        }
    }

    /// Sets the belt speed in km/h, clamped to what the treadmill supports and to the speed limit.
    ///
    /// Asking for one calls off a pause that hasn't shown yet: whoever asks wants to keep going. A
    /// belt slowing down for an emulated pause is left to stop.
    public func setSpeed(_ speed: Double) {
        guard isReady, belt == .running, emulatedPause == nil else { return }
        endPauseCheck()
        requestedSpeed = Target(clamp(speed))
        sendTarget()
    }

    public func setIncline(_ incline: Double) {
        guard isReady, belt == .running, emulatedPause == nil else { return }
        endPauseCheck()
        requestedIncline = Target(clamp(incline: incline))
        sendTarget()
    }

    /// Closes the runaway warning without stopping the belt: the answer to "keep going". The
    /// guard then stays quiet until the app next asks for a speed.
    public func acknowledgeRunaway() {
        disarm()
        runaway = nil
    }

    public func use(_ wireProtocol: WireProtocol) { link.use(wireProtocol) }
    public func connect(to candidate: Candidate) { link.connect(to: candidate.id) }
    public func search() { link.search() }
    public func forget() { link.forget() }
    public func disconnect() { link.disconnect() }

    /// Sends the speed and incline wanted, and puts the runaway guard on the speed.
    private func sendTarget() {
        // An incline change repeats the reported speed, which the console may have taken past
        // the limit.
        let speed = min(targetSpeed, fastest)
        disarm()
        runawayGuard = RunawayGuard(requested: speed, from: self.speed)
        // In the treadmill's unit, to a hundredth: as fine as either protocol goes, and it sheds
        // what the conversion left in the last digits.
        link.send(.target(speed: (speed / unit * 100).rounded() / 100, incline: targetIncline))
    }

    /// Drops what was asked for.
    ///
    /// Nothing asked of one run carries over to the next, which starts at the treadmill's own
    /// speed: against a stale target, "slower" would be a jump up to it.
    private func cancelRequests() {
        requestedSpeed = nil
        requestedIncline = nil
        disarm()
    }

    // MARK: - Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .connection(let connection):
            self.connection = connection
            // Nothing can be sent now, which is when a warning matters most: it stays up to say so.
            if !isReady, case .warning = runaway { runaway = .unreachable }
            updateUnit()
            if !isReady {
                cancelRequests()
                speedAfterStart = nil
                inclineAfterStart = nil
                endPauseCheck()
                emulatedPause = nil
                if ignoresPause { ignoresPause = false }
                reportedSpeedRange = nil
                updateSpeedRange()
                inclineRange = 0...0
                inclineStep = 1
                record(Sample(belt: .idle, speed: 0, incline: 0, heartRate: 0))
                session = Session()
            }
        case .candidates(let candidates):
            self.candidates = candidates
        case .protocols(let available, let active):
            availableProtocols = available
            activeProtocol = active
        case .speedRange(let range):
            reportedSpeedRange = range
            updateSpeedRange()
        case .inclineRange(let range, let step):
            inclineRange = range
            inclineStep = step
        case .sample(let sample):
            record(sample)
        case .ignoresPause(let ignoresPause):
            if ignoresPause != self.ignoresPause { self.ignoresPause = ignoresPause }
        }
    }

    /// Stores what the treadmill reported, touching only what changed so observers aren't told
    /// about identical samples.
    private func record(_ sample: Sample) {
        let wasRunning = belt == .running
        var resumed = false
        if let reported = sample.belt {
            reportedBelt = reported
            resumed = followEmulatedPause()
        }
        showBelt()
        if let speed = sample.speed.map({ $0 * unit }), speed != self.speed { self.speed = speed }
        if let incline = sample.incline, incline != self.incline { self.incline = incline }
        if let reported = sample.heartRate {
            // Zero is how a treadmill says nobody is holding its sensors.
            let heartRate = reported > 0 ? reported : nil
            if heartRate != self.heartRate { self.heartRate = heartRate }
        }
        var updated = session
        // The workout goes on, whatever the treadmill did to its own counts while it was paused.
        if resumed { updated.isHeld = false }
        if let elapsed = sample.elapsed {
            // A treadmill that speaks miles may well count them too. Its distance is left out, to
            // be worked out from the converted speed instead.
            updated.record(elapsed: elapsed, speed: speed, distance: speaksMiles ? nil : sample.distance)
        }
        // After the clock, so a new workout doesn't start with the last one's totals.
        updated.record(calories: sample.calories, steps: sample.steps)
        if updated != session { session = updated }
        watchPause(after: sample)

        guard belt == .running else {
            cancelRequests()
            return
        }
        if requestedSpeed?.isSettled(by: speed) == true { requestedSpeed = nil }
        if requestedIncline?.isSettled(by: incline) == true { requestedIncline = nil }
        if !wasRunning { goToWhatWasAskedAtStart() }
        watchForRunaway()
    }

    /// Sends the speed and incline asked for as the belt was started, now that it's moving.
    private func goToWhatWasAskedAtStart() {
        let (speed, incline) = (speedAfterStart, inclineAfterStart)
        (speedAfterStart, inclineAfterStart) = (nil, nil)
        var asked = false
        if let speed, !speed.isExpired {
            requestedSpeed = Target(clamp(speed.value))
            asked = true
        }
        if let incline, !incline.isExpired {
            requestedIncline = Target(clamp(incline: incline.value))
            asked = true
        }
        if asked { sendTarget() }
    }

    // MARK: - Pause

    /// Stops the belt in place of a pause, to resume at `speed`, in km/h, and `incline`.
    ///
    /// The session is held from here, though the belt takes a moment to stop: some treadmills
    /// start their counts over as it does, and not always in the report that says it stopped.
    private func emulatePause(speed: Double, incline: Double) {
        link.send(.stop)
        cancelRequests()
        emulatedPause = EmulatedPause(speed: speed, incline: incline)
        session.isHeld = true
        showBelt()
    }

    /// Follows the belt through an emulated pause, which ends once it runs again, and says whether
    /// it just did. That may be the console's doing rather than a resume from here, and then the
    /// belt is left at whatever speed it starts at.
    private func followEmulatedPause() -> Bool {
        guard var pause = emulatedPause else { return false }
        switch reportedBelt {
        case .idle:
            pause.hasStopped = true
        case .running where pause.hasStopped || pause.isResuming:
            emulatedPause = nil
            return true
        default:
            break
        }
        emulatedPause = pause
        return false
    }

    /// Brings ``belt`` up to date: what the treadmill reports, except that a belt stopped for an
    /// emulated pause is paused rather than idle.
    private func showBelt() {
        let shown = emulatedPause != nil && reportedBelt == .idle ? BeltState.paused : reportedBelt
        if shown != belt { belt = shown }
    }

    /// Judges a pause being checked by the latest report. A belt that stops running or slows down
    /// didn't ignore it, whatever else it may be doing.
    private func watchPause(after sample: Sample) {
        guard var check = pauseCheck, sample.belt != nil || sample.speed != nil else { return }
        // A tenth of a km/h of slack, for a reading that wobbles.
        if belt == .running, speed > check.reportedSpeed - 0.1 {
            check.keptGoing = true
            pauseCheck = check
        } else {
            endPauseCheck()
        }
    }

    /// Ends a pause check that ran its course. A belt still running as fast as it was ignored the
    /// pause, and is stopped instead. One that went unreported proves nothing, and is left alone.
    private func pauseCheckTimedOut() {
        guard let check = pauseCheck else { return }
        endPauseCheck()
        guard check.keptGoing, belt == .running else { return }
        ignoresPause = true
        link.remember(ignoresPause: true)
        emulatePause(speed: check.speed, incline: check.incline)
    }

    private func endPauseCheck() {
        pauseCheck = nil
        pauseTimer?()
        pauseTimer = nil
    }

    // MARK: - Speed

    /// The fastest the app asks for, in km/h: the treadmill's maximum, or the speed limit if
    /// that's lower.
    private var fastest: Double {
        guard let speedLimit else { return speedRange.upperBound }
        // Down to a tenth in the treadmill's unit, so that rounding a request can't lift it past
        // the limit. The nudge keeps a limit that's already a tenth from landing on the one below.
        let limit = (speedLimit / unit * 10 + 1e-6).rounded(.down) / 10 * unit
        // A limit under the slowest the belt goes can only be kept by asking for that.
        return max(min(limit, speedRange.upperBound), speedRange.lowerBound)
    }

    /// The nearest speed the app may ask for, in km/h.
    ///
    /// It's rounded to a tenth in the treadmill's unit, so that what's sent is a speed its console
    /// could show and what it reports back matches. Then it's clamped, so an odd range limit
    /// can't be overshot by the rounding.
    private func clamp(_ speed: Double) -> Double {
        let rounded = (speed / unit * 10).rounded() / 10 * unit
        return min(max(rounded, speedRange.lowerBound), fastest)
    }

    private func clamp(incline: Double) -> Double {
        min(max(incline, inclineRange.lowerBound), inclineRange.upperBound)
    }

    /// Works out the unit again, after the connection or the list of mph treadmills changed.
    private func updateUnit() {
        var unit = 1.0
        if case .ready(let name) = connection, treadmillsSpeakingMiles.contains(name) {
            unit = Self.kilometersPerMile
        }
        guard unit != self.unit else { return }
        // What was asked for was worked out in the other unit.
        requestedSpeed = nil
        disarm()
        // What a pause holds on to was read in it, and stands for the same belt speed.
        let scale = unit / self.unit
        pauseCheck?.reportedSpeed *= scale
        pauseCheck?.speed *= scale
        emulatedPause?.speed *= scale
        speed *= scale
        self.unit = unit
        updateSpeedRange()
    }

    private func updateSpeedRange() {
        let range = reportedSpeedRange.map { $0.lowerBound * unit...$0.upperBound * unit } ?? Self.defaultSpeedRange
        if range != speedRange { speedRange = range }
    }

    // MARK: - Runaway guard

    /// Judges the speed just reported, raising the warning or taking it back.
    private func watchForRunaway() {
        guard var watching = runawayGuard else { return }
        let isRunaway = watching.isRunaway(speed)
        runawayGuard = watching

        if isRunaway {
            if case .warning = runaway { return }
            // The guard is needed for as long as the warning is up.
            graceTimer?()
            graceTimer = nil
            runaway = .warning(
                requested: watching.requested, secondsUntilStop: stopsRunawayBelt ? RunawayGuard.countdown : nil)
            if stopsRunawayBelt { countDown() }
        } else {
            standDown()
            if requestedSpeed == nil, graceTimer == nil {
                graceTimer = scheduler(RunawayGuard.grace) { [weak self] in self?.disarm() }
            }
        }
    }

    private func countDown() {
        countdownTimer = scheduler(.seconds(1)) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard case .warning(let requested, let seconds?) = runaway else { return }
        if seconds > 1 {
            runaway = .warning(requested: requested, secondsUntilStop: seconds - 1)
            countDown()
        } else {
            // The only command that's ever sent without a click. Stopping also disarms the guard,
            // so it's sent once.
            stop()
            runaway = .stopped(requested: requested)
        }
    }

    private func cancelCountdown() {
        countdownTimer?()
        countdownTimer = nil
    }

    /// Takes back a warning that's no longer true, along with the stop it was counting down to.
    private func standDown() {
        cancelCountdown()
        if case .warning = runaway { runaway = nil }
    }

    /// Stops watching, until the app next asks for a speed.
    private func disarm() {
        runawayGuard = nil
        graceTimer?()
        graceTimer = nil
        standDown()
    }
}
