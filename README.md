# zmk-gaze-switch

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md)

Your keyboard's output follows the screen you are looking at.

- Look at the MacBook screen → **USB output (this Mac)**
- Look toward the other computer → **BLE profile n (the other computer)**

This repository holds two things.

| Path | Contents |
|---|---|
| `/` (repository root) | A ZMK module. Its `host-output-switch` snippet lets the host change the output over USB serial |
| `app/` | **GazeSwitch**, a menu bar app that reads your gaze from the MacBook camera and sends those commands |

```
MacBook camera → GazeSwitch ──USB serial──▶ keyboard (central)
                                             ├─ USB  → this Mac
                                             └─ BLE  → other computer (profile n)
```

It works while the keyboard (the central half, on a split) is **plugged into the Mac over USB**.
The module is usable without the app: the protocol is simple enough to drive from any script.

> Tested on one nRF52840 board only (E24 ZEN), on ZMK v0.3 (Zephyr 3.5).

## 1. Add the module to your firmware

`config/west.yml`:

```yaml
manifest:
  remotes:
    - name: aimdevlee
      url-base: https://github.com/aimdevlee
  projects:
    - name: zmk-gaze-switch
      remote: aimdevlee
      revision: v0.1.0
```

In `build.yaml`, add the snippet to the side you plug in over USB (the central half, on a split).

```yaml
include:
  - board: nice_nano_v2
    shield: my_keyboard
    snippet: host-output-switch
```

If you also use ZMK Studio, list `studio-rpc-usb-uart` **first**.

```yaml
    snippet: "studio-rpc-usb-uart host-output-switch"
```

### Things to know

- The snippet adds one more CDC ACM port on `&zephyr_udc0`, so your board needs a `zephyr_udc0` label.
- If you use a feature that assumes a single CDC ACM port (for example a 1200-baud bootloader trigger),
  point it at the port it should watch in your own overlay.
- Pair the other computer to a BLE profile beforehand (for example `&bt BT_SEL 1`).

## 2. Check it without the app

```bash
ls /dev/cu.usbmodem*
```

```bash
screen /dev/cu.usbmodemXXXX 115200
```

Type `?` and Enter. A reply like `ZMK-HOS 1 U 1 1` means this is the switch port.
Check that `B1` selects BLE profile 1 and `U` goes back to USB.
(To quit `screen`: `Ctrl-A`, then `K`, `y`.)

## 3. Build and run GazeSwitch

Requires macOS 13 or later and the Xcode command line tools.

```bash
cd app && ./bundle.sh
```

```bash
open app/GazeSwitch.app
```

The first launch asks for camera access. The app follows the system language (English, Korean or Japanese);
you can also pick one under **Language** in the menu. From the menu bar icon:

- **BLE profile of the other computer**: pick the profile you paired.
- **Start calibration** (required, about one minute): a full-screen guide appears on the MacBook
  and each step is also read aloud, because you can't see this screen while looking at the other computer.
  Recording starts on the "ting" sound and ends on the "pop". Press Esc to cancel.
  - Looking at the MacBook: naturally → head still, eyes only → head toward the other computer, eyes on the MacBook
  - Looking at the other computer: naturally → both edges of its screen → head facing the MacBook, eyes only → head fully turned
- **Switch to this Mac now / Switch to the other computer now**: manual switch.

## How it decides

- Six signals are read per frame: head yaw and pitch (Vision), pupil position left-right and up-down
  (Vision landmarks), and iris position left-right and up-down (centre of the dark pixels inside the eye outline).
- From the calibration data it takes each signal's mean and the **correlations between signals** (LDA)
  and finds the combination that best separates the two screens. Head and eyes are each ambiguous on
  their own, but "head angle + eye angle" is not.
- The score is scaled to −0.5 for the Mac and +0.5 for the other computer. It switches only after the
  score stays **beyond ±0.08 for 0.4 seconds**.
- When no face is visible it keeps the current output.
- **With a mask on**, the eye outline is not detected reliably, so only head direction is used.

## Privacy

No video is stored or sent anywhere. Calibration numbers (numbers only) are kept in
`~/Library/Application Support/GazeSwitch/` and never leave this Mac.

To diagnose eye detection, you can have it keep cropped eye images from calibration in `eyes/`
inside that folder (off by default).

```bash
defaults write io.github.aimdevlee.GazeSwitch debugEyeImages -bool true
```

## Protocol

115200 baud, line based (`\n` or `\r`). The keyboard replies only while the host asserts DTR.

| Command | Action |
|---|---|
| `U` | Select the USB output |
| `B` | Select the BLE output (keep the current profile) |
| `B<n>` | Select BLE profile n, then the BLE output |
| `?` | Report state only |

Reply: `ZMK-HOS 1 <U|B> <profile> <BLE connected 0|1>`, or `ZMK-HOS 1 ERR` on failure.

If you send `B` while the BLE profile is not connected, ZMK keeps using USB and moves to BLE the moment it connects.

## License

MIT
