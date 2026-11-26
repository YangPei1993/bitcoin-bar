import AppKit
import Foundation
import Security
import ServiceManagement
import SwiftUI

// MARK: - 偏好枚举

nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    @MainActor
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

nonisolated enum PriceColorStyle: String, CaseIterable, Identifiable, Sendable {
    case greenUp
    case redUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .greenUp: return "绿涨红跌（国际）"
        case .redUp: return "红涨绿跌（中式）"
        }
    }

    var shortLabel: String {
        switch self {
        case .greenUp: return "绿涨红跌"
        case .redUp: return "红涨绿跌"
        }
    }
}

nonisolated enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case full
    case symbolAndPrice
    case priceOnly
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "币种 + 价格 + 涨跌幅"
        case .symbolAndPrice: return "币种 + 价格"
        case .priceOnly: return "仅显示价格"
        case .iconOnly: return "仅显示图标"
        }
    }
}

// MARK: - 钥匙串存取（保护 AI API Key）

nonisolated enum KeychainStore {
    private static let service = "com.paul.bitcoin-bar.secrets"

    static func save(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 应用全局设置

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let appearance = "AppSettings.appearance"
        static let priceColorStyle = "AppSettings.priceColorStyle"
        static let showDockIcon = "AppSettings.showDockIcon"
        static let menuBarAsset = "AppSettings.menuBarAsset"
        static let menuBarDisplayMode = "AppSettings.menuBarDisplayMode"
        static let menuBarCompactPrice = "AppSettings.menuBarCompactPrice"
        static let menuBarColoredChange = "AppSettings.menuBarColoredChange"
        static let floatingWindowOpacity = "AppSettings.floatingWindowOpacity.v2"
        static let floatingShowsChange = "AppSettings.floatingShowsChange"
        static let floatingShowsBalance = "AppSettings.floatingShowsBalance"
        static let floatingClickThrough = "AppSettings.floatingClickThrough"
        static let floatingVisibleOnLaunch = "AppSettings.floatingVisibleOnLaunch"
        static let floatingFrame = "AppSettings.floatingFrame"
        static let aiProvider = "AppSettings.ai.provider"
        static let aiBaseURL = "AppSettings.ai.baseURL"
        static let aiModel = "AppSettings.ai.model"
        static let aiKeyAccount = "ai.apiKey"
    }

    static let floatingOpacityRange: ClosedRange<Double> = 0.22...0.96

    var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    var priceColorStyle: PriceColorStyle {
        didSet {
            UserDefaults.standard.set(priceColorStyle.rawValue, forKey: Keys.priceColorStyle)
            onMenuBarStyleChanged?()
        }
    }

    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon)
            applyActivationPolicy()
        }
    }

    var menuBarAsset: CryptoAsset {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarAsset) {
                UserDefaults.standard.set(data, forKey: Keys.menuBarAsset)
            }
            onMenuBarAssetChanged?(menuBarAsset)
        }
    }

    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: Keys.menuBarDisplayMode)
            onMenuBarStyleChanged?()
        }
    }

    var menuBarCompactPrice: Bool {
        didSet {
            UserDefaults.standard.set(menuBarCompactPrice, forKey: Keys.menuBarCompactPrice)
            onMenuBarStyleChanged?()
        }
    }

    var menuBarColoredChange: Bool {
        didSet {
            UserDefaults.standard.set(menuBarColoredChange, forKey: Keys.menuBarColoredChange)
            onMenuBarStyleChanged?()
        }
    }

    var floatingWindowOpacity: Double {
        didSet {
            let clamped = min(max(floatingWindowOpacity, Self.floatingOpacityRange.lowerBound), Self.floatingOpacityRange.upperBound)
            if clamped != floatingWindowOpacity {
                floatingWindowOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.floatingWindowOpacity)
        }
    }

    var floatingShowsChange: Bool {
        didSet {
            UserDefaults.standard.set(floatingShowsChange, forKey: Keys.floatingShowsChange)
        }
    }

    var floatingShowsBalance: Bool {
        didSet {
            UserDefaults.standard.set(floatingShowsBalance, forKey: Keys.floatingShowsBalance)
            onFloatingShowsBalanceChanged?(floatingShowsBalance)
        }
    }

    var floatingClickThrough: Bool {
        didSet {
            UserDefaults.standard.set(floatingClickThrough, forKey: Keys.floatingClickThrough)
            onFloatingClickThroughChanged?(floatingClickThrough)
        }
    }

    var floatingVisibleOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(floatingVisibleOnLaunch, forKey: Keys.floatingVisibleOnLaunch)
        }
    }

    var aiConfiguration: AIProviderConfiguration {
        didSet {
            UserDefaults.standard.set(aiConfiguration.provider.rawValue, forKey: Keys.aiProvider)
            UserDefaults.standard.set(aiConfiguration.baseURL, forKey: Keys.aiBaseURL)
            UserDefaults.standard.set(aiConfiguration.model, forKey: Keys.aiModel)
            KeychainStore.save(aiConfiguration.apiKey, account: Keys.aiKeyAccount)
        }
    }

    private(set) var launchAtLoginError: String?

    @ObservationIgnored var onMenuBarAssetChanged: ((CryptoAsset) -> Void)?
    @ObservationIgnored var onMenuBarStyleChanged: (() -> Void)?
    @ObservationIgnored var onFloatingClickThroughChanged: ((Bool) -> Void)?
    @ObservationIgnored var onFloatingShowsBalanceChanged: ((Bool) -> Void)?

    init() {
        let defaults = UserDefaults.standard

        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        self.priceColorStyle = PriceColorStyle(rawValue: defaults.string(forKey: Keys.priceColorStyle) ?? "") ?? .greenUp
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false

        if let data = defaults.data(forKey: Keys.menuBarAsset),
           let decoded = try? JSONDecoder().decode(CryptoAsset.self, from: data) {
            self.menuBarAsset = decoded
        } else {
            self.menuBarAsset = CryptoAsset(id: "BTC-USDT", symbol: "BTC", name: "Bitcoin", instrumentKind: .spot)
        }

        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: defaults.string(forKey: Keys.menuBarDisplayMode) ?? "") ?? .full
        self.menuBarCompactPrice = defaults.object(forKey: Keys.menuBarCompactPrice) as? Bool ?? false
        self.menuBarColoredChange = defaults.object(forKey: Keys.menuBarColoredChange) as? Bool ?? true

        if let savedOpacity = defaults.object(forKey: Keys.floatingWindowOpacity) as? Double {
            self.floatingWindowOpacity = min(max(savedOpacity, Self.floatingOpacityRange.lowerBound), Self.floatingOpacityRange.upperBound)
        } else {
            self.floatingWindowOpacity = 0.82
        }

        self.floatingShowsChange = defaults.object(forKey: Keys.floatingShowsChange) as? Bool ?? true
        self.floatingShowsBalance = defaults.object(forKey: Keys.floatingShowsBalance) as? Bool ?? true
        self.floatingClickThrough = false
        self.floatingVisibleOnLaunch = defaults.object(forKey: Keys.floatingVisibleOnLaunch) as? Bool ?? false

        let provider = AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .openAI
        let baseURL = defaults.string(forKey: Keys.aiBaseURL) ?? provider.defaultBaseURL
        let model = defaults.string(forKey: Keys.aiModel) ?? provider.defaultModel
        let apiKey = KeychainStore.load(account: Keys.aiKeyAccount)
        self.aiConfiguration = AIProviderConfiguration(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model
        )
    }

    // MARK: 涨跌颜色语义

    var upColor: Color {
        priceColorStyle == .greenUp ? MarketColors.green : MarketColors.red
    }

    var downColor: Color {
        priceColorStyle == .greenUp ? MarketColors.red : MarketColors.green
    }

    var upNSColor: NSColor {
        priceColorStyle == .greenUp
            ? NSColor(red: 0.13, green: 0.74, blue: 0.45, alpha: 1)
            : NSColor(red: 0.93, green: 0.30, blue: 0.34, alpha: 1)
    }

    var downNSColor: NSColor {
        priceColorStyle == .greenUp
            ? NSColor(red: 0.93, green: 0.30, blue: 0.34, alpha: 1)
            : NSColor(red: 0.13, green: 0.74, blue: 0.45, alpha: 1)
    }

    func changeColor(for value: Double) -> Color {
        if value > 0 { return upColor }
        if value < 0 { return downColor }
        return MarketColors.neutral
    }

    func candleColor(for point: KlinePoint) -> Color {
        point.close >= point.open ? upColor : downColor
    }

    // MARK: 系统集成

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    func applyActivationPolicy() {
        guard let app = NSApp else { return }
        let target: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if app.activationPolicy() != target {
            app.setActivationPolicy(target)
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = "设置开机自启失败：请先将应用移至“应用程序”文件夹后重试。"
        }
    }

    // MARK: 悬浮窗位置记忆

    func saveFloatingFrame(_ frame: NSRect) {
        let string = NSStringFromRect(frame)
        UserDefaults.standard.set(string, forKey: Keys.floatingFrame)
    }

    func loadFloatingFrame() -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: Keys.floatingFrame) else { return nil }
        let rect = NSRectFromString(string)
        guard rect.width >= 200, rect.height >= 100 else { return nil }
        return rect
    }
}
