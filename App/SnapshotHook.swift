#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// 本地视觉回归用：设置 `BYWAY_SNAPSHOT_DIR` 后，把主界面离屏渲染成 PNG 再退出。
/// ImageRenderer 不依赖屏幕录制权限，也不会留下窗口。只在 Debug 构建里编译。
enum SnapshotHook {
    static var requestedPage: MacPage? {
        ProcessInfo.processInfo.environment["BYWAY_SNAPSHOT_PAGE"].flatMap(MacPage.init(rawValue:))
    }

    static var requestedNodeID: UUID? {
        ProcessInfo.processInfo.environment["BYWAY_SNAPSHOT_NODE"].flatMap(UUID.init(uuidString:))
    }

    @MainActor static func renderOffscreenIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["BYWAY_SNAPSHOT_DIR"] else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let page = requestedPage ?? .nodes
        let scheme: ColorScheme = ProcessInfo.processInfo.environment["BYWAY_SNAPSHOT_DARK"] == "1" ? .dark : .light
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let controller = VPNController()
        let localControl = LANControl()
        Task { @MainActor in
            await controller.load()
            try? await Task.sleep(for: .seconds(1))
            let start = Date()
            let root = MacWorkspace(controller: controller, localControl: localControl,
                                    initialPage: page, initialNodeID: requestedNodeID)
                .frame(width: 1280, height: 820)
                .environment(\.colorScheme, scheme)
                .tint(.bywayBrand)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                  styleMask: [.titled, .resizable, .closable],
                                  backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            window.makeKey()
            window.displayIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(2))
            window.displayIfNeeded()
            hosting.displayIfNeeded()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = scheme == .dark ? "-dark" : ""
            let url = directory.appending(path: "\(page.rawValue)\(suffix).png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1640,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)
            if let rep {
                rep.size = NSSize(width: 1280, height: 820)
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                    FileHandle.standardError.write(Data("snapshot: \(url.path) \(Int(Date().timeIntervalSince(start) * 1000))ms\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("snapshot: no bitmap\n".utf8))
            }
            exit(0)
        }
        RunLoop.main.run()
        return true
    }
}
#endif
