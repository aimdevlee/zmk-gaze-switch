import Darwin
import Foundation

/// The module's USB serial port (firmware built without the HID interface).
final class SerialPort: KeyboardTransport {
    let route = KeyboardLink.Route.usbSerial
    var onEvent: ((KeyboardEvent) -> Void)?

    private let path: String
    private var fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    /// Pulling the cable removes the device node, but nothing tells an open port.
    var isStillThere: Bool { FileManager.default.fileExists(atPath: path) }

    func send(_ command: KeyboardCommand) {
        let text = Self.text(for: command)
        switch exchange(text) {
        case .state(let state): onEvent?(.state(state))
        case .rejected: onEvent?(.rejected(command: text))
        case nil: onEvent?(.lost)
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    private static func text(for command: KeyboardCommand) -> String {
        switch command {
        case .query: return "?"
        // Serial only exists over USB, so "this Mac" is the USB output.
        case .selectThisMac: return "U"
        case .selectProfile(let profile): return "B\(profile)"
        }
    }

    // MARK: - Finding the port

    /// Looks for the module's port among the USB serial devices.
    ///
    /// The keyboard exposes two ports (ZMK Studio and ours) and we don't guess
    /// from the device path: we open each candidate, send `?`, and keep the one
    /// that answers. Paths that didn't answer are skipped until the /dev listing
    /// changes, so an absent keyboard or unrelated serial devices aren't poked forever.
    struct Finder {
        private var silentPaths: Set<String> = []
        private var lastListing: [String] = []

        mutating func find() -> (port: SerialPort, state: KeyboardLink.State)? {
            let listing = SerialPort.candidatePaths()
            if listing != lastListing {
                lastListing = listing
                silentPaths = []
            }
            for path in listing where !silentPaths.contains(path) {
                if let fd = SerialPort.open(path) {
                    let port = SerialPort(path: path, fd: fd)
                    if case .state(let state) = port.exchange(SerialPort.text(for: .query)) {
                        return (port, state)
                    }
                    port.close()
                }
                silentPaths.insert(path)
            }
            return nil
        }
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

    // MARK: - Talking

    /// Writes one command line and waits briefly for the status line.
    private func exchange(_ command: String) -> KeyboardReply? {
        guard fd >= 0 else { return nil }
        tcflush(fd, TCIFLUSH)
        let bytes = Array((command + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { return nil }

        var received = ""
        let deadline = Date().addingTimeInterval(0.4)
        var buffer = [UInt8](repeating: 0, count: 64)

        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { continue }
            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return nil }

            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno != EAGAIN { return nil }
            if n > 0 { received += String(decoding: buffer[0..<n], as: UTF8.self) }

            while let newline = received.firstIndex(of: "\n") {
                let line = String(received[..<newline]).trimmingCharacters(in: .whitespaces)
                received = String(received[received.index(after: newline)...])
                if let reply = KeyboardReply(line: line) { return reply }
            }
        }
        return nil
    }
}
