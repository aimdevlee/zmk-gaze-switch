import Darwin
import Foundation

/// Talks to the keyboard's host-output-switch serial port (see src/host_output_switch.c).
///
/// The keyboard exposes two USB serial ports: ZMK Studio and ours. We don't
/// guess from the device path; we open each candidate, send `?`, and keep the
/// one that answers with `ZMK-HOS 1`.
final class KeyboardLink {
    struct State: Equatable {
        var usb: Bool
        var profile: Int
        var bleConnected: Bool
    }

    private(set) var portPath: String?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "gaze-switch.serial")

    /// Called on the main queue whenever the connection or reported state changes.
    var onChange: ((_ connected: Bool, _ state: State?) -> Void)?

    var isConnected: Bool { queue.sync { fd >= 0 } }

    /// Called on the main queue when a port is found, with the keyboard's current state.
    var onConnect: ((State) -> Void)?
    /// Called on the main queue when the keyboard rejects a command.
    var onError: ((String) -> Void)?

    private var rejected: Set<String> = []
    private var lastListing: [String] = []

    /// Looks for the port in the background if we don't have one.
    ///
    /// Paths that didn't answer are skipped until the /dev listing changes,
    /// so an absent keyboard or unrelated serial devices aren't poked forever.
    func connectInBackground() {
        queue.async { [self] in
            if fd >= 0 { return }
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
                    notify(true, state)
                    let callback = onConnect
                    DispatchQueue.main.async { callback?(state) }
                    return
                }
                Darwin.close(handle)
                rejected.insert(path)
            }
        }
    }

    /// Sends `U` (this Mac) or `B<n>` (BLE profile n) in the background.
    func select(usb: Bool, profile: Int) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            let command = usb ? "U" : "B\(profile)"
            switch Self.exchange(fd, command) {
            case .state(let state):
                notify(true, state)
            case .error:
                let callback = onError
                DispatchQueue.main.async { callback?("키보드가 '\(command)' 명령을 거부했어요 (프로필 번호를 확인하세요)") }
            case nil:
                dropLocked()
            }
        }
    }

    func disconnect() {
        queue.async { [self] in dropLocked() }
    }

    // MARK: - Internals

    private func dropLocked() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        portPath = nil
        notify(false, nil)
    }

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

    /// `ZMK-HOS 1 <U|B> <profile> <ble-connected>` or `ZMK-HOS 1 ERR`.
    /// `ZEN-HOS` is the name the protocol had before it left the ZEN firmware;
    /// keyboards flashed back then still answer with it.
    private static let identities: Set<Substring> = ["ZMK-HOS", "ZEN-HOS"]

    private static func parse(_ line: String) -> Reply? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, identities.contains(parts[0]), parts[1] == "1" else { return nil }
        if parts.count == 3, parts[2] == "ERR" { return .error }
        guard parts.count == 5, let profile = Int(parts[3]) else { return nil }
        return .state(State(usb: parts[2] == "U", profile: profile, bleConnected: parts[4] == "1"))
    }
}
