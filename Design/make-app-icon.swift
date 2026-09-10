import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }
context.setAllowsAntialiasing(true)

// macOS icon grid: the art sits inside ~82% of the canvas with a squircle mask.
let inset = size * 0.09
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

context.saveGState()
squircle.addClip()
let colors = [
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.20, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.38, alpha: 1).cgColor
] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
}
context.restoreGState()

// A gate: two posts with a lintel, and a focus dot passing through.
let center = CGPoint(x: size / 2, y: size / 2)
let gateWidth = rect.width * 0.46
let gateHeight = rect.height * 0.50
let postWidth = gateWidth * 0.20
let amber = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)

func roundedBar(_ r: CGRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

let left = CGRect(
    x: center.x - gateWidth / 2,
    y: center.y - gateHeight / 2,
    width: postWidth,
    height: gateHeight
)
let right = CGRect(
    x: center.x + gateWidth / 2 - postWidth,
    y: center.y - gateHeight / 2,
    width: postWidth,
    height: gateHeight
)
roundedBar(left, radius: postWidth / 2, color: .white)
roundedBar(right, radius: postWidth / 2, color: .white)

let lintel = CGRect(
    x: center.x - gateWidth / 2,
    y: center.y + gateHeight / 2 - postWidth,
    width: gateWidth,
    height: postWidth
)
roundedBar(lintel, radius: postWidth / 2, color: .white)

// The one thing that gets through.
let dotRadius = gateWidth * 0.135
amber.setFill()
NSBezierPath(ovalIn: CGRect(
    x: center.x - dotRadius,
    y: center.y - gateHeight * 0.10 - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2
)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
