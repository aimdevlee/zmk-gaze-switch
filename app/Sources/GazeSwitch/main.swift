import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tracker = GazeTracker()
    private let link = KeyboardLink()
    private var classifier = GazeClassifier()
    private var reconnectTimer: Timer?

    private var lastPose: HeadPose?
    private var keyboardState: KeyboardLink.State?
    private var cameraError: String?
    private var calibration: CalibrationSession?

    private let defaults = UserDefaults.standard

    /// Menu rows that change while the menu is open. NSMenu doesn't rebuild
    /// itself while visible, so these get their titles updated in place.
    private weak var keyboardRow: NSMenuItem?
    private weak var faceRow: NSMenuItem?
    private weak var eyeRow: NSMenuItem?
    private weak var scoreRow: NSMenuItem?
    private var menuOpen = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Add pupil position to head pose when deciding where the user looks.
    private var useEyes: Bool {
        get { defaults.object(forKey: "useEyes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useEyes"); classifier.useEyes = newValue }
    }

    /// BLE profile the other computer is paired on (the keymap's BT_SEL index).
    private var profile: Int {
        get { defaults.object(forKey: "profile") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "profile") }
    }

    /// Per-target calibration statistics; the model needs both.
    private var macStats: TargetStats? { didSet { rebuildModel() } }
    private var otherStats: TargetStats? { didSet { rebuildModel() } }

    private func rebuildModel() {
        if let macStats, let otherStats {
            classifier.model = GazeModel(mac: macStats, other: otherStats)
        } else {
            classifier.model = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateFromZenGaze()
        // v2 keys: earlier formats can't train the current model.
        macStats = loadStats("macStats3")
        otherStats = loadStats("otherStats3")
        classifier.useEyes = useEyes

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        link.onChange = { [weak self] connected, state in
            self?.keyboardState = connected ? state : nil
            self?.refreshIcon()
            self?.refreshLiveRows()
        }
        // Adopt whatever the keyboard is doing now; gaze + dwell make the next change.
        link.onConnect = { [weak self] state in
            self?.classifier.force(state.usb ? .mac : .other)
            self?.refreshIcon()
        }
        link.onError = { [weak self] message in self?.alert(message) }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.link.connectInBackground()
        }
        link.connectInBackground()
        applyEnabled()
        refreshIcon()
    }

    // MARK: - Flow

    private var calibrated: Bool { classifier.model != nil }

    /// Auto-switching only runs once calibrated: without it, looking down at
    /// the keyboard could read as "looking away".
    private var autoSwitching: Bool { enabled && calibrated }

    private func applyEnabled() {
        guard autoSwitching || calibration != nil else {
            tracker.stop()
            lastPose = nil
            refreshIcon()
            return
        }
        GazeTracker.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.cameraError = tr("카메라 권한이 없어요 (시스템 설정 > 개인정보 보호 및 보안 > 카메라)",
                                      "No camera access (System Settings > Privacy & Security > Camera)",
                                      "カメラの許可がありません(システム設定 > プライバシーとセキュリティ > カメラ)")
                self.refreshIcon()
                return
            }
            do {
                try self.tracker.start()
                self.cameraError = nil
            } catch {
                self.cameraError = error.localizedDescription
            }
            self.refreshIcon()
        }
    }

    private func handle(_ pose: HeadPose?) {
        lastPose = pose

        if let calibration {
            calibration.ingest(pose)
            return
        }
        guard autoSwitching else { return }

        if let target = classifier.feed(pose) {
            send(target)
        }
        refreshIcon()
        refreshLiveRows()
    }

    private func send(_ target: Target) {
        guard keyboardState != nil else { return }
        link.select(usb: target == .mac, profile: profile)
    }

    private func switchManually(to target: Target) {
        classifier.force(target)
        send(target)
        refreshIcon()
    }

    // MARK: - Calibration

    private func startCalibration() {
        guard calibration == nil else { return }
        GazeTracker.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.alert(tr("카메라 권한이 필요해요. 시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 GazeSwitch를 허용해 주세요.",
                              "Camera access is needed. Allow GazeSwitch in System Settings > Privacy & Security > Camera.",
                              "カメラの許可が必要です。システム設定 > プライバシーとセキュリティ > カメラで GazeSwitch を許可してください。"))
                return
            }
            let session = CalibrationSession()
            session.onFinish = { [weak self] result in self?.finishCalibration(result) }
            // Diagnostics: keep eye snapshots of this run only.
            if let dir = GazeTracker.debugDirectory { try? FileManager.default.removeItem(at: dir) }
            // Diagnostic eye crops are off unless asked for:
            //   defaults write io.github.aimdevlee.GazeSwitch debugEyeImages -bool true
            if defaults.bool(forKey: "debugEyeImages") {
                session.onRecording = { [weak self] label in self?.tracker.setDebugLabel(label) }
            }
            self.calibration = session
            self.applyEnabled()  // camera on
            self.refreshIcon()
            session.start()
        }
    }

    private func finishCalibration(_ result: CalibrationSession.Result?) {
        calibration = nil
        defer { applyEnabled(); refreshIcon() }
        guard let result else { return }  // cancelled: keep the previous calibration

        guard let mac = TargetStats(samples: result.mac), let other = TargetStats(samples: result.other) else {
            alert(tr("얼굴을 충분히 인식하지 못해서 보정을 저장하지 않았어요. 밝은 곳에서 다시 해 주세요.",
                     "The face was not detected well enough, so the calibration was not saved. Please try again somewhere brighter.",
                     "顔を十分に検出できなかったため、キャリブレーションを保存しませんでした。明るい場所でもう一度お試しください。"))
            return
        }
        macStats = mac
        otherStats = other
        saveStats(mac, "macStats3")
        saveStats(other, "otherStats3")
        classifier.force(.mac)  // the overlay just closed, so they're at the Mac

        var lines: [String] = []
        if let model = classifier.model {
            let total = model.totalSeparation(useEyes: useEyes)
            lines.append(String(format: tr("구분력 %.1f — %@", "Separation %.1f — %@", "分離度 %.1f — %@"), total,
                                total >= 3 ? tr("충분해요.", "plenty.", "十分です。")
                                : total >= 2 ? tr("쓸 만해요.", "good enough.", "使える範囲です。")
                                : tr("낮아요. 전환이 불안정할 수 있어요.", "low. Switching may be unreliable.", "低いです。切り替えが不安定になるかもしれません。")))
            if useEyes && !model.hasEyes {
                lines.append(tr("눈 위치를 믿을 수 있게 잡지 못해서 고개 방향만 사용합니다. 마스크를 쓰고 있거나 얼굴 일부가 가려져 있으면 이렇게 돼요.",
                                "The eyes could not be located reliably, so only head direction is used. This happens with a mask on or when part of the face is covered.",
                                "目の位置を確実に検出できなかったため、頭の向きだけを使います。マスクを着けているときや顔の一部が隠れているときにこうなります。"))
            }
        }
        if let model = classifier.model {
            // How often each posture's own frames land on the right side.
            let report = result.groups.compactMap { group -> String? in
                let scores = group.samples.compactMap { model.score($0, useEyes: useEyes) }
                guard !scores.isEmpty else { return nil }
                let right = scores.filter { ($0 > 0) == (group.target == .other) }.count
                return String(format: "%@  %d%%", group.name, right * 100 / scores.count)
            }
            lines.append(tr("자세별 정확도", "Accuracy by posture", "姿勢ごとの正解率") + "\n" + report.joined(separator: "\n"))
        }
        writeLog(result)
        if !result.weakSteps.isEmpty {
            lines.append(tr("얼굴이 잘 안 잡힌 단계: ", "Steps where the face was mostly lost: ", "顔をうまく検出できなかったステップ: ")
                         + result.weakSteps.joined(separator: ", ")
                         + tr(". 그 자세에서는 판단이 덜 정확할 수 있어요.", ". Decisions may be less accurate in those postures.", "。その姿勢では判定の精度が下がるかもしれません。"))
        }
        alert(tr("보정을 마쳤어요.", "Calibration finished.", "キャリブレーションが終わりました。") + "\n\n" + lines.joined(separator: "\n\n"))
    }

    /// Raw frames of the last calibration, for tuning. Numbers only, no images.
    private func writeLog(_ result: CalibrationSession.Result) {
        let groups = result.groups.map { group -> [String: Any] in
            ["name": group.name, "target": group.target.rawValue,
             "features": Feature.allCases.map { "\($0)" },
             "frames": group.samples.map { pose in Feature.allCases.map { $0.value(of: pose) as Any? ?? NSNull() } }]
        }
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GazeSwitch"),
              let data = try? JSONSerialization.data(withJSONObject: groups) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("last-calibration.json"))
    }

    /// The app was called ZenGaze while it lived in the ZEN firmware repo.
    /// Carry its settings and calibration over once.
    private func migrateFromZenGaze() {
        guard !defaults.bool(forKey: "migratedFromZenGaze") else { return }
        defaults.set(true, forKey: "migratedFromZenGaze")
        guard let old = UserDefaults.standard.persistentDomain(forName: "local.zen-firmware.zengaze") else { return }
        for key in ["enabled", "useEyes", "profile", "macStats3", "otherStats3"] {
            if defaults.object(forKey: key) == nil, let value = old[key] { defaults.set(value, forKey: key) }
        }
    }

    private func saveStats(_ stats: TargetStats, _ key: String) {
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: key) }
    }

    private func loadStats(_ key: String) -> TargetStats? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TargetStats.self, from: $0) }
    }

    // MARK: - Live menu rows

    private var keyboardText: String {
        guard let state = keyboardState else {
            return tr("키보드: 찾는 중… (키보드를 USB로 연결하세요)",
                      "Keyboard: searching… (plug the keyboard in over USB)",
                      "キーボード: 検索中…(キーボードを USB で接続してください)")
        }
        let out = state.usb
            ? tr("USB (이 맥)", "USB (this Mac)", "USB(この Mac)")
            : tr("BLE 프로필 \(state.profile)", "BLE profile \(state.profile)", "BLE プロファイル \(state.profile)")
                + (state.bleConnected ? "" : tr(" · 연결 안 됨", " · not connected", " · 未接続"))
        return tr("키보드: ", "Keyboard: ", "キーボード: ") + out
    }

    private var faceText: String {
        lastPose.map { String(format: tr("얼굴: 좌우 %.0f° · 상하 %.0f°", "Face: L/R %.0f° · U/D %.0f°", "顔: 左右 %.0f° · 上下 %.0f°"),
                                 $0.yaw, $0.pitch) }
            ?? tr("얼굴: 인식 안 됨 (현재 상태 유지)", "Face: not detected (keeping the current output)", "顔: 検出なし(現在の出力を維持)")
    }

    private var eyeText: String {
        guard let pose = lastPose else { return tr("눈동자: –", "Eyes: –", "瞳: –") }
        return pose.irisX.map { String(format: tr("눈동자: 좌우 %+.2f · 상하 %+.2f", "Eyes: L/R %+.2f · U/D %+.2f", "瞳: 左右 %+.2f · 上下 %+.2f"),
                                       $0, pose.irisY ?? 0) }
            ?? tr("눈동자: 인식 안 됨 — 마스크 등으로 얼굴이 가려졌을 수 있어요 (고개 방향만 사용)",
                  "Eyes: not detected — the face may be covered, e.g. by a mask (using head direction only)",
                  "瞳: 検出なし — マスクなどで顔が隠れているかもしれません(頭の向きだけを使用)")
    }

    /// The model's verdict for the latest frame, drawn as a little gauge.
    private var scoreText: String {
        guard let score = classifier.lastScore else { return tr("판단: –", "Verdict: –", "判定: –") }
        let slots = 11
        let clamped = min(max(score, -0.75), 0.75)
        let pos = Int(((clamped + 0.75) / 1.5 * Double(slots - 1)).rounded())
        let gauge = (0..<slots).map { $0 == pos ? "●" : ($0 == slots / 2 ? "┼" : "─") }.joined()
        return String(format: tr("판단: 맥 %@ 다른  (%+.2f)", "Verdict: Mac %@ other  (%+.2f)", "判定: Mac %@ もう一台  (%+.2f)"), gauge, score)
    }

    /// Updates the live rows of an open menu; menu tracking runs the main
    /// queue in a mode GCD still services, so this shows up immediately.
    private func refreshLiveRows() {
        guard menuOpen else { return }
        keyboardRow?.title = keyboardText
        faceRow?.title = faceText
        eyeRow?.title = eyeText
        scoreRow?.title = scoreText
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: - UI

    private func refreshIcon() {
        let symbol: String
        if calibration != nil { symbol = "scope" }
        else if keyboardState == nil { symbol = "keyboard.badge.exclamationmark" }
        else if !autoSwitching { symbol = "pause.circle" }
        else { symbol = classifier.current == .mac ? "laptopcomputer" : "desktopcomputer" }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GazeSwitch")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "GazeSwitch")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        @discardableResult
        func info(_ text: String) -> NSMenuItem {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return item
        }
        @discardableResult
        func action(_ title: String, _ key: String = "", _ block: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, block)
            menu.addItem(item)
            return item
        }

        keyboardRow = info(keyboardText)
        faceRow = nil
        eyeRow = nil
        scoreRow = nil
        if let cameraError {
            info(cameraError)
        } else if enabled && !calibrated {
            info(tr("자동 전환은 보정을 마친 뒤 켜져요", "Automatic switching turns on after calibration", "自動切り替えはキャリブレーション後に有効になります"))
        } else if autoSwitching {
            scoreRow = info(scoreText)
            faceRow = info(faceText)
            if useEyes { eyeRow = info(eyeText) }
        }
        menu.addItem(.separator())

        action(tr("시선으로 자동 전환", "Switch automatically by gaze", "視線で自動切り替え")) { [weak self] in
            guard let self else { return }
            self.enabled.toggle()
            self.applyEnabled()
        }.state = enabled ? .on : .off
        action(tr("눈동자 방향도 사용", "Also use eye direction", "瞳の向きも使う")) { [weak self] in self?.useEyes.toggle() }.state = useEyes ? .on : .off
        action(tr("지금 이 맥으로", "Switch to this Mac now", "今すぐこの Mac へ")) { [weak self] in self?.switchManually(to: .mac) }
        action(tr("지금 다른 컴퓨터로", "Switch to the other computer now", "今すぐもう一台へ")) { [weak self] in self?.switchManually(to: .other) }
        menu.addItem(.separator())

        if let model = classifier.model {
            info(String(format: tr("보정됨 · 구분력 %.1f (2 이상이면 안정적)", "Calibrated · separation %.1f (2 or more is reliable)", "キャリブレーション済み · 分離度 %.1f(2 以上なら安定)"), model.totalSeparation(useEyes: useEyes)))
            // Each signal on its own; the total above uses them in combination.
            let parts = Feature.allCases.compactMap { f -> String? in
                guard !f.isEye || useEyes, let sep = model.separation(f) else { return nil }
                return String(format: "%@ %.1f", f.label, sep)
            }
            info(tr("신호별: ", "Per signal: ", "信号ごと: ") + parts.joined(separator: " · "))
            if useEyes && !model.hasEyes {
                info(tr("눈동자가 보정 중에 잘 안 잡혀서 고개 방향만 쓰고 있어요", "Eyes were not detected well during calibration; using head direction only", "キャリブレーション中に瞳をうまく検出できなかったため、頭の向きだけを使っています"))
            }
        } else {
            info(tr("보정 안 됨", "Not calibrated", "未キャリブレーション"))
        }
        action(calibrated ? tr("다시 보정 (화면 안내, 약 1분)", "Recalibrate (on-screen guide, about 1 minute)", "再キャリブレーション(画面の案内、約 1 分)")
                          : tr("보정 시작 (화면 안내, 약 1분)", "Start calibration (on-screen guide, about 1 minute)", "キャリブレーション開始(画面の案内、約 1 分)")) { [weak self] in
            self?.startCalibration()
        }
        if calibrated {
            action(tr("보정 초기화", "Reset calibration", "キャリブレーションをリセット")) { [weak self] in
                guard let self else { return }
                self.macStats = nil
                self.otherStats = nil
                self.defaults.removeObject(forKey: "macStats3")
                self.defaults.removeObject(forKey: "otherStats3")
                self.applyEnabled()
                self.refreshIcon()
            }
        }
        menu.addItem(.separator())

        let profileItem = NSMenuItem(title: tr("다른 컴퓨터의 BLE 프로필", "BLE profile of the other computer", "もう一台の BLE プロファイル"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // ZMK's default of five BLE profiles. A split central may have fewer;
        // the keyboard answers ERR for one it doesn't have.
        for n in 0..<5 {
            let item = ClosureMenuItem(title: tr("프로필 \(n)", "Profile \(n)", "プロファイル \(n)"), keyEquivalent: "") { [weak self] in
                self?.profile = n
                if self?.classifier.current == .other { self?.send(.other) }
            }
            item.state = n == profile ? .on : .off
            sub.addItem(item)
        }
        profileItem.submenu = sub
        menu.addItem(profileItem)

        let languageItem = NSMenuItem(title: tr("언어", "Language", "言語"), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        let automatic = ClosureMenuItem(title: tr("시스템 설정 따르기", "Follow the system", "システム設定に合わせる"),
                                        keyEquivalent: "") { Language.chosen = nil }
        automatic.state = Language.chosen == nil ? .on : .off
        languages.addItem(automatic)
        languages.addItem(.separator())
        for language in Language.allCases {
            let item = ClosureMenuItem(title: language.displayName, keyEquivalent: "") { Language.chosen = language }
            item.state = Language.chosen == language ? .on : .off
            languages.addItem(item)
        }
        languageItem.submenu = languages
        menu.addItem(languageItem)
        menu.addItem(.separator())

        action(tr("종료", "Quit", "終了"), "q") { NSApp.terminate(nil) }
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "GazeSwitch"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, keyEquivalent: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { block() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
