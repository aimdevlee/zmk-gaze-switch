import Darwin
import Foundation
import IOKit.hid
import os

/// Talks to the keyboard's host-output-switch module (see ../../../src).
///
/// Three ways in, tried in this order:
///  1. the vendor HID interface over USB,
///  2. the USB serial port (firmware built before the HID interface existed),
///  3. the vendor HID interface over Bluetooth, when no cable is plugged in.
///
/// HID is found by its usage page, so nothing else is touched. For serial the
/// keyboard exposes two ports (ZMK Studio and ours) and we don't guess from the
/// device path: we open each candidate, send `?`, and keep the one that answers
/// with `ZMK-HOS 1`.
final class KeyboardLink {
    struct State: Equatable {
        /// The selected output is USB.
        var usb: Bool
        /// The selected BLE profile.
        var profile: Int
        var bleConnected: Bool
        /// The selected output is this Mac: USB when we talk over USB, our own
        /// BLE profile when we talk over Bluetooth.
        var onThisMac: Bool
        /// Commands travel over Bluetooth (no cable).
        var wireless: Bool
    }

    private static let log = Logger(subsystem: "io.github.aimdevlee.GazeSwitch", category: "keyboard")

    private(set) var portPath: String?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "gaze-switch.keyboard")

    /// Called on the main queue whenever the connection or reported state changes.
    var onChange: ((_ connected: Bool, _ state: State?) -> Void)?

    var isConnected: Bool { queue.sync { fd >= 0 || hidGreeted } }

    /// Called on the main queue when the keyboard is found, with its current state.
    var onConnect: ((State) -> Void)?
    /// Called on the main queue when the keyboard rejects a command.
    var onError: ((String) -> Void)?

    private var rejected: Set<String> = []
    private var lastListing: [String] = []

    // Vendor HID interface of the module (CONFIG_ZMK_HOST_OUTPUT_SWITCH_HID_USAGE_PAGE / _USAGE).
    private static let hidUsagePage = 0xFF9A
    private static let hidUsage = 0x01
    private static let hidReportSize = 32
    /// Over Bluetooth a reply can take most of a second: the keyboard only wakes
    /// its radio every so often while idle.
    private static let hidReplyTimeout = 2.0

    private let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    /// The HID interface in use, once chosen. `hidGreeted` turns true at its first reply.
    private var hidDevice: IOHIDDevice?
    private var hidGreeted = false
    /// Interfaces that matched the usage page but didn't answer; forgotten when the set of devices changes, or after a while.
    private var hidRejected: Set<IOHIDDevice> = []
    /// A link that has just come up can miss its first `?`, so a rejection only lasts this long.
    private var hidRejectedAt = Date.distantPast
    private static let hidRejectionLifetime = 10.0
    /// The command we are waiting on, and a token that tells its timeout apart from older ones.
    private var hidPending: (command: String, token: Int)?
    private var hidToken = 0

    private var hidStarted = false

    /// Starts watching for the HID interface. Not done in `init`: the first reply can
    /// arrive at once, and the owner must have set `onChange` / `onConnect` by then.
    private func hidStartWatching() {
        hidStarted = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(hidManager, [
            kIOHIDDeviceUsagePageKey: Self.hidUsagePage,
            kIOHIDDeviceUsageKey: Self.hidUsage,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { context, _, _, _ in
            Unmanaged<KeyboardLink>.fromOpaque(context!).takeUnretainedValue().hidDevicesChanged()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, device in
            Unmanaged<KeyboardLink>.fromOpaque(context!).takeUnretainedValue().hidDevicesChanged(removed: device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(hidManager, { context, _, sender, _, _, report, length in
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let bytes = UnsafeBufferPointer(start: report, count: length).prefix { $0 != 0 }
            Unmanaged<KeyboardLink>.fromOpaque(context!).takeUnretainedValue()
                .hidReceived(String(decoding: bytes, as: UTF8.self), from: device)
        }, context)
        // Callbacks arrive on our queue. Opening is limited to the matched vendor
        // interfaces; the keyboard's key-input interface is a separate device we never open.
        IOHIDManagerSetDispatchQueue(hidManager, queue)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(hidManager)
    }

    /// Looks for the keyboard in the background if we don't have it.
    ///
    /// Paths that didn't answer are skipped until the /dev listing changes,
    /// so an absent keyboard or unrelated serial devices aren't poked forever.
    func connectInBackground() {
        queue.async { [self] in connectLocked() }
    }

    private func connectLocked() {
        if !hidStarted { hidStartWatching() }
        if fd >= 0 || hidDevice != nil { return }
        if Date().timeIntervalSince(hidRejectedAt) > Self.hidRejectionLifetime { hidRejected = [] }
        // A cable beats the serial port (nothing to probe), and the serial port beats Bluetooth.
        if let usb = hidCandidates().first(where: { !Self.isBluetooth($0) }) {
            hidStart(usb)
            return
        }
        let listing = Self.candidatePaths()
        if listing != lastListing {
            lastListing = listing
            rejected = []
        }
        for path in listing where !rejected.contains(path) {
            guard let handle = Self.open(path) else { rejected.insert(path); continue }
            if case .state(let state) = Self.exchange(handle, "?") {
                fd = handle
                portPath = path
                Self.log.notice("connected over the USB serial port")
                notify(true, state)
                let callback = onConnect
                DispatchQueue.main.async { callback?(state) }
                return
            }
            Darwin.close(handle)
            rejected.insert(path)
        }
        if let ble = hidCandidates().first {
            hidStart(ble)
        }
    }

    /// Points the keyboard at this Mac, or at BLE profile `profile` (the other computer).
    func select(thisMac: Bool, profile: Int) {
        queue.async { [self] in
            if fd >= 0 {
                // Serial only exists over USB, so "this Mac" is the USB output.
                let command = thisMac ? "U" : "B\(profile)"
                switch Self.exchange(fd, command) {
                case .state(let state):
                    notify(true, state)
                case .error:
                    reportRejected(command)
                case nil:
                    dropLocked()
                }
            } else if hidDevice != nil, hidGreeted {
                // `M` lets the keyboard work out what "the sender" is: USB over a
                // cable, our own BLE profile over Bluetooth.
                hidSend(thisMac ? "M" : "B\(profile)")
            }
        }
    }

    private func reportRejected(_ command: String) {
        let callback = onError
        DispatchQueue.main.async { callback?(tr("키보드가 '\(command)' 명령을 거부했어요 (프로필 번호를 확인하세요)",
                                                  "The keyboard rejected the '\(command)' command (check the profile number)",
                                                  "キーボードが「\(command)」コマンドを拒否しました(プロファイル番号を確認してください)")) }
    }

    func disconnect() {
        queue.async { [self] in dropLocked() }
    }

    // MARK: - Internals

    private func dropLocked() {
        let wasConnected = fd >= 0 || hidGreeted
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        portPath = nil
        hidDevice = nil
        hidGreeted = false
        hidPending = nil
        if wasConnected {
            Self.log.notice("keyboard link lost")
            notify(false, nil)
        }
    }

    // MARK: - HID

    private static func isBluetooth(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        return transport.lowercased().contains("bluetooth")
    }

    /// Matching interfaces that haven't failed to answer, USB first.
    private func hidCandidates() -> [IOHIDDevice] {
        let all = (IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>) ?? []
        return all.subtracting(hidRejected).sorted { !Self.isBluetooth($0) && Self.isBluetooth($1) }
    }

    private func hidStart(_ device: IOHIDDevice) {
        hidDevice = device
        hidGreeted = false
        hidSend("?")
    }

    private func hidSend(_ command: String) {
        guard let device = hidDevice else { return }
        var report = Array(command.utf8.prefix(Self.hidReportSize))
        report += [UInt8](repeating: 0, count: Self.hidReportSize - report.count)

        hidToken += 1
        let token = hidToken
        hidPending = (command, token)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count) == kIOReturnSuccess else {
            hidFailed(device)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.hidReplyTimeout) { [self] in
            if hidPending?.token == token, hidDevice === device { hidFailed(device) }
        }
    }

    /// No answer: not our interface, or the link went away under us.
    private func hidFailed(_ device: IOHIDDevice) {
        if !hidGreeted {
            hidRejected.insert(device)
            hidRejectedAt = Date()
        }
        dropLocked()
    }

    private func hidReceived(_ text: String, from device: IOHIDDevice) {
        guard device === hidDevice, let pending = hidPending,
              let reply = Self.parse(text, wireless: Self.isBluetooth(device)) else { return }
        hidPending = nil
        switch reply {
        case .state(let state):
            notify(true, state)
            if !hidGreeted {
                hidGreeted = true
                Self.log.notice("connected over HID (\(state.wireless ? "Bluetooth" : "USB", privacy: .public))")
                let callback = onConnect
                DispatchQueue.main.async { callback?(state) }
            }
        case .error:
            // A rejected `?` can't happen; a rejected first command still proves who answered.
            reportRejected(pending.command)
        }
    }

    private func hidDevicesChanged(removed: IOHIDDevice? = nil) {
        hidRejected = []
        if let removed, removed === hidDevice {
            dropLocked()
        } else if removed == nil, let current = hidDevice, Self.isBluetooth(current),
                  hidCandidates().contains(where: { !Self.isBluetooth($0) }) {
            // The cable was plugged in while we were talking over Bluetooth.
            dropLocked()
        }
        connectLocked()
    }

    // MARK: - Serial

    private func notify(_ connected: Bool, _ state: State?) {
        let callback = onChange
        DispatchQueue.main.async { callback?(connected, state) }
    }

    private static func candidatePaths() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    private static func open(_ path: String) -> Int32? {
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { return nil }

        var tio = termios()
        tcgetattr(handle, &tio)
        cfmakeraw(&tio)
        // Never 1200 baud: that speed tells the bootloader trigger to reset.
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(handle, TCSANOW, &tio)

        // The firmware only answers while DTR is asserted.
        var bits: Int32 = TIOCM_DTR
        _ = ioctl(handle, TIOCMBIS, &bits)
        // Give the DTR control request time to reach the keyboard; a command
        // sent before it lands is answered into a port the firmware thinks is
        // closed, and the reply is dropped. (Seen on real hardware.)
        usleep(300_000)
        tcflush(handle, TCIOFLUSH)
        return handle
    }

    /// Writes one command line and waits briefly for the status line.
    private enum Reply {
        case state(State)
        case error
    }

    private static func exchange(_ handle: Int32, _ command: String) -> Reply? {
        tcflush(handle, TCIFLUSH)
        let bytes = Array((command + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(handle, $0.baseAddress, $0.count) }
        guard written == bytes.count else { return nil }

        var received = ""
        let deadline = Date().addingTimeInterval(0.4)
        var buffer = [UInt8](repeating: 0, count: 64)

        while Date() < deadline {
            var pfd = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { continue }
            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return nil }

            let n = Darwin.read(handle, &buffer, buffer.count)
            if n < 0 && errno != EAGAIN { return nil }
            if n > 0 { received += String(decoding: buffer[0..<n], as: UTF8.self) }

            while let newline = received.firstIndex(of: "\n") {
                let line = String(received[..<newline]).trimmingCharacters(in: .whitespaces)
                received = String(received[received.index(after: newline)...])
                if let reply = parse(line) { return reply }
            }
        }
        return nil
    }

    /// Serial: `ZMK-HOS 1 <U|B> <profile> <ble-connected>`.
    /// HID: `ZMK-HOS 2 <U|B> <profile> <ble-connected> <me> <sender>`.
    /// Either: `ZMK-HOS <n> ERR`.
    /// `ZEN-HOS` is the name the protocol had before it left the ZEN firmware;
    /// keyboards flashed back then still answer with it.
    private static let identities: Set<Substring> = ["ZMK-HOS", "ZEN-HOS"]

    private static func parse(_ line: String, wireless: Bool = false) -> Reply? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, identities.contains(parts[0]) else { return nil }
        if parts.count == 3, parts[2] == "ERR" { return .error }
        switch (parts[1], parts.count) {
        case ("1", 5):
            guard let profile = Int(parts[3]) else { return nil }
            let usb = parts[2] == "U"
            return .state(State(usb: usb, profile: profile, bleConnected: parts[4] == "1",
                                onThisMac: usb, wireless: false))
        case ("2", 7):
            guard let profile = Int(parts[3]) else { return nil }
            return .state(State(usb: parts[2] == "U", profile: profile, bleConnected: parts[4] == "1",
                                onThisMac: parts[5] == "1", wireless: wireless))
        default:
            return nil
        }
    }
}
