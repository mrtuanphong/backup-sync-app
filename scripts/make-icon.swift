// Draws the app icon (green squircle, white circular "history" arrow around a clock) and writes a 1024 px PNG.
// Usage: swift scripts/make-icon.swift <out.png>   (scripts/make-icon.sh turns it into src/AppIcon.icns)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824 pt body centred on a 1024 canvas, continuous-corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.30))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x1E9E4A)); ctx.fillPath()
ctx.restoreGState()

// Green vertical gradient (light top → deep bottom).
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0x5EDC7A), rgb(0x2DB75A), rgb(0x17853F)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Subtle top highlight.
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
ctx.restoreGState()

let c = CGPoint(x: 512, y: 512)
let white = rgb(0xFFFFFF)

// Glyph shadow so the white reads on the light top of the gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0B5A27, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

// Circular arrow: an open ring, counter-clockwise ("go back in time"), with an arrowhead at its upper-left end.
let r: CGFloat = 255, lw: CGFloat = 64
let startDeg: CGFloat = 125, endDeg: CGFloat = 125 + 300   // gap at the top-left where the arrowhead sits
ctx.setStrokeColor(white); ctx.setLineWidth(lw); ctx.setLineCap(.round)
ctx.addArc(center: c, radius: r, startAngle: startDeg * .pi / 180, endAngle: endDeg * .pi / 180, clockwise: false)
ctx.strokePath()

// Arrowhead at the start of the arc, pointing along the counter-clockwise direction of travel (backwards in time).
let a = startDeg * .pi / 180
let tip = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
let tangent = CGPoint(x: sin(a), y: -cos(a))            // clockwise tangent = direction the head points
let normal = CGPoint(x: cos(a), y: sin(a))
let headLen: CGFloat = 120, headHalf: CGFloat = 92
let p1 = CGPoint(x: tip.x + tangent.x * headLen * 0.55, y: tip.y + tangent.y * headLen * 0.55)
let base = CGPoint(x: tip.x - tangent.x * headLen * 0.45, y: tip.y - tangent.y * headLen * 0.45)
let p2 = CGPoint(x: base.x + normal.x * headHalf, y: base.y + normal.y * headHalf)
let p3 = CGPoint(x: base.x - normal.x * headHalf, y: base.y - normal.y * headHalf)
ctx.setFillColor(white)
ctx.setLineJoin(.round); ctx.setLineWidth(18)
ctx.move(to: p1); ctx.addLine(to: p2); ctx.addLine(to: p3); ctx.closePath()
ctx.drawPath(using: .fillStroke)

// Clock hands: minute hand up, hour hand to ~4 o'clock, with a centre dot.
ctx.setLineCap(.round)
ctx.setLineWidth(52)
ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 150)); ctx.strokePath()
let hourA: CGFloat = -30 * .pi / 180
ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + 115 * cos(hourA), y: c.y + 115 * sin(hourA))); ctx.strokePath()
ctx.fillEllipse(in: CGRect(x: c.x - 42, y: c.y - 42, width: 84, height: 84))

ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
