import Foundation
import os

/// Talks to the keyboard's host-output-switch module (see ../../../src).
///
/// Three ways in, best first:
///  1. the vendor HID interface over USB,
///  2. the USB serial port (firmware built before the HID interface existed),
///  3. the vendor HID interface over Bluetooth, when no cable is plugged in.
///
/// The link moves to a better way as soon as one answers, and to a worse one
/// when the way it had goes away.
final class KeyboardLink {
    /// What the keyboard reports about itself.
    struct State: Equatable {
        /// The selected output is USB.
        var usb: Bool
        /// The selected BLE profile.
        var profile: Int
        var bleConnected: Bool
        /// The selected output is this Mac: USB when we talk over USB, our own
        /// BLE profile when we talk over Bluetooth.
        var onThisMac: Bool

        /// The command that would point the keyboard where it points now, if there is one.
        fileprivate var asTarget: KeyboardCommand? {
            if onThisMac { return .selectThisMac }
            return usb ? nil : .selectProfile(profile)
        }

        fileprivate func satisfies(_ target: KeyboardCommand) -> Bool {
            switch target {
            case .query: return true
            case .selectThisMac: return onThisMac
            case .selectProfile(let wanted): return !usb && profile == wanted
            }
        }
    }

    /// The ways in, best first.
    enum Route: Int {
        case usbHID, usbSerial, bluetoothHID

        fileprivate var name: String {
            switch self {
            case .usbHID: return "USB HID"
            case .usbSerial: return "the USB serial port"
            case .bluetoothHID: return "Bluetooth HID"
            }
        }
    }

    /// Called on the main queue whenever the connection or reported state changes.
    /// `overBluetooth` says how commands travel, not where the keyboard points.
    var onChange: ((_ connected: Bool, _ state: State?, _ overBluetooth: Bool) -> Void)?
    /// Called on the main queue when the keyboard is found and the app should
    /// take over where it points, with its current state.
    var onConnect: ((State) -> Void)?
    /// Called on the main queue when the keyboard rejects a command.
    var onError: ((String) -> Void)?

    var isConnected: Bool { queue.sync { link != nil } }

    /// Looks for the keyboard, or for a better way to reach it, in the background.
    func connectInBackground() {
        queue.async { [self] in connectLocked() }
    }

    /// Points the keyboard at this Mac. Asked while the keyboard is away, it is
    /// carried out if the keyboard comes back soon.
    func selectThisMac() {
        queue.async { [self] in askLocked(.selectThisMac) }
    }

    /// Points the keyboard at BLE profile `profile` (the other computer).
    func selectProfile(_ profile: Int) {
        queue.async { [self] in askLocked(.selectProfile(profile)) }
    }

    func disconnect() {
        queue.async { [self] in
            abandonGreetingLocked()
            dropLocked()
        }
    }

    // MARK: - Internals (everything below runs on `queue`)

    private static let log = Logger(subsystem: "io.github.aimdevlee.GazeSwitch", category: "keyboard")

    private let queue = DispatchQueue(label: "gaze-switch.keyboard")
    /// The way in we use. It has answered at least once.
    private var link: KeyboardTransport?
    /// An HID interface we have sent `?` to and not heard from yet. It exists
    /// only while that `?` is out, and never replaces `link` before it answers.
    private var greeting: HIDLink?
    /// Created at the first search, not in `init`: its first callback can arrive at
    /// once, and the owner must have set `onChange` / `onConnect` by then.
    private var hid: HIDInterfaces?
    private var serialPorts = SerialPort.Finder()

    /// Where the keyboard should point: what the app last asked for, or, once
    /// the keyboard has confirmed that, wherever the keyboard says it points.
    private var target: KeyboardCommand?
    /// Set while the keyboard has not confirmed `target`, with the time it was asked for.
    private var targetAskedAt: Date?
    /// The way in we had before this one (or before none), and when we left it.
    private var previous: (route: Route, leftAt: Date)?
    /// How long after losing the keyboard, or asking in vain, `target` still
    /// counts when the keyboard is found again.
    private static let targetLifetime = 30.0

    private func askLocked(_ command: KeyboardCommand) {
        target = command
        targetAskedAt = Date()
        link?.send(command)
    }

    /// The keyboard said where it points.
    private func heardLocked(_ state: State) {
        if targetAskedAt == nil {
            target = state.asTarget
        } else if let target, state.satisfies(target) {
            targetAskedAt = nil
        }
        notifyLocked(state)
    }

    /// `target`, when the keyboard just found must be told about it again:
    /// - it never confirmed the last thing we asked for (the reply, or the
    ///   whole link, was lost), or
    /// - we reach it another way than before. Pulling or plugging the cable
    ///   makes the keyboard itself move its output; nobody chose that.
    /// A keyboard that comes back the same way keeps whatever it points at:
    /// someone may have changed it on the keyboard.
    private func targetToRestoreLocked(over route: Route, given state: State) -> KeyboardCommand? {
        guard let target, !state.satisfies(target) else { return nil }
        let since: Date?
        if let targetAskedAt {
            since = targetAskedAt
        } else if let previous, previous.route != route {
            since = previous.leftAt
        } else {
            since = nil
        }
        guard let since, Date().timeIntervalSince(since) < Self.targetLifetime else { return nil }
        return target
    }

    private func connectLocked() {
        let hid = hid ?? startWatchingHIDLocked()

        if let link, !link.isStillThere { dropLocked() }
        if greeting != nil { return } // its answer, or its silence, brings us back here

        if link?.route != .usbHID, let usb = hid.openLink(bluetooth: false) {
            greetLocked(usb)
            return
        }
        // The serial port beats Bluetooth too, if the USB HID interface stayed silent.
        if link == nil || link?.route == .bluetoothHID, let (port, state) = serialPorts.find() {
            adoptLocked(port, state)
        } else if link == nil, let bluetooth = hid.openLink(bluetooth: true) {
            greetLocked(bluetooth)
        }
    }

    /// Re-enters `connectLocked` before it returns if an interface is already attached.
    private func startWatchingHIDLocked() -> HIDInterfaces {
        let interfaces = HIDInterfaces(queue: queue) { [unowned self] in connectLocked() }
        hid = interfaces
        interfaces.startWatching()
        return interfaces
    }

    private func greetLocked(_ candidate: HIDLink) {
        greeting = candidate
        candidate.onEvent = { [unowned self, unowned candidate] event in
            greeting = nil
            if case .state(let state) = event {
                adoptLocked(candidate, state)
            } else {
                // Silent, or it answered `?` with an error: not a way in for now.
                hid?.giveUp(on: candidate)
                connectLocked()
            }
        }
        candidate.send(.query)
    }

    private func abandonGreetingLocked() {
        greeting?.close()
        greeting = nil
    }

    private func adoptLocked(_ transport: KeyboardTransport, _ state: State) {
        if let replaced = link {
            previous = (replaced.route, Date())
            replaced.close()
        }
        link = transport
        transport.onEvent = { [unowned self, unowned transport] event in
            guard transport === link else { return }
            switch event {
            case .state(let state): heardLocked(state)
            case .rejected(let command):
                targetAskedAt = nil
                target = nil
                reportRejected(command)
            case .lost: dropLocked()
            }
        }
        Self.log.notice("connected over \(transport.route.name, privacy: .public)")
        if let restore = targetToRestoreLocked(over: transport.route, given: state) {
            // The app's idea of where the keyboard points still stands, so no `onConnect`.
            notifyLocked(state)
            targetAskedAt = Date()
            transport.send(restore)
        } else {
            targetAskedAt = nil
            heardLocked(state)
            let callback = onConnect
            DispatchQueue.main.async { callback?(state) }
        }
    }

    private func dropLocked() {
        guard let lost = link else { return }
        link = nil
        previous = (lost.route, Date())
        lost.close()
        Self.log.notice("keyboard link lost")
        notifyLocked(nil)
    }

    private func notifyLocked(_ state: State?) {
        let callback = onChange
        let overBluetooth = link?.route == .bluetoothHID
        DispatchQueue.main.async { callback?(state != nil, state, overBluetooth) }
    }

    private func reportRejected(_ command: String) {
        let callback = onError
        DispatchQueue.main.async { callback?(tr("키보드가 '\(command)' 명령을 거부했어요 (프로필 번호를 확인하세요)",
                                                  "The keyboard rejected the '\(command)' command (check the profile number)",
                                                  "キーボードが「\(command)」コマンドを拒否しました(プロファイル番号を確認してください)")) }
    }
}
