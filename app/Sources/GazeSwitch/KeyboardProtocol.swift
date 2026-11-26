import Foundation

/// What the app asks of the keyboard's host-output-switch module (see ../../../src/core.c).
enum KeyboardCommand: Equatable {
    /// Report the state, change nothing.
    case query
    /// Point the keyboard at this Mac.
    case selectThisMac
    /// Point the keyboard at a BLE profile (the other computer).
    case selectProfile(Int)
}

/// What a link to the keyboard reports back, always on the link's queue.
enum KeyboardEvent {
    case state(KeyboardLink.State)
    /// The keyboard refused the command with this text.
    case rejected(command: String)
    /// No answer, or the link went away.
    case lost
}

/// One way of reaching the keyboard. All calls are made on the link's queue.
protocol KeyboardTransport: AnyObject {
    var route: KeyboardLink.Route { get }
    /// False once the thing we talk through has gone, even if nothing has failed yet.
    var isStillThere: Bool { get }
    var onEvent: ((KeyboardEvent) -> Void)? { get set }
    /// Answered with exactly one event.
    func send(_ command: KeyboardCommand)
    func close()
}

/// One reply line of the module.
///
/// Serial: `ZMK-HOS 1 <U|B> <profile> <ble-connected>`.
/// HID: `ZMK-HOS 2 <U|B> <profile> <ble-connected> <me> <sender>`.
/// Either: `ZMK-HOS <n> ERR`.
enum KeyboardReply {
    case state(KeyboardLink.State)
    case rejected

    /// `ZEN-HOS` is the name the protocol had before it left the ZEN firmware;
    /// keyboards flashed back then still answer with it.
    private static let identities: Set<Substring> = ["ZMK-HOS", "ZEN-HOS"]

    init?(line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, Self.identities.contains(parts[0]) else { return nil }
        if parts.count == 3, parts[2] == "ERR" {
            self = .rejected
            return
        }
        let usb = parts[2] == "U"
        let onThisMac: Bool
        switch (parts[1], parts.count) {
        case ("1", 5): onThisMac = usb // serial only exists over USB
        case ("2", 7): onThisMac = parts[5] == "1"
        default: return nil
        }
        guard let profile = Int(parts[3]) else { return nil }
        self = .state(KeyboardLink.State(usb: usb, profile: profile, bleConnected: parts[4] == "1",
                                         onThisMac: onThisMac))
    }
}
