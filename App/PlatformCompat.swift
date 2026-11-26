import SwiftUI

#if os(macOS)
import AppKit
typealias BywayImage = NSImage
#else
import UIKit
typealias BywayImage = UIImage
#endif

/// iPhone 和 Mac 共用的键盘与文本输入提示。macOS 没有软键盘，相关修饰符直接忽略。
enum BywayKeyboardKind {
    case url
    case numbersAndPunctuation
}

extension View {
    /// iOS 用行内导航标题，macOS 窗口使用系统标题。
    func bywayInlineTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    func bywayInsetGroupedList() -> some View {
        #if os(iOS)
        return listStyle(.insetGrouped)
        #else
        return listStyle(.inset)
        #endif
    }

    /// 弹出面板在 iPhone 上半屏显示，Mac 上由窗口尺寸决定。
    func bywaySheetDetents() -> some View {
        #if os(iOS)
        return presentationDetents([.medium, .large])
        #else
        return self
        #endif
    }

    func bywayKeyboardType(_ kind: BywayKeyboardKind) -> some View {
        #if os(iOS)
        switch kind {
        case .url: return keyboardType(.URL)
        case .numbersAndPunctuation: return keyboardType(.numbersAndPunctuation)
        }
        #else
        return self
        #endif
    }

    func bywayNoAutocapitalization() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never)
        #else
        return self
        #endif
    }

    func bywayURLContentType() -> some View {
        #if os(iOS)
        return textContentType(.URL)
        #else
        return self
        #endif
    }
}

extension Color {
    /// 旧调用点沿用这三个名字，实际取值统一在 DesignSystem 里定义。
    static var bywayFill: Color { .bywaySubtleFill }

    static var bywayCardBackground: Color { .bywaySurface }

    static var bywaySidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

/// 剪贴板在 iPhone 与 Mac 上使用不同的系统接口。
enum BywayPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(url: URL) {
        copy(url.absoluteString)
    }
}

extension BywayImage {
    static func byway(cgImage: CGImage) -> BywayImage {
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

extension Image {
    init(bywayImage: BywayImage) {
        #if os(macOS)
        self.init(nsImage: bywayImage)
        #else
        self.init(uiImage: bywayImage)
        #endif
    }
}
