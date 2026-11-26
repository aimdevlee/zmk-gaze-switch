import Foundation
import IOKit.hid

/// The module's vendor HID interfaces currently attached, over USB or Bluetooth.
///
/// They are found by usage page, so nothing else is touched: the keyboard's
/// key-input interface is a separate device we never open.
final class HIDInterfaces {
    // USAGE_PAGE, USAGE and REPORT_SIZE in ../../../src/hid.c.
    private static let usagePage = 0xFF9A
    private static let usage = 0x01
    fileprivate static let reportSize = 32
    /// A link that has just come up can miss its first `?`, so an interface that
    /// didn't answer is only left alone for this long.
    private static let silenceLifetime = 3.0

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let queue: DispatchQueue
    private let onChange: () -> Void
    /// Interfaces with a link open on them.
    private var links: [IOHIDDevice: HIDLink] = [:]
    /// Interfaces that matched but didn't answer; forgotten when the set of
    /// interfaces changes, or after `silenceLifetime`.
    private var silent: (devices: Set<IOHIDDevice>, since: Date) = ([], .distantPast)

    /// Every callback, `onChange` included, arrives on `queue`.
    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Starts watching. Call it on `queue`, once the owner holds this object:
    /// `onChange` is called before this returns if an interface is already attached.
    func startWatching() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: Self.usagePage,
            kIOHIDDeviceUsageKey: Self.usage,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            Unmanaged<HIDInterfaces>.fromOpaque(context!).takeUnretainedValue().changed(removed: nil)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<HIDInterfaces>.fromOpaque(context!).takeUnretainedValue().changed(removed: device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, _, report, length in
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let bytes = UnsafeBufferPointer(start: report, count: length).prefix { $0 != 0 }
            Unmanaged<HIDInterfaces>.fromOpaque(context!).takeUnretainedValue()
                .links[device]?.received(String(decoding: bytes, as: UTF8.self))
        }, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
    }

    /// A link on an interface of that kind that has no link yet and hasn't just failed to answer.
    func openLink(bluetooth: Bool) -> HIDLink? {
        if Date().timeIntervalSince(silent.since) > Self.silenceLifetime { silent.devices = [] }
        let attached = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let device = attached.first(where: {
            Self.isBluetooth($0) == bluetooth && links[$0] == nil && !silent.devices.contains($0)
        }) else { return nil }

        let link = HIDLink(device: device, bluetooth: bluetooth, queue: queue) { [unowned self] in
            links[device] = nil
        }
        links[device] = link
        return link
    }

    /// Closes a link whose interface didn't answer, and leaves that interface alone for a while.
    func giveUp(on link: HIDLink) {
        silent.devices.insert(link.device)
        silent.since = Date()
        link.close()
    }

    private func changed(removed: IOHIDDevice?) {
        silent.devices = []
        if let removed { links[removed]?.lose() }
        onChange()
    }

    private static func isBluetooth(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        return transport.lowercased().contains("bluetooth")
    }
}

/// One of the module's HID interfaces, opened.
///
/// A command is ASCII in an output report, zero padded; the reply is one input
/// report. Replies carry no reference to their command, so only one command is
/// out at a time and every reply belongs to it.
final class HIDLink: KeyboardTransport {
    let route: KeyboardLink.Route
    let isStillThere = true // a removed interface is reported by `HIDInterfaces`
    var onEvent: ((KeyboardEvent) -> Void)?

    fileprivate let device: IOHIDDevice
    private let queue: DispatchQueue
    private let onClose: () -> Void
    private var isClosed = false

    /// Over Bluetooth a reply can take most of a second: the keyboard only wakes
    /// its radio every so often while idle.
    private static let replyTimeout = 2.0

    /// The command that is out, and what gives up on it.
    private var awaited: (text: String, timeout: DispatchWorkItem)?
    /// Asked for while `awaited` was out; sent when its reply arrives. A newer
    /// request replaces it: only the last thing asked of the keyboard matters.
    private var waiting: KeyboardCommand?

    fileprivate init(device: IOHIDDevice, bluetooth: Bool, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.device = device
        self.route = bluetooth ? .bluetoothHID : .usbHID
        self.queue = queue
        self.onClose = onClose
    }

    func send(_ command: KeyboardCommand) {
        guard !isClosed else { return }
        if awaited == nil {
            transmit(command)
        } else {
            waiting = command
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        awaited?.timeout.cancel()
        awaited = nil
        waiting = nil
        onClose()
    }

    /// No answer, or the interface went away. The owner closes us.
    fileprivate func lose() {
        guard !isClosed else { return }
        awaited?.timeout.cancel()
        awaited = nil
        waiting = nil
        onEvent?(.lost)
    }

    fileprivate func received(_ text: String) {
        guard !isClosed, let command = awaited, let reply = KeyboardReply(line: text) else { return }
        command.timeout.cancel()
        awaited = nil
        switch reply {
        case .state(let state): onEvent?(.state(state))
        case .rejected: onEvent?(.rejected(command: command.text))
        }
        // The event may have closed us.
        if !isClosed, awaited == nil, let next = waiting {
            waiting = nil
            transmit(next)
        }
    }

    private func transmit(_ command: KeyboardCommand) {
        let text = Self.text(for: command)
        var report = Array(text.utf8.prefix(HIDInterfaces.reportSize))
        report += [UInt8](repeating: 0, count: HIDInterfaces.reportSize - report.count)

        let timeout = DispatchWorkItem { [weak self] in self?.lose() }
        awaited = (text, timeout)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count) == kIOReturnSuccess else {
            lose()
            return
        }
        queue.asyncAfter(deadline: .now() + Self.replyTimeout, execute: timeout)
    }

    private static func text(for command: KeyboardCommand) -> String {
        switch command {
        case .query: return "?"
        // `M` lets the keyboard work out what "the sender" is: USB over a
        // cable, our own BLE profile over Bluetooth.
        case .selectThisMac: return "M"
        case .selectProfile(let profile): return "B\(profile)"
        }
    }
}
