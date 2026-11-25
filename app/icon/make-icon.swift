// Draws the GazeSwitch app icon: an eye above a split keyboard, with the half
// it looks at lit.
//   swift icon/make-icon.swift <output.png>     (1024 x 1024)
import AppKit

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}
func rounded(_ rect: CGRect, _ corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}
func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
}

// Tile: the macOS icon grid leaves a 100 pt margin around an 824 pt rounded square.
let tile = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
ctx.addPath(tile)
ctx.setFillColor(color(0x121419))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.drawLinearGradient(gradient(0x30343F, 0x121419), start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Eye: a white almond with the iris turned to the right.
let eyeCenter = CGPoint(x: 512, y: 700)
let eyeHalfWidth: CGFloat = 190
let eye = CGMutablePath()
eye.move(to: CGPoint(x: eyeCenter.x - eyeHalfWidth, y: eyeCenter.y))
eye.addQuadCurve(to: CGPoint(x: eyeCenter.x + eyeHalfWidth, y: eyeCenter.y),
                 control: CGPoint(x: eyeCenter.x, y: eyeCenter.y + eyeHalfWidth * 1.21))
eye.addQuadCurve(to: CGPoint(x: eyeCenter.x - eyeHalfWidth, y: eyeCenter.y),
                 control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - eyeHalfWidth * 1.21))
eye.closeSubpath()
ctx.addPath(eye)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()

ctx.saveGState()
ctx.addPath(eye)
ctx.clip()
let iris = CGPoint(x: eyeCenter.x + 55, y: eyeCenter.y)
for (radius, hex) in [(78, 0x171A2B), (34, 0xFFFFFF)] as [(CGFloat, UInt32)] {
    ctx.setFillColor(color(hex))
    ctx.fillEllipse(in: CGRect(x: iris.x - radius, y: iris.y - radius, width: radius * 2, height: radius * 2))
}
ctx.restoreGState()

// A keycap: a darker base with a lighter top face set slightly high.
func keycap(_ rect: CGRect, base: UInt32, top: UInt32, bottom: UInt32) {
    let corner = rect.width * 0.17, inset = rect.width * 0.075, lift = rect.width * 0.06
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.03), blur: rect.width * 0.06,
                  color: color(0x000000, 0.45))
    ctx.addPath(rounded(rect, corner))
    ctx.setFillColor(color(base))
    ctx.fillPath()
    ctx.restoreGState()

    let face = CGRect(x: rect.minX + inset, y: rect.minY + inset + lift,
                      width: rect.width - inset * 2, height: rect.height - inset * 2 - lift * 0.4)
    ctx.saveGState()
    ctx.addPath(rounded(face, corner * 0.75))
    ctx.clip()
    ctx.drawLinearGradient(gradient(top, bottom), start: CGPoint(x: face.midX, y: face.maxY),
                           end: CGPoint(x: face.midX, y: face.minY), options: [])
    ctx.restoreGState()
}

// Split keyboard: two halves of 2 x 2 keys tilted outward. The right half,
// where the eye looks, is lit.
let key: CGFloat = 128, gap: CGFloat = 14
for (centerX, tilt, lit) in [(328, -0.17, false), (696, 0.17, true)] as [(CGFloat, CGFloat, Bool)] {
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: 340)
    ctx.rotate(by: tilt)
    for row in 0..<2 {
        for col in 0..<2 {
            let rect = CGRect(x: (CGFloat(col) - 1) * (key + gap) + gap / 2,
                              y: (CGFloat(row) - 1) * (key + gap - 6) + gap / 2, width: key, height: key)
            if lit {
                keycap(rect, base: 0x16897F, top: 0x48E6D6, bottom: 0x2FD3C4)
            } else {
                keycap(rect, base: 0x23262F, top: 0x5A6072, bottom: 0x474C5B)
            }
        }
    }
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
