import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 跨平台视觉基线：间距、圆角、字号和语义色都从这里取，页面不再各写一套数字。
enum BywayStyle {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 28
    }

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let window: CGFloat = 12
    }

    enum Typography {
        #if os(macOS)
        static let pageTitle = Font.system(size: 20, weight: .semibold)
        static let sectionTitle = Font.system(size: 11, weight: .semibold)
        static let rowTitle = Font.system(size: 13, weight: .regular)
        static let rowTitleEmphasized = Font.system(size: 13, weight: .medium)
        static let groupTitle = Font.system(size: 11, weight: .semibold)
        static let metadata = Font.system(size: 11, weight: .regular)
        static let metric = Font.system(size: 20, weight: .semibold)
        static let metricSmall = Font.system(size: 15, weight: .semibold)
        static let monospacedValue = Font.system(size: 12, design: .monospaced)
        #else
        static let pageTitle = Font.largeTitle.weight(.bold)
        static let sectionTitle = Font.footnote.weight(.semibold)
        static let rowTitle = Font.body
        static let rowTitleEmphasized = Font.body.weight(.semibold)
        static let groupTitle = Font.footnote.weight(.semibold)
        static let metadata = Font.caption
        static let metric = Font.title2.weight(.semibold)
        static let metricSmall = Font.headline
        static let monospacedValue = Font.system(.footnote, design: .monospaced)
        #endif
    }

    enum Metrics {
        #if os(macOS)
        static let compactRowHeight: CGFloat = 26
        static let tapTarget: CGFloat = 22
        static let cardPadding: CGFloat = 14
        static let pagePadding: CGFloat = 20
        static let contentMaxWidth: CGFloat = 720
        #else
        static let compactRowHeight: CGFloat = 44
        static let tapTarget: CGFloat = 44
        static let cardPadding: CGFloat = 16
        static let pagePadding: CGFloat = 16
        static let contentMaxWidth: CGFloat = 640
        #endif
    }
}

extension Color {
    /// 品牌绿。深色模式下提亮，保证在墨绿侧栏和深色卡片上的对比度。
    static var bywayBrand: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.36, green: 0.78, blue: 0.68, alpha: 1)
                : NSColor(srgbRed: 0.10, green: 0.48, blue: 0.41, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.36, green: 0.78, blue: 0.68, alpha: 1)
                : UIColor(red: 0.10, green: 0.48, blue: 0.41, alpha: 1)
        })
        #endif
    }

    /// 卡片底色：跟随窗口背景稍作区分。
    static var bywaySurface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// 弱填充：用于搜索框、次级按钮与指标块的底纹。
    static var bywaySubtleFill: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }

    /// 卡片描边，深色与浅色都保持一条细线。
    static var bywayHairline: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    static var bywayPositive: Color {
        #if os(macOS)
        Color(nsColor: .systemGreen)
        #else
        Color(uiColor: .systemGreen)
        #endif
    }

    static var bywayWarning: Color {
        #if os(macOS)
        Color(nsColor: .systemOrange)
        #else
        Color(uiColor: .systemOrange)
        #endif
    }
}

// MARK: - 复用组件

/// 原生设置风格的卡片：圆角、描边、统一内边距。
struct BywayCard<Content: View>: View {
    var padding = BywayStyle.Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bywaySurface, in: RoundedRectangle(cornerRadius: BywayStyle.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BywayStyle.Radius.card, style: .continuous)
                    .strokeBorder(Color.bywayHairline.opacity(0.6), lineWidth: 0.5)
            }
    }
}

/// 指标块：一个标题加一个数值，用于延迟、出口、流量。
struct BywayMetricTile: View {
    let title: String
    let value: String
    var symbol: String?
    var emphasized = false
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.xs) {
            HStack(spacing: BywayStyle.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(BywayStyle.Typography.metadata)
            .foregroundStyle(.secondary)

            Text(value)
                .font(emphasized ? BywayStyle.Typography.metric : BywayStyle.Typography.metricSmall)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let footnote {
                Text(footnote)
                    .font(BywayStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, BywayStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 连接状态圆点，颜色跟随连接状态。
struct BywayStatusDot: View {
    let connected: Bool
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(connected ? Color.bywayPositive : Color.secondary.opacity(0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 分区小标题：设置页与详情页共用。
struct BywaySectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(BywayStyle.Typography.sectionTitle)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.bottom, BywayStyle.Spacing.xxs)
    }
}


#if os(macOS)
/// 自绘的主要按钮：不依赖系统 accent，离线渲染和深色模式都稳定显示品牌绿。
struct MacProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .bywayBrand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.82) : .white)
            .padding(.horizontal, BywayStyle.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(tint.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: BywayStyle.Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// 行内小动作按钮，覆盖 Form 里那颗灰色圆角按钮的观感。
struct MacInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.bywayBrand.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}
#endif

extension View {
    /// macOS 上把表单切成系统设置那种分组样式；iPhone 继续用 inset grouped。
    func bywaySettingsForm() -> some View {
        #if os(macOS)
        return formStyle(.grouped)
        #else
        return bywayInsetGroupedList()
        #endif
    }

    /// 设置页内容宽度收窄并对齐，避免在宽窗口里被拉成一长条。
    func bywayPageWidth() -> some View {
        frame(maxWidth: BywayStyle.Metrics.contentMaxWidth)
    }
}
