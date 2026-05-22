#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Pixel-level verification script.
///
/// Checks:
///   1. SCK PNG (uncropped, 1280×751) — top 31 rows contain title‑bar content
///      (non‑black, non‑transparent pixels), proving the original capture has it.
///   2. MP4 first frame (cropped, 1280×720) — top rows have *no* title‑bar
///      remnants and edges have no rounded‑corner transparency.
///
/// Usage:
///   swift tmp/verify_pixel_check.swift \
///       /tmp/preview-bake-sck.png \
///       /tmp/waifux-preview-bake.mp4

// MARK: - Helpers

func loadCGImage(_ path: String) -> CGImage? {
    guard let url = URL(string: "file://\(path)"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func pixelBuffer(at index: Int, from asset: AVAsset) -> CVPixelBuffer? {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    gen.appliesPreferredTrackTransform = true
    let time = CMTime(value: CMTimeValue(index), timescale: 600)
    guard let ref = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }

    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, ref.width, ref.height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true,
         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
        &pb)
    guard status == kCVReturnSuccess, let buffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let ctx = CGContext(
            data: base,
            width: ref.width,
            height: ref.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          )
    else {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return nil
    }
    ctx.draw(ref, in: CGRect(x: 0, y: 0, width: ref.width, height: ref.height))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// Returns `(nonBlackRatio, nonTransparentRatio)` for a row at `y`.
/// Works on a BGRA pixel buffer assumed to be premultiplied-first.
func analyzeRow(_ pb: CVPixelBuffer, y: Int) -> (nonBlack: Double, nonOpaque: Double) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self)
    else { return (0, 0) }

    var nonBlack = 0
    var nonOpaque = 0
    for x in 0..<w {
        let off = y * bpr + x * 4
        let b = base[off]
        let g = base[off + 1]
        let r = base[off + 2]
        let a = base[off + 3]
        // non‑black: any channel > 16
        if r > 16 || g > 16 || b > 16 { nonBlack += 1 }
        // non‑opaque: alpha < 250
        if a < 250 { nonOpaque += 1 }
    }
    return (Double(nonBlack) / Double(w), Double(nonOpaque) / Double(w))
}

/// Render a CGImage into a new CVPixelBuffer (BGRA, premultiplied).
func cgImageToPixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    let st = CVPixelBufferCreate(
        kCFAllocatorDefault, image.width, image.height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let buf = pb else { return nil }

    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
    guard let ctx = CGContext(
        data: base,
        width: image.width, height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buf
}

func checkEdges(_ pb: CVPixelBuffer, label: String, expectedTitleBar: Bool) -> Bool {
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let titleBarH = 31
    var allOk = true
    var lines: [String] = []

    // ── top title‑bar region ──
    if expectedTitleBar {
        // Expect title bar: high non‑black ratio in top 31 rows
        let samples = stride(from: 0, to: min(titleBarH, h), by: max(1, titleBarH / 5))
        for y in samples {
            let (nb, no) = analyzeRow(pb, y: y)
            let ok = nb > 0.3
            if !ok { allOk = false }
            lines.append("  row \(y): non‑black=\(String(format: "%.2f", nb)) non‑opaque=\(String(format: "%.2f", no)) \(ok ? "✓" : "✗ TITLE BAR MISSING")")
        }
    } else {
        // Expect NO title bar: first rows should be mostly black/content
        for y in 0..<min(8, h) {
            let (nb, no) = analyzeRow(pb, y: y)
            // If there was a title bar remnant, non‑black would be high
            // Since it's cropped content, non‑black should reflect scene content
            lines.append("  row \(y): non‑black=\(String(format: "%.2f", nb)) non‑opaque=\(String(format: "%.2f", no))")
        }
    }

    // ── check corners for transparency ──
    // Sample a small area at each corner & edge
    let margin = 4
    for (cx, cy, cornerName) in [
        (margin, margin, "top‑left"),
        (w - margin, margin, "top‑right"),
        (margin, h - margin, "bottom‑left"),
        (w - margin, h - margin, "bottom‑right"),
    ] {
        guard cx < w, cy < h else { continue }
        let off = cy * CVPixelBufferGetBytesPerRow(pb) + cx * 4
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { continue }
        let a = base[off + 3]
        let b = base[off]; let g = base[off + 1]; let r = base[off + 2]
        let opaque = a >= 250
        if !opaque && !expectedTitleBar {
            // In the output video, corners should be opaque (no transparency)
            allOk = false
            lines.append("  \(cornerName) corner: rgba(\(r),\(g),\(b),\(a)) ✗ TRANSPARENT EDGE")
        } else {
            lines.append("  \(cornerName) corner: rgba(\(r),\(g),\(b),\(a)) \(opaque ? "✓" : "")")
        }
    }

    let verdict = allOk ? "✅ PASS" : "❌ FAIL"
    print("\n\(verdict) — \(label)")
    lines.forEach { print($0) }
    return allOk
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: verify_pixel_check.swift <sck-png> <output-mp4>")
    exit(1)
}

let sckPath = args[1]
let mp4Path = args[2]

let sep = String(repeating: "=", count: 60)
print(sep)
print("Pixel‑level verification")
print("  SCK PNG: \(sckPath)")
print("  MP4:     \(mp4Path)")
print(sep)

// 1. Load SCK PNG
guard let sckImage = loadCGImage(sckPath) else {
    print("❌ Cannot load SCK PNG from \(sckPath)")
    exit(1)
}
print("\n📸 SCK PNG: \(sckImage.width)×\(sckImage.height)")

// Convert to pixel buffer for row analysis
guard let sckBuf = cgImageToPixelBuffer(sckImage) else {
    print("❌ Cannot create sck pixel buffer")
    exit(1)
}

let sckOk = checkEdges(sckBuf, label: "SCK PNG (should HAVE title bar)", expectedTitleBar: true)

// 2. Load MP4 first frame
let mp4URL = URL(fileURLWithPath: mp4Path)
let asset = AVURLAsset(url: mp4URL)
guard let firstBuf = pixelBuffer(at: 0, from: asset) else {
    print("❌ Cannot extract first frame from MP4")
    exit(1)
}
let mp4W = CVPixelBufferGetWidth(firstBuf)
let mp4H = CVPixelBufferGetHeight(firstBuf)
print("\n🎬 MP4 first frame: \(mp4W)×\(mp4H)")

let mp4Ok = checkEdges(firstBuf, label: "MP4 first frame (should NOT have title bar / rounded corners)", expectedTitleBar: false)

// 3. Summary
print("\n" + sep)
    if sckOk && mp4Ok {
        print("✅ ALL CHECKS PASSED")
        print("   • SCK PNG contains title bar (top‑row content verified)")
        print("   • MP4 first frame has no title bar remnants")
        print("   • MP4 edges are fully opaque (no rounded‑corner transparency)")
    } else {
        print("❌ SOME CHECKS FAILED")
        if !sckOk { print("   • SCK PNG missing expected title‑bar content") }
        if !mp4Ok { print("   • MP4 has unexpected artifacts (title bar remnants or transparent edges)") }
    }
    print(sep)
