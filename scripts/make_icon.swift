import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }
    let s = size
    // Background rounded square
    let margin = s * 0.06
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = s * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    // Subtle border
    ctx.setStrokeColor(CGColor(red: 0.0, green: 0.75, blue: 0.90, alpha: 0.45))
    ctx.setLineWidth(s * 0.02)
    ctx.addPath(path)
    ctx.strokePath()

    // Battery body
    let bw = s * 0.42
    let bh = s * 0.58
    let bx = (s - bw) / 2
    let by = s * 0.18
    let battery = CGRect(x: bx, y: by, width: bw, height: bh)
    let br = s * 0.06
    let bPath = CGPath(roundedRect: battery, cornerWidth: br, cornerHeight: br, transform: nil)
    ctx.setStrokeColor(CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1))
    ctx.setLineWidth(s * 0.035)
    ctx.addPath(bPath)
    ctx.strokePath()
    // Battery terminal
    let tw = bw * 0.35
    let th = s * 0.05
    let terminal = CGRect(x: (s - tw) / 2, y: by + bh, width: tw, height: th)
    ctx.setFillColor(CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: terminal, cornerWidth: th/2, cornerHeight: th/2, transform: nil))
    ctx.fillPath()
    // Fill level (cyan→green)
    let pad = s * 0.05
    let fillH = (bh - pad * 2) * 0.62
    let fill = CGRect(x: bx + pad, y: by + pad, width: bw - pad * 2, height: fillH)
    let colors = [
        CGColor(red: 0.0, green: 0.55, blue: 0.75, alpha: 1),
        CGColor(red: 0.0, green: 0.95, blue: 0.7, alpha: 1)
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.saveGState()
        let clip = CGPath(roundedRect: fill, cornerWidth: br * 0.5, cornerHeight: br * 0.5, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: fill.midX, y: fill.minY),
                               end: CGPoint(x: fill.midX, y: fill.maxY),
                               options: [])
        ctx.restoreGState()
    }
    // Depth wave (fathom) across mid
    ctx.setStrokeColor(CGColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.9))
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)
    let waveY = by + pad + fillH * 0.55
    let wave = CGMutablePath()
    let w0 = bx + pad
    let w1 = bx + bw - pad
    wave.move(to: CGPoint(x: w0, y: waveY))
    let mid = (w0 + w1) / 2
    wave.addCurve(to: CGPoint(x: w1, y: waveY),
                  control1: CGPoint(x: mid - (w1-w0)*0.15, y: waveY + s*0.04),
                  control2: CGPoint(x: mid + (w1-w0)*0.15, y: waveY - s*0.04))
    ctx.addPath(wave)
    ctx.strokePath()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, _ path: String, _ px: Int) -> Bool {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/fathom-icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let base = drawIcon(size: 1024)
var ok = true
for px in sizes {
    let p = "\(outDir)/icon_\(px).png"
    if !writePNG(base, p, px) { ok = false; print("fail", px) }
    else { print("ok", px) }
}
// also 1024 master
_ = writePNG(base, "\(outDir)/AppIcon-1024.png", 1024)
exit(ok ? 0 : 1)
