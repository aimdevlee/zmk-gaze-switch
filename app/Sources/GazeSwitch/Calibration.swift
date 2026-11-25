import AppKit
import AVFoundation

/// A guided calibration: a full-screen overlay on the MacBook shows where to
/// look, and each instruction is also spoken, because for half the steps the
/// user is looking at the other computer and can't read this screen.
///
/// The steps deliberately mix postures for each target (natural, head held
/// straight with only the eyes moving, head turned away), so the model learns
/// the combination of head and eye signals rather than one habitual pose.
final class CalibrationSession: NSObject, AVSpeechSynthesizerDelegate {
    struct Step {
        var target: Target
        /// Short name used when reporting a step that didn't record well.
        var name: String
        /// Shown large on screen and spoken. nil = same posture, just a new dot.
        var instruction: String?
        /// Where the dot goes on the MacBook screen (0…1, y up). nil for the other computer.
        var dot: CGPoint?
        var collect: TimeInterval = 2.2
    }

    struct Result {
        var mac: [HeadPose]
        var other: [HeadPose]
        /// Steps where the face was mostly lost (e.g. head turned too far).
        var weakSteps: [String]
        /// Every recorded frame, grouped by posture, for the accuracy report.
        var groups: [(name: String, target: Target, samples: [HeadPose])] = []
    }

    static let steps: [Step] = [
        // Looking at the MacBook
        Step(target: .mac, name: "맥북·평소처럼", instruction: "평소처럼 편하게, 화면의 점을 보세요.", dot: CGPoint(x: 0.5, y: 0.42)),
        Step(target: .mac, name: "맥북·평소처럼", dot: CGPoint(x: 0.08, y: 0.42)),
        Step(target: .mac, name: "맥북·평소처럼", dot: CGPoint(x: 0.92, y: 0.42)),
        Step(target: .mac, name: "맥북·눈만 움직이기", instruction: "고개는 화면 정면에 고정하고, 눈만 움직여 점을 따라가세요.", dot: CGPoint(x: 0.06, y: 0.9)),
        Step(target: .mac, name: "맥북·눈만 움직이기", dot: CGPoint(x: 0.94, y: 0.9)),
        Step(target: .mac, name: "맥북·눈만 움직이기", dot: CGPoint(x: 0.5, y: 0.08)),
        Step(target: .mac, name: "맥북·고개는 다른 쪽", instruction: "고개를 다른 컴퓨터 쪽으로 돌린 채, 눈으로만 이 점을 보세요.", dot: CGPoint(x: 0.5, y: 0.42), collect: 3),
        // Looking at the other computer
        Step(target: .other, name: "다른 컴퓨터·평소처럼", instruction: "이제 평소처럼 편하게, 다른 컴퓨터 화면의 가운데를 보세요.", collect: 3),
        Step(target: .other, name: "다른 컴퓨터·양 끝", instruction: "다른 컴퓨터 화면의 왼쪽 끝과 오른쪽 끝을 천천히 번갈아 보세요.", collect: 4),
        Step(target: .other, name: "다른 컴퓨터·눈만 움직이기", instruction: "고개는 맥북 정면에 두고, 눈만 돌려서 다른 컴퓨터 화면을 보세요. 가능한 만큼만 하면 됩니다.", collect: 3),
        Step(target: .other, name: "다른 컴퓨터·고개 완전히", instruction: "고개를 다른 컴퓨터 쪽으로 완전히 돌려서 화면을 보세요.", collect: 3),
    ]

    /// nil when the user cancelled.
    var onFinish: ((Result?) -> Void)?
    /// A file-name label while a step is recording, nil otherwise (for eye snapshots).
    var onRecording: ((String?) -> Void)?

    private enum Phase { case announcing, settling, collecting }

    private var index = 0
    private var token = 0
    private var phase = Phase.announcing
    private var stepSamples: [HeadPose] = []
    private var result = Result(mac: [], other: [], weakSteps: [])

    private let synth = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "ko-KR")
    private var window: OverlayWindow?
    private var view: OverlayView?

    func start() {
        synth.delegate = self
        showOverlay()
        runStep()
    }

    /// Feed every camera frame here while the session is running.
    func ingest(_ pose: HeadPose?) {
        view?.setFaceVisible(pose != nil)
        if phase == .collecting, let pose { stepSamples.append(pose) }
    }

    func cancel() {
        tearDown()
        onFinish?(nil)
    }

    // MARK: - Sequencing

    private func after(_ seconds: TimeInterval, _ t: Int, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.token == t else { return }
            block()
        }
    }

    private func runStep() {
        guard index < Self.steps.count else { return finish() }
        let step = Self.steps[index]
        token += 1
        let t = token
        phase = .announcing
        view?.show(step, number: index + 1, of: Self.steps.count)

        guard let instruction = step.instruction else {
            // Same posture, new dot: just give the eyes time to get there.
            phase = .settling
            return after(1.0, t) { self.beginCollect(t) }
        }
        if let voice {
            let utterance = AVSpeechUtterance(string: instruction)
            utterance.voice = voice
            synth.speak(utterance)
            after(12, t) { self.beginSettle(t) }  // in case the finish callback never comes
        } else {
            after(3.5, t) { self.beginSettle(t) }  // no Korean voice installed: reading time
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let t = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token == t else { return }
            self.beginSettle(t)
        }
    }

    /// Time to actually move into the new posture after hearing it.
    private func beginSettle(_ t: Int) {
        guard token == t, phase == .announcing else { return }
        phase = .settling
        after(1.5, t) { self.beginCollect(t) }
    }

    private func beginCollect(_ t: Int) {
        guard token == t, phase == .settling else { return }
        phase = .collecting
        stepSamples = []
        NSSound(named: "Tink")?.play()
        view?.setCollecting(true)
        onRecording?(String(format: "s%02d-%@", index + 1, Self.steps[index].target.rawValue))
        after(Self.steps[index].collect, t) { self.endCollect() }
    }

    private func endCollect() {
        let step = Self.steps[index]
        phase = .announcing
        view?.setCollecting(false)
        onRecording?(nil)
        NSSound(named: "Pop")?.play()

        // ~10 frames/s: fewer than this means the face was mostly not found.
        if stepSamples.count < Int(step.collect * 4), !result.weakSteps.contains(step.name) {
            result.weakSteps.append(step.name)
        }
        if let g = result.groups.firstIndex(where: { $0.name == step.name }) {
            result.groups[g].samples += stepSamples
        } else {
            result.groups.append((step.name, step.target, stepSamples))
        }
        switch step.target {
        case .mac: result.mac += stepSamples
        case .other: result.other += stepSamples
        }
        index += 1
        runStep()
    }

    private func finish() {
        tearDown()
        NSSound(named: "Glass")?.play()
        onFinish?(result)
    }

    private func tearDown() {
        token += 1
        onRecording?(nil)
        synth.stopSpeaking(at: .immediate)
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    // MARK: - Overlay

    private func showOverlay() {
        // The camera sits on the built-in display, so the dots must be there too.
        let builtIn = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        guard let screen = builtIn ?? NSScreen.main else { return }

        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in self?.cancel() }

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onCancel = { [weak self] in self?.cancel() }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.view = view
    }
}

private final class OverlayWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }  // Esc
    }
}

private final class OverlayView: NSView {
    var onCancel: (() -> Void)?

    private let title = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "취소 (Esc)", target: nil, action: nil)
    private let dot = CALayer()
    private let ring = CALayer()

    private var dotPosition: CGPoint?
    private var collecting = false
    private var faceVisible = true
    private var lookingAway = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor

        title.font = .systemFont(ofSize: 34, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.maximumNumberOfLines = 3
        status.font = .systemFont(ofSize: 20, weight: .medium)
        status.alignment = .center
        progress.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        progress.textColor = NSColor.white.withAlphaComponent(0.6)
        progress.alignment = .center
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded
        [title, status, progress, cancelButton].forEach(addSubview)

        ring.borderWidth = 3
        ring.cornerRadius = 26
        ring.bounds = CGRect(x: 0, y: 0, width: 52, height: 52)
        dot.cornerRadius = 11
        dot.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func cancelClicked() { onCancel?() }

    func show(_ step: CalibrationSession.Step, number: Int, of count: Int) {
        if let instruction = step.instruction { title.stringValue = instruction }
        progress.stringValue = "\(number) / \(count)   ·   \(step.name)"
        dotPosition = step.dot
        lookingAway = step.target == .other
        collecting = false
        refresh()
        needsLayout = true
    }

    func setCollecting(_ on: Bool) {
        collecting = on
        refresh()
    }

    func setFaceVisible(_ visible: Bool) {
        guard visible != faceVisible else { return }
        faceVisible = visible
        refresh()
    }

    private func refresh() {
        let color: NSColor = collecting ? .systemGreen : .systemOrange
        dot.backgroundColor = color.cgColor
        ring.borderColor = color.withAlphaComponent(0.7).cgColor
        dot.isHidden = dotPosition == nil
        ring.isHidden = dotPosition == nil

        if !faceVisible {
            status.stringValue = "얼굴이 안 보여요 — 카메라에 얼굴이 잡히는 범위에서만 돌려 주세요"
            status.textColor = .systemRed
        } else if collecting {
            status.stringValue = lookingAway ? "● 기록 중 — 그대로 유지 (톡 소리가 날 때까지)" : "● 기록 중 — 점을 계속 보세요"
            status.textColor = .systemGreen
        } else {
            status.stringValue = lookingAway ? "띵 소리가 나면 기록을 시작해요" : "준비…"
            status.textColor = .systemOrange
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let titleWidth = w * 0.7
        let titleHeight = title.sizeThatFits(NSSize(width: titleWidth, height: 400)).height
        title.frame = NSRect(x: (w - titleWidth) / 2, y: h * 0.62, width: titleWidth, height: titleHeight)
        status.frame = NSRect(x: w * 0.1, y: h * 0.62 - 44, width: w * 0.8, height: 28)
        progress.frame = NSRect(x: w * 0.1, y: h * 0.22, width: w * 0.8, height: 20)
        cancelButton.sizeToFit()
        cancelButton.frame.origin = NSPoint(x: (w - cancelButton.frame.width) / 2, y: h * 0.22 - 44)

        if let p = dotPosition {
            let point = CGPoint(x: p.x * w, y: p.y * h)
            dot.position = point
            ring.position = point
        }
    }
}
