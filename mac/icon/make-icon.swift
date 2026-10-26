// Draws Longarm's app icon: a phone reaching across to a Mac pointer, on a dark squircle.
//   swift mac/icon/make-icon.swift   → writes mac/icon/AppIcon.icns (and a 1024 px preview PNG)
import AppKit

let orange = NSColor(srgbRed: 1.0, green: 0.56, blue: 0.24, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024   // everything below is on a 1024 grid
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

    // macOS icon body: 824 × 824 squircle, centred, with a soft drop shadow.
    let body = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 186 * s, yRadius: 186 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)])!.draw(in: body, angle: -90)

    // The phone, bottom left: a light body with a dark screen.
    let phone = NSBezierPath(roundedRect: rect(220, 190, 230, 400), xRadius: 46 * s, yRadius: 46 * s)
    NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1).setFill()
    phone.fill()
    let screen = NSBezierPath(roundedRect: rect(244, 230, 182, 320), xRadius: 26 * s, yRadius: 26 * s)
    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setFill()
    screen.fill()
    // The arm: from a fingertip on the phone's screen, up and across to the pointer.
    let arm = NSBezierPath()
    arm.move(to: point(370, 430))
    arm.curve(to: point(640, 690), controlPoint1: point(420, 640), controlPoint2: point(520, 700))
    arm.lineWidth = 44 * s
    arm.lineCapStyle = .round
    orange.setStroke()
    arm.stroke()

    // A fingertip dot on the screen, where the arm starts.
    orange.setFill()
    NSBezierPath(ovalIn: rect(335, 395, 70, 70)).fill()

    // The Mac pointer, top right, where the arm arrives.
    let pointer = NSBezierPath()
    pointer.move(to: point(620, 820))
    pointer.line(to: point(620, 560))
    pointer.line(to: point(683, 618))
    pointer.line(to: point(725, 525))
    pointer.line(to: point(770, 545))
    pointer.line(to: point(728, 637))
    pointer.line(to: point(810, 640))
    pointer.close()
    pointer.lineJoinStyle = .round
    NSColor.white.setFill()
    pointer.fill()
    NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).setStroke()
    pointer.lineWidth = 16 * s
    pointer.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}


let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: here.appendingPathComponent("AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(here.path)/AppIcon.icns" : "iconutil failed")
