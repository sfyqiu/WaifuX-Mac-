import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct WindowInfo {
    let id: CGWindowID
    let bounds: CGRect
}

enum VerifyError: Error, CustomStringConvertible {
    case usage
    case screenCaptureDenied
    case launchFailed(String)
    case windowNotFound
    case placementFailed(String)
    case captureFailed(String)
    case writerFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: verify_preview_bake <wallpaper-wgpu> <wallpaper-dir-or-scene.pkg> <assets-dir> <output.mp4> [width height duration fps]"
        case .screenCaptureDenied:
            return "screen capture permission denied"
        case .launchFailed(let message),
             .placementFailed(let message),
             .captureFailed(let message),
             .writerFailed(let message):
            return message
        case .windowNotFound:
            return "renderer window not found"
        }
    }
}

@main
struct VerifyPreviewBake {
    static let previewWindowTitlebarHeight: Int = {
        // --wallpaper 模式下窗口无标题栏
        CommandLine.arguments.contains("--wallpaper-mode") ? 0 : 31
    }()

    static func main() async {
        do {
            try await run()
            exit(0)
        } catch {
            print("[verify] ERROR: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { throw VerifyError.usage }

        let rendererURL = URL(fileURLWithPath: args[1])
        let scenePath = args[2]
        let assetsPath = args[3]
        let outputURL = URL(fileURLWithPath: args[4])
        let width = args.count > 5 ? Int(args[5]) ?? 1280 : 1280
        let height = args.count > 6 ? Int(args[6]) ?? 720 : 720
        let duration = args.count > 7 ? Double(args[7]) ?? 3.0 : 3.0
        let fps = args.count > 8 ? Int(args[8]) ?? 15 : 15

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                throw VerifyError.screenCaptureDenied
            }
        }

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        print("[verify] screenCapture=ok accessibility=\(trusted ? "ok" : "not-trusted")")

        let process = Process()
        process.executableURL = rendererURL
        process.arguments = ["--release", "--", scenePath, "--assets", assetsPath, "--wallpaper", "--background"]
        process.currentDirectoryURL = rendererURL.deletingLastPathComponent()
        process.environment = rendererEnvironment(for: rendererURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw VerifyError.launchFailed("failed to launch renderer: \(error.localizedDescription)")
        }
        print("[verify] launched pid=\(process.processIdentifier) args=\(process.arguments?.joined(separator: " ") ?? "")")

        defer {
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }

        let initialWindow = try await waitForWindow(pid: process.processIdentifier, timeout: 12)
        print("[verify] window id=\(initialWindow.id) initial=\(rectString(initialWindow.bounds))")

        let isWallpaperMode = CommandLine.arguments.contains("--wallpaper-mode")
        let captureWidth: Int
        let captureHeight: Int

        if isWallpaperMode {
            // --wallpaper 模式下窗口已铺满桌面层，无需移动/缩放，无标题栏
            captureWidth = width
            captureHeight = height
            print("[verify] wallpaper-mode=on 跳过窗口放置 titleBarHeight=0")
        } else {
            // 普通预览窗口：移动到可视区域外并调整尺寸
            let outerW = width
            let outerH = height + Self.previewWindowTitlebarHeight
            captureWidth = outerW
            captureHeight = outerH
            let targetSize = CGSize(width: outerW, height: outerH)
            let targetOrigin = offscreenOrigin()
            let placedByAX = trusted && setWindowFrameUsingAX(pid: process.processIdentifier, windowID: initialWindow.id, origin: targetOrigin, size: targetSize)
            let placedByCGS = placedByAX ? false : setWindowFrameUsingCGS(windowID: initialWindow.id, origin: targetOrigin, size: targetSize, ownerPID: process.processIdentifier)
            print("[verify] placement ax=\(placedByAX) cgs=\(placedByCGS) outer=\(outerW)x\(outerH) content=\(width)x\(height)@\(Int(targetOrigin.x)),\(Int(targetOrigin.y))")
            guard placedByAX || placedByCGS else {
                throw VerifyError.placementFailed("failed to move and resize preview window")
            }

            guard let placedWindow = try await waitForWindowPlacement(windowID: initialWindow.id, origin: targetOrigin, width: outerW, height: outerH) else {
                let current = windowBounds(windowID: initialWindow.id).map(rectString) ?? "nil"
                throw VerifyError.placementFailed("window did not reach offscreen target; current=\(current)")
            }
            print("[verify] placed=\(rectString(placedWindow)) visibleRatio=\(String(format: "%.4f", visibleRatioOnActiveDisplays(placedWindow)))")
        }

        let sckFirstFrame = try? await waitForRenderableFrameWithScreenCaptureKit(
            windowID: initialWindow.id,
            width: captureWidth,
            height: captureHeight,
            timeout: 20
        )
        if let sckFrame = sckFirstFrame {
            let url = URL(fileURLWithPath: "/tmp/preview-bake-sck.png")
            savePNG(sckFrame, to: url)
            let crop = contentCropRect(for: sckFrame, width: width, height: height, titleBarHeight: VerifyPreviewBake.previewWindowTitlebarHeight)
            print("[verify] sckFrame=\(sckFrame.width)x\(sckFrame.height) crop=\(Int(crop.width))x\(Int(crop.height))@\(Int(crop.origin.x)),\(Int(crop.origin.y)) luma=\(String(format: "%.2f", averageLuma(sckFrame))) path=\(url.path)")
        } else {
            print("[verify] sckFrame=failed")
        }
        let firstFrame = try await waitForRenderableFrame(windowID: initialWindow.id, timeout: 20)
        print("[verify] cgFrame=\(firstFrame.width)x\(firstFrame.height)")

        try await encode(windowID: initialWindow.id, firstFrame: sckFirstFrame ?? firstFrame, outputURL: outputURL, width: width, height: height, duration: duration, fps: fps)
        try await inspectVideo(url: outputURL)
    }
}

func rendererEnvironment(for rendererURL: URL) -> [String: String] {
    let rendererDir = rendererURL.deletingLastPathComponent()
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = [
        rendererDir.path,
        rendererDir.deletingLastPathComponent().path,
        env["PATH"] ?? ""
    ].filter { !$0.isEmpty }.joined(separator: ":")
    env["DYLD_LIBRARY_PATH"] = [
        rendererDir.appendingPathComponent("lib").path,
        rendererDir.deletingLastPathComponent().appendingPathComponent("lib").path,
        env["DYLD_LIBRARY_PATH"] ?? ""
    ].filter { !$0.isEmpty }.joined(separator: ":")
    return env
}

func waitForWindow(pid: pid_t, timeout: TimeInterval) async throws -> WindowInfo {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if let window = findWindow(pid: pid) {
            return window
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw VerifyError.windowNotFound
}

func findWindow(pid: pid_t) -> WindowInfo? {
    guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var candidates: [(WindowInfo, CGFloat)] = []
    for item in list {
        guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int, ownerPID == pid else { continue }
        guard let number = item[kCGWindowNumber as String] as? CGWindowID else { continue }
        guard let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
        guard bounds.width >= 100, bounds.height >= 100 else { continue }
        let name = (item[kCGWindowName as String] as? String ?? "").lowercased()
        let score = bounds.width * bounds.height + (name.contains("wallpaper") ? 1_000_000 : 0)
        candidates.append((WindowInfo(id: number, bounds: bounds), score))
    }
    return candidates.max { $0.1 < $1.1 }?.0
}

func offscreenOrigin() -> CGPoint {
    let displays = activeDisplayUnionBounds()
    return CGPoint(x: displays.maxX + 128, y: max(displays.minY, 0) + 64)
}

func activeDisplayUnionBounds() -> CGRect {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    guard count > 0 else {
        return NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays.prefix(Int(count)).reduce(CGRect.null) { partial, displayID in
        partial.union(CGDisplayBounds(displayID))
    }
}

func setWindowFrameUsingAX(pid: pid_t, windowID: CGWindowID, origin: CGPoint, size: CGSize) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return false
    }
    let window: AXUIElement?
    if let matching = windows.first(where: { axWindowNumber($0) == Int(windowID) }) {
        window = matching
    } else {
        window = windows.count == 1 ? windows[0] : nil
    }
    guard let window else { return false }
    var position = origin
    var targetSize = size
    guard let positionValue = AXValueCreate(.cgPoint, &position),
          let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
        return false
    }
    let move = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    let resize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    return move == .success && resize == .success
}

func axWindowNumber(_ window: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success else {
        return nil
    }
    if let number = value as? NSNumber { return number.intValue }
    if let intValue = value as? Int { return intValue }
    return nil
}

let cgsHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
}()

// macOS 26: CGSWindowByID / CGSResizeWindow 已移除，改用
// CGSGetOnScreenWindowList + CGSGetWindowOwner 查找窗口，
// CGSSetWindowShape 替代 resize。
private let CGSDefaultConnection: (@convention(c) () -> UInt32)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "_CGSDefaultConnection") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> UInt32).self)
}()

private let CGSGetOnScreenWindowList: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UInt32, UnsafeMutablePointer<UInt32>) -> CGError)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSGetOnScreenWindowList") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UInt32, UnsafeMutablePointer<UInt32>) -> CGError).self)
}()

private let CGSGetWindowOwner: (@convention(c) (UInt32, UInt32, UnsafeMutablePointer<pid_t>) -> CGError)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSGetWindowOwner") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, UnsafeMutablePointer<pid_t>) -> CGError).self)
}()

private let CGSMoveWindowFn: (@convention(c) (UInt32, CGPoint) -> Void)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSMoveWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, CGPoint) -> Void).self)
}()

private let CGSNewRegionWithRect: (@convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<OpaquePointer?>) -> CGError)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSNewRegionWithRect") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<OpaquePointer?>) -> CGError).self)
}()

private let CGSSetWindowShape: (@convention(c) (UInt32, UInt32, OpaquePointer?) -> CGError)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSSetWindowShape") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, OpaquePointer?) -> CGError).self)
}()

private let CGSReleaseRegion: (@convention(c) (OpaquePointer?) -> CGError)? = {
    guard let handle = cgsHandle, let sym = dlsym(handle, "CGSReleaseRegion") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (OpaquePointer?) -> CGError).self)
}()

/// 通过枚举 CGS 窗口列表查找 CGWindowID 对应的 CGS 窗口 ID。
/// macOS 26 移除了 CGSWindowByID，只能用遍历方式。
private func findCGSWindowID(_ targetCGWindowID: CGWindowID, ownerPID: pid_t) -> UInt32? {
    guard let conn = CGSDefaultConnection?(),
          let getList = CGSGetOnScreenWindowList,
          let getOwner = CGSGetWindowOwner else { return nil }
    var count: UInt32 = 0
    guard getList(conn, nil, 0, &count) == .success, count > 0 else { return nil }
    var ids = [UInt32](repeating: 0, count: Int(count))
    var outCount: UInt32 = 0
    guard getList(conn, &ids, count, &outCount) == .success else { return nil }
    let validCount = min(Int(outCount), ids.count)
    for i in 0..<validCount {
        var pid: pid_t = 0
        if getOwner(conn, ids[i], &pid) == .success, pid == ownerPID {
            // 用 CGWindowListCopyWindowInfo 交叉验证 CGWindowID
            if let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
                for item in list {
                    guard let num = item[kCGWindowNumber as String] as? CGWindowID, num == targetCGWindowID else { continue }
                    guard let owner = item[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
                    return ids[i]
                }
            }
        }
    }
    return nil
}

func setWindowFrameUsingCGS(windowID: CGWindowID, origin: CGPoint, size: CGSize, ownerPID: pid_t) -> Bool {
    guard let move = CGSMoveWindowFn,
          let setShape = CGSSetWindowShape,
          let newRegion = CGSNewRegionWithRect,
          let releaseRegion = CGSReleaseRegion else {
        return false
    }
    guard let cgsWindow = findCGSWindowID(windowID, ownerPID: ownerPID) else { return false }
    move(cgsWindow, origin)
    var rect = CGRect(origin: .zero, size: size)
    var region: OpaquePointer?
    guard newRegion(&rect, &region) == .success, let region else { return false }
    defer { releaseRegion(region) }
    return setShape(CGSDefaultConnection?() ?? 0, cgsWindow, region) == .success
}

func waitForWindowPlacement(windowID: CGWindowID, origin: CGPoint, width: Int, height: Int) async throws -> CGRect? {
    let start = Date()
    while Date().timeIntervalSince(start) < 4 {
        if let bounds = windowBounds(windowID: windowID) {
            let widthOK = abs(Int(bounds.width.rounded()) - width) <= 4
            let heightOK = abs(Int(bounds.height.rounded()) - height) <= 4
            let xOK = abs(bounds.origin.x - origin.x) <= 8
            let yOK = abs(bounds.origin.y - origin.y) <= 8
            if widthOK, heightOK, (xOK && yOK || visibleRatioOnActiveDisplays(bounds) <= 0.05) {
                return bounds
            }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    return nil
}

func windowBounds(windowID: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for item in list {
        guard let number = item[kCGWindowNumber as String] as? CGWindowID, number == windowID else { continue }
        guard let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }
    return nil
}

func windowIsOutsideActiveDisplays(_ bounds: CGRect) -> Bool {
    let displays = activeDisplayUnionBounds()
    let overlap = bounds.intersection(displays)
    return overlap.isNull || overlap.isEmpty
}

func visibleRatioOnActiveDisplays(_ bounds: CGRect) -> CGFloat {
    let displays = activeDisplayUnionBounds()
    let overlap = bounds.intersection(displays)
    guard !overlap.isNull, !overlap.isEmpty, bounds.width > 0, bounds.height > 0 else {
        return 0
    }
    return (overlap.width * overlap.height) / (bounds.width * bounds.height)
}

func waitForRenderableFrame(windowID: CGWindowID, timeout: TimeInterval) async throws -> CGImage {
    let start = Date()
    var last: CGImage?
    while Date().timeIntervalSince(start) < timeout {
        if let image = await captureWindow(windowID: windowID) {
            last = image
            if Date().timeIntervalSince(start) >= 2, averageLuma(image) > 8 {
                return image
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    if let last { return last }
    throw VerifyError.captureFailed("no frame captured")
}

func captureWindow(windowID: CGWindowID) async -> CGImage? {
    guard let bounds = windowBounds(windowID: windowID) else { return nil }
    let w = max(1, Int(bounds.width.rounded()))
    let h = max(1, Int(bounds.height.rounded()))
    return try? await captureWindowWithScreenCaptureKit(windowID: windowID, width: w, height: h)
}

func waitForRenderableFrameWithScreenCaptureKit(windowID: CGWindowID, width: Int, height: Int, timeout: TimeInterval) async throws -> CGImage {
    let start = Date()
    var last: CGImage?
    while Date().timeIntervalSince(start) < timeout {
        if let image = try? await captureWindowWithScreenCaptureKit(windowID: windowID, width: width, height: height) {
            last = image
            if Date().timeIntervalSince(start) >= 2, averageLuma(image) > 8 {
                return image
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    if let last { return last }
    throw VerifyError.captureFailed("no ScreenCaptureKit frame captured")
}

func captureWindowWithScreenCaptureKit(windowID: CGWindowID, width: Int, height: Int) async throws -> CGImage {
    let content = try await SCShareableContent.current
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw VerifyError.captureFailed("ScreenCaptureKit window not found")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.scalesToFit = true
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    if #available(macOS 14.0, *) {
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .best
    }
    return try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            if let image {
                continuation.resume(returning: image)
            } else {
                continuation.resume(throwing: error ?? VerifyError.captureFailed("ScreenCaptureKit capture returned nil"))
            }
        }
    }
}

func savePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

func averageLuma(_ image: CGImage) -> Double {
    let sample = 32
    let bytesPerPixel = 4
    let bytesPerRow = sample * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: sample * bytesPerRow)
    let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let base = buffer.baseAddress,
              let context = CGContext(
                data: base,
                width: sample,
                height: sample,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return false
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sample, height: sample))
        return true
    }
    guard ok else { return 0 }
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
        let b = Double(pixels[index])
        let g = Double(pixels[index + 1])
        let r = Double(pixels[index + 2])
        total += 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    return total / Double(sample * sample)
}

func encode(windowID: CGWindowID, firstFrame: CGImage, outputURL: URL, width: Int, height: Int, duration: Double, fps: Int) async throws {
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: width * height * 4,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )
    guard writer.canAdd(input) else { throw VerifyError.writerFailed("cannot add writer input") }
    writer.add(input)
    guard writer.startWriting() else {
        throw VerifyError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)

    let frames = max(1, Int(duration * Double(fps)))
    let start = Date()
    for index in 0..<frames {
        let expected = Double(index) / Double(fps)
        let elapsed = Date().timeIntervalSince(start)
        if expected > elapsed {
            try await Task.sleep(nanoseconds: UInt64((expected - elapsed) * 1_000_000_000))
        }
        let image: CGImage
        if index == 0 {
            image = firstFrame
        } else if let sckImage = try? await captureWindowWithScreenCaptureKit(
            windowID: windowID,
            width: width,
            height: height + VerifyPreviewBake.previewWindowTitlebarHeight
        ) {
            image = sckImage
        } else if let cgImage = await captureWindow(windowID: windowID) {
            image = cgImage
        } else {
            image = firstFrame
        }
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
        try append(image: image, adaptor: adaptor, input: input, writer: writer, width: width, height: height, at: time, titleBarHeight: VerifyPreviewBake.previewWindowTitlebarHeight)
    }
    input.markAsFinished()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.finishWriting {
            if writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: VerifyError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed"))
            }
        }
    }
    print("[verify] wrote=\(outputURL.path)")
}

func append(image: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput, writer: AVAssetWriter, width: Int, height: Int, at time: CMTime, titleBarHeight: Int = 31) throws {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw VerifyError.writerFailed("CVPixelBufferCreate failed")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else {
        throw VerifyError.writerFailed("CGContext create failed")
    }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    let crop = contentCropRect(for: image, width: width, height: height, titleBarHeight: titleBarHeight)
    if let cropped = image.cropping(to: crop) {
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var attempts = 0
    while !input.isReadyForMoreMediaData, attempts < 500 {
        usleep(1_000)
        attempts += 1
    }
    guard input.isReadyForMoreMediaData else {
        throw VerifyError.writerFailed("writer input not ready")
    }
    guard adaptor.append(buffer, withPresentationTime: time) else {
        throw VerifyError.writerFailed(writer.error?.localizedDescription ?? "append failed")
    }
}

func inspectVideo(url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
        throw VerifyError.writerFailed("output has no video track")
    }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let size = naturalSize.applying(transform)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    print("[verify] output duration=\(String(format: "%.2f", duration))s size=\(abs(Int(size.width.rounded())))x\(abs(Int(size.height.rounded()))) bytes=\(bytes)")
}

func contentCropRect(for image: CGImage, width: Int, height: Int, titleBarHeight: Int = 31) -> CGRect {
    let capturePointHeight = height + titleBarHeight
    let scale = image.height > capturePointHeight ? Double(image.height) / Double(capturePointHeight) : 1.0
    let titleBarPixels = Int(Double(titleBarHeight) * scale)
    let contentPixelW = Int(Double(width) * scale)
    let contentPixelH = Int(Double(height) * scale)
    let xOffset = max(0, (image.width - contentPixelW) / 2)
    return CGRect(
        x: xOffset,
        y: titleBarPixels,
        width: min(contentPixelW, image.width),
        height: min(contentPixelH, max(1, image.height - titleBarPixels))
    )
}

func rectString(_ rect: CGRect) -> String {
    "\(Int(rect.width))x\(Int(rect.height))@\(Int(rect.origin.x)),\(Int(rect.origin.y))"
}
