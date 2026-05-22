import Foundation
import CryptoKit

// MARK: - 通过汇编 .incbin 嵌入在 WaifuX 主二进制中的 ZIP 材质包
//（运行时解压后传给 wallpaper-wgpu --assets）

@_silgen_name("get_zip_data_ptr")
func getZipDataPtr() -> UnsafePointer<UInt8>

@_silgen_name("get_zip_data_size")
func getZipDataSize() -> UInt

enum WallpaperEngineEmbeddedAssets {
    private static let prepLock = NSLock()
    private static nonisolated(unsafe) var cachedAssetsRoot: String?

    /// 供渲染器使用的 **assets 根目录**（内含 materials、shaders 等）；首次调用时从 Mach-O 嵌入段解压。
    static func materializedAssetsRootIfPresent() -> String? {
        prepLock.lock()
        defer { prepLock.unlock() }

        if let cached = cachedAssetsRoot,
           FileManager.default.fileExists(atPath: cached) {
            print("[WallpaperEngineEmbeddedAssets] 使用缓存的 assets: \(cached)")
            return cached
        }

        guard let zipData = readEmbeddedZip() else {
            print("[WallpaperEngineEmbeddedAssets] ⚠️ 无内嵌 ZIP 数据（readEmbeddedZip 返回 nil）")
            return nil
        }
        print("[WallpaperEngineEmbeddedAssets] 内嵌 ZIP 数据大小: \(zipData.count) bytes")

        let digest = SHA256.hash(data: zipData)
        let cacheKey = digest.map { String(format: "%02x", $0) }.joined()

        guard let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            print("[WallpaperEngineEmbeddedAssets] ❌ 无法获取 cachesDirectory")
            return nil
        }
        let extractRoot = cacheBase
            .appendingPathComponent("com.waifux.wallpaperengine", isDirectory: true)
            .appendingPathComponent("embedded-assets", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)

        let assetsDir = extractRoot.appendingPathComponent("assets", isDirectory: true)
        let readyURL = extractRoot.appendingPathComponent(".extracted", isDirectory: false)

        if FileManager.default.fileExists(atPath: readyURL.path),
           FileManager.default.fileExists(atPath: assetsDir.path) {
            print("[WallpaperEngineEmbeddedAssets] 使用已解压的 assets: \(assetsDir.path)")
            cachedAssetsRoot = assetsDir.path
            return assetsDir.path
        }

        let fm = FileManager.default
        try? fm.removeItem(at: extractRoot)
        do {
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        } catch {
            print("[WallpaperEngineEmbeddedAssets] ❌ 创建解压目录失败: \(error.localizedDescription)")
            return nil
        }

        let zipURL = extractRoot.appendingPathComponent("_payload.zip")
        do {
            try zipData.write(to: zipURL)
        } catch {
            print("[WallpaperEngineEmbeddedAssets] ❌ 写入 ZIP 文件失败: \(error.localizedDescription)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", zipURL.path, "-d", extractRoot.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            print("[WallpaperEngineEmbeddedAssets] ❌ 启动 unzip 失败: \(error.localizedDescription)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        if proc.terminationStatus != 0 {
            print("[WallpaperEngineEmbeddedAssets] ❌ unzip 退出码 \(proc.terminationStatus)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? fm.removeItem(at: zipURL)

        guard proc.terminationStatus == 0,
              fm.fileExists(atPath: assetsDir.path) else {
            print("[WallpaperEngineEmbeddedAssets] ❌ unzip 完成但 assets 目录不存在: \(assetsDir.path)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? "ok".write(to: readyURL, atomically: true, encoding: .utf8)
        cachedAssetsRoot = assetsDir.path
        print("[WallpaperEngineEmbeddedAssets] ✅ assets 解压成功: \(assetsDir.path)")
        return assetsDir.path
    }

    private static func readEmbeddedZip() -> Data? {
        let ptr = getZipDataPtr()
        let size = getZipDataSize()
        guard size > 100 else {
            print("[WallpaperEngineEmbeddedAssets] 内嵌 ZIP 数据过小 (\(size) bytes)，跳过")
            return nil
        }
        let data = Data(bytes: ptr, count: Int(size))
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) else {
            print("[WallpaperEngineEmbeddedAssets] 内嵌数据不是有效的 ZIP 格式（缺少 PK 魔术头）")
            return nil
        }
        return data
    }
}
