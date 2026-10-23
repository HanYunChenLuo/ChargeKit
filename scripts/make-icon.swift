// make-icon.swift — generate the ChargeKit app icon masters (1024 px).
// Two palettes are coded (`light`/`dark`); make-icon.sh currently folds
// only the dark one into the icns (a single dual-mode-friendly icon —
// appearance variants need an asset catalog / actool, see make-icon.sh).
// Motif: rounded square + the app's own battery gauge (translucent
// track, green fill ~80 %, electrode nub).
// Build:  swiftc scripts/make-icon.swift -o /tmp/make-icon
//         /tmp/make-icon light|dark /tmp/master-<mode>.png
// Then:   make-icon.sh folds it into ChargeKit.icns.
import AppKit

let dark = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "dark"
let outPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "/tmp/ChargeKit-icon-master-\(dark ? "dark" : "light").png"

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = CGFloat(size)
let rect = CGRect(x: 0, y: 0, width: s, height: s)

// Background: rounded square, vertical gradient per appearance.
let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
ctx.saveGState()
bg.addClip()
let bgColors: [CGColor] = dark
    ? [NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.31, alpha: 1).cgColor,
       NSColor(calibratedWhite: 0.07, alpha: 1).cgColor]
    : [NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).cgColor,
       NSColor(calibratedRed: 0.80, green: 0.81, blue: 0.85, alpha: 1).cgColor]
let bgGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    bgGrad, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])
ctx.restoreGState()

// Battery capsule (horizontal, centered; mirrors BatteryGaugeView).
let capsuleW = s * 0.56
let capsuleH = s * 0.30
let capsuleX = (s - capsuleW) / 2 - s * 0.02   // room for the nub on the right
let capsuleY = (s - capsuleH) / 2
let track = NSBezierPath(
    roundedRect: CGRect(x: capsuleX, y: capsuleY, width: capsuleW, height: capsuleH),
    xRadius: capsuleH / 2, yRadius: capsuleH / 2)
NSColor(white: dark ? 0.92 : 0.0, alpha: dark ? 0.22 : 0.12).setFill()
track.fill()

// Green fill at ~80 %, subtle vertical gradient.
let inset = capsuleH * 0.14
let fillW = (capsuleW - inset * 2) * 0.80
let fill = NSBezierPath(
    roundedRect: CGRect(
        x: capsuleX + inset, y: capsuleY + inset,
        width: fillW, height: capsuleH - inset * 2),
    xRadius: (capsuleH - inset * 2) / 2, yRadius: (capsuleH - inset * 2) / 2)
ctx.saveGState()
fill.addClip()
let fillColors: [CGColor] = dark
    ? [NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.41, alpha: 1).cgColor,
       NSColor(calibratedRed: 0.05, green: 0.60, blue: 0.24, alpha: 1).cgColor]
    : [NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.36, alpha: 1).cgColor,
       NSColor(calibratedRed: 0.02, green: 0.55, blue: 0.22, alpha: 1).cgColor]
let fillGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fillColors as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    fillGrad,
    start: CGPoint(x: 0, y: capsuleY + capsuleH), end: CGPoint(x: 0, y: capsuleY),
    options: [])
ctx.restoreGState()

// Electrode nub.
let nub = NSBezierPath(
    roundedRect: CGRect(
        x: capsuleX + capsuleW + s * 0.025,
        y: capsuleY + capsuleH * 0.32,
        width: s * 0.04, height: capsuleH * 0.36),
    xRadius: s * 0.02, yRadius: s * 0.02)
NSColor(white: dark ? 0.92 : 0.0, alpha: dark ? 0.40 : 0.28).setFill()
nub.fill()

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: outPath)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("\(dark ? "dark" : "light") master written: \(out.path)")
