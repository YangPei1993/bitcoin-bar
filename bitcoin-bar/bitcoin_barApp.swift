import AppKit
import SwiftUI
import UserNotifications

// MARK: - 应用主入口

@main
@MainActor
final class bitcoin_barApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var appDelegate: bitcoin_barApp?

    private let settings = AppSettings()
    private let hub = MarketQuoteHub()
    private let watchlist = WatchlistStore()
    private let dispatcher = NotificationDispatcher()
    private lazy var tickerStore = CryptoTickerStore(hub: hub)
    private lazy var alertStore = PriceAlertStore(hub: hub, dispatcher: dispatcher)
    private lazy var portfolioStore = PortfolioStore(dispatcher: dispatcher)
    private lazy var riskEngine = RiskMonitorEngine(
        hub: hub,
        watchlist: watchlist,
        portfolio: portfolioStore,
        dispatcher: dispatcher
    )
    private let aiCache = AIAnalysisCache()
    private let navigation = PanelNavigationState()

    private let floatingWindowController = FloatingTickerWindowController()
    private let marketPanelController = MarketPanelController()
    private let settingsWindowController = SettingsWindowController()
    private var statusBarController: StatusBarController?
    private var keyMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = bitcoin_barApp()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        settings.applyActivationPolicy()
        settings.applyAppearance()
        setupCallbacks()
        setupNotificationCenter()
        setupKeyboardShortcuts()

        // 注册菜单栏币种需求并启动统一行情中枢
        hub.setDemand([settings.menuBarAsset], for: "menubar")
        hub.start()

        statusBarController = StatusBarController(
            hub: hub,
            settings: settings,
            watchlist: watchlist,
            isPanelVisible: { [weak self] in self?.marketPanelController.isVisible ?? false },
            isFloatingVisible: { [weak self] in self?.floatingWindowController.isVisible ?? false },
            onTogglePanel: { [weak self] anchorRect in
                self?.toggleMarketPanel(from: anchorRect)
            },
            onOpenPanel: { [weak self] anchorRect in
                self?.openMarketPanel(detailAsset: nil, from: anchorRect)
            },
            onToggleFloating: { [weak self] in
                self?.toggleFloatingWindow()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings(tab: .general)
            }
        )

        if settings.floatingVisibleOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.openFloatingWindow()
            }
        } else {
            // 首次启动时自动展开主面板，避免纯菜单栏模式用户误以为应用未启动
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.openMarketPanel(detailAsset: nil, from: self?.statusBarController?.buttonScreenFrame)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        portfolioStore.stopAllTasks()
        hub.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMarketPanel(detailAsset: nil, from: statusBarController?.buttonScreenFrame)
        return true
    }

    // MARK: 回调绑定

    private func setupCallbacks() {
        settings.onMenuBarAssetChanged = { [weak self] asset in
            guard let self else { return }
            self.hub.setDemand([asset], for: "menubar")
            self.statusBarController?.refreshDisplay()
        }

        settings.onMenuBarStyleChanged = { [weak self] in
            self?.statusBarController?.refreshDisplay()
        }

        settings.onFloatingClickThroughChanged = { [weak self] enabled in
            self?.floatingWindowController.updateClickThrough(enabled)
        }

        floatingWindowController.onVisibilityChanged = { [weak self] visible in
            self?.navigation.isFloatingVisible = visible
        }

        watchlist.onFavoritesChanged = { [weak self] _ in
            self?.floatingWindowController.syncWatchlistDemand()
            self?.riskEngine.syncVolatilityDemand()
        }

        dispatcher.onDisplayToast = { [weak self] payload in
            self?.navigation.showToast("\(payload.severity.emoji) \(payload.title)")
        }

        // 将主动风控引擎与账户轮询联动起来
        portfolioStore.onSnapshotsUpdated = { [weak self] in
            self?.riskEngine.evaluatePortfolioRisks()
            self?.riskEngine.syncVolatilityDemand()
        }
        portfolioStore.setExternalRiskMonitoringEnabled(riskEngine.config.hasPortfolioRiskRuleEnabled)
        riskEngine.onConfigChanged = { [weak self] config in
            self?.portfolioStore.setExternalRiskMonitoringEnabled(config.hasPortfolioRiskRuleEnabled)
        }
    }

    // MARK: 系统菜单（支持 ⌘C/⌘V/⌘X/⌘A/⌘Z 与常用快捷键）

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "bitcoin-bar")
        let settingsItem = NSMenuItem(title: "设置...", action: #selector(handleOpenSettingsShortcut), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 bitcoin-bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k":
                    if self.marketPanelController.isVisible {
                        self.navigation.searchFocusToken &+= 1
                        return nil
                    }
                case ",":
                    self.openSettings(tab: .general)
                    return nil
                case "r":
                    if self.marketPanelController.isVisible {
                        if self.navigation.activeSection == .portfolio {
                            Task { await self.portfolioStore.refreshAll() }
                        } else {
                            Task { await self.hub.refreshNow() }
                        }
                        return nil
                    }
                default:
                    break
                }
            } else if event.keyCode == 53 { // Escape
                if self.marketPanelController.isKeyWindow {
                    if self.navigation.detailAsset != nil {
                        self.navigation.detailAsset = nil
                        return nil
                    } else if self.navigation.isPinned == false {
                        self.marketPanelController.hide()
                        return nil
                    }
                }
            }

            return event
        }
    }

    @objc private func handleOpenSettingsShortcut() {
        openSettings(tab: .general)
    }

    // MARK: 系统通知代理

    private func setupNotificationCenter() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let openTab = userInfo["openTab"] as? String
        let assetID = userInfo["assetID"] as? String
        await MainActor.run { [weak self] in
            guard let self else { return }
            if openTab == "portfolio" {
                self.navigation.detailAsset = nil
                self.navigation.activeSection = .portfolio
                self.openMarketPanel(detailAsset: nil, from: self.statusBarController?.buttonScreenFrame)
                return
            }
            let targetAsset = assetID.flatMap { id in
                self.alertStore.alerts.first(where: { $0.asset.id == id })?.asset
                    ?? self.watchlist.favoriteAssets.first(where: { $0.id == id })
                    ?? self.tickerStore.featuredSpotAssets.first(where: { $0.id == id })
            }
            self.openMarketPanel(detailAsset: targetAsset, from: self.statusBarController?.buttonScreenFrame)
        }
    }

    // MARK: 窗口调度

    private func toggleMarketPanel(from anchorRect: NSRect?) {
        if marketPanelController.isVisible {
            marketPanelController.hide()
        } else if marketPanelController.wasJustAutoHidden {
            // 避免点击状态栏图标时先触发失焦隐藏、随即又重新弹开的闪烁
            return
        } else {
            openMarketPanel(detailAsset: nil, from: anchorRect)
        }
    }

    private func openMarketPanel(detailAsset: CryptoAsset?, from anchorRect: NSRect?) {
        if let detailAsset {
            navigation.detailAsset = detailAsset
        }

        let contentView = ContentView(
            hub: hub,
            tickerStore: tickerStore,
            watchlist: watchlist,
            alertStore: alertStore,
            portfolioStore: portfolioStore,
            riskEngine: riskEngine,
            settings: settings,
            aiCache: aiCache,
            navigation: navigation,
            toggleFloatingWindow: { [weak self] in self?.toggleFloatingWindow() },
            openSettings: { [weak self] tab in self?.openSettings(tab: tab) },
            onPinChanged: { [weak self] pinned in self?.marketPanelController.isPinned = pinned },
            onDismissPanel: { [weak self] in self?.marketPanelController.hide() }
        )

        marketPanelController.show(rootView: contentView, anchorRect: anchorRect)
    }

    private func openFloatingWindow() {
        floatingWindowController.open(
            hub: hub,
            watchlist: watchlist,
            settings: settings
        ) { [weak self] asset in
            self?.openMarketPanel(detailAsset: asset, from: self?.statusBarController?.buttonScreenFrame)
        }
    }

    private func toggleFloatingWindow() {
        floatingWindowController.toggle(
            hub: hub,
            watchlist: watchlist,
            settings: settings
        ) { [weak self] asset in
            self?.openMarketPanel(detailAsset: asset, from: self?.statusBarController?.buttonScreenFrame)
        }
    }

    private func openSettings(tab: SettingsTab) {
        let view = SettingsView(
            settings: settings,
            hub: hub,
            watchlist: watchlist,
            alertStore: alertStore,
            portfolioStore: portfolioStore,
            riskEngine: riskEngine,
            dispatcher: dispatcher,
            tickerStore: tickerStore,
            initialTab: tab,
            toggleFloatingWindow: { [weak self] in self?.toggleFloatingWindow() }
        )
        settingsWindowController.show(rootView: view)
    }
}

// MARK: - 主行情弹出面板控制器

@MainActor
final class MarketPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ContentView>?
    private var lastAutoHideTime: Date?

    var isPinned = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var isKeyWindow: Bool {
        panel?.isKeyWindow ?? false
    }

    var wasJustAutoHidden: Bool {
        guard let lastAutoHideTime else { return false }
        return Date().timeIntervalSince(lastAutoHideTime) < 0.25
    }

    func show(rootView: ContentView, anchorRect: NSRect?) {
        if let panel {
            hostingController?.rootView = rootView
            if panel.isVisible == false {
                position(panel, relativeTo: anchorRect)
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 424, height: 620),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 400, height: 540)
        panel.maxSize = NSSize(width: 640, height: 860)

        // 隐藏原生交通灯，保持菜单栏弹出卡片的清爽观感
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.panel = panel
        self.hostingController = hostingController

        position(panel, relativeTo: anchorRect)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isPinned == false,
              let panel,
              panel.attachedSheet == nil else { return }
        lastAutoHideTime = Date()
        panel.orderOut(nil)
    }

    private func position(_ panel: NSPanel, relativeTo anchorRect: NSRect?) {
        let size = panel.frame.size
        if let anchorRect {
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let rawX = anchorRect.midX - size.width / 2
                let x = min(max(rawX, visible.minX + 8), visible.maxX - size.width - 8)
                let y = min(max(anchorRect.minY - size.height - 6, visible.minY + 8), visible.maxY - size.height - 4)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
        panel.center()
    }
}

// MARK: - 独立设置窗口控制器

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    func show(rootView: SettingsView) {
        if let window {
            hostingController?.rootView = rootView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        self.hostingController = hostingController

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 菜单栏状态项控制器

@MainActor
final class StatusBarController: NSObject {
    private let hub: MarketQuoteHub
    private let settings: AppSettings
    private let watchlist: WatchlistStore
    private let isPanelVisible: () -> Bool
    private let isFloatingVisible: () -> Bool
    private let onTogglePanel: (NSRect?) -> Void
    private let onOpenPanel: (NSRect?) -> Void
    private let onToggleFloating: () -> Void
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private var lastRenderedSignature = ""

    init(
        hub: MarketQuoteHub,
        settings: AppSettings,
        watchlist: WatchlistStore,
        isPanelVisible: @escaping () -> Bool,
        isFloatingVisible: @escaping () -> Bool,
        onTogglePanel: @escaping (NSRect?) -> Void,
        onOpenPanel: @escaping (NSRect?) -> Void,
        onToggleFloating: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.hub = hub
        self.settings = settings
        self.watchlist = watchlist
        self.isPanelVisible = isPanelVisible
        self.isFloatingVisible = isFloatingVisible
        self.onTogglePanel = onTogglePanel
        self.onOpenPanel = onOpenPanel
        self.onToggleFloating = onToggleFloating
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        configureButton()
        refreshDisplay()

        // 仅在菜单栏绑定币种报价真正更新时重绘，避免每秒空转定时器
        hub.addListener { [weak self] assetID, _ in
            guard let self, assetID == self.settings.menuBarAsset.id else { return }
            self.refreshDisplay()
        }
    }

    var buttonScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func refreshDisplay() {
        guard let button = statusItem.button else { return }

        let asset = settings.menuBarAsset
        let quote = hub.quotes[asset.id]
        let mode = settings.menuBarDisplayMode
        let compact = settings.menuBarCompactPrice
        let colored = settings.menuBarColoredChange

        let signature = "\(asset.id)|\(mode.rawValue)|\(compact)|\(colored)|\(settings.priceColorStyle.rawValue)|\(quote?.price ?? -1)|\(quote?.changePercentage24h ?? 0)"
        guard signature != lastRenderedSignature else { return }
        lastRenderedSignature = signature

        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let title = NSMutableAttributedString()

        switch mode {
        case .iconOnly:
            title.append(NSAttributedString(string: "₿", attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .bold)]))
        case .priceOnly:
            let priceText = quote.map { MarketFormatter.menuBarPrice($0.price, compact: compact) } ?? "--"
            title.append(NSAttributedString(string: priceText, attributes: [.font: baseFont]))
        case .symbolAndPrice:
            let priceText = quote.map { MarketFormatter.menuBarPrice($0.price, compact: compact) } ?? "--"
            title.append(NSAttributedString(string: "\(asset.symbol) \(priceText)", attributes: [.font: baseFont]))
        case .full:
            if let quote {
                let priceText = MarketFormatter.menuBarPrice(quote.price, compact: compact)
                let changeText = " \(MarketFormatter.changePercent(quote.changePercentage24h, digits: 1))"
                title.append(NSAttributedString(string: "\(asset.symbol) \(priceText)", attributes: [.font: baseFont]))

                var changeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                ]
                if colored {
                    changeAttrs[.foregroundColor] = quote.changePercentage24h >= 0 ? settings.upNSColor : settings.downNSColor
                }
                title.append(NSAttributedString(string: changeText, attributes: changeAttrs))
            } else {
                title.append(NSAttributedString(string: "\(asset.symbol) --", attributes: [.font: baseFont]))
            }
        }

        button.image = nil
        button.attributedTitle = title
        if let quote {
            button.toolTip = "\(asset.pairLabel) \(MarketFormatter.price(quote.price)) (\(MarketFormatter.changePercent(quote.changePercentage24h)))"
        } else {
            button.toolTip = "bitcoin-bar · 点击打开实时行情"
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: button)
        } else {
            onTogglePanel(buttonScreenFrame)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let panelItem = NSMenuItem(
            title: isPanelVisible() ? "隐藏行情面板" : "打开行情面板",
            action: #selector(menuTogglePanel),
            keyEquivalent: ""
        )
        panelItem.target = self
        menu.addItem(panelItem)

        let floatingItem = NSMenuItem(
            title: isFloatingVisible() ? "隐藏桌面悬浮窗" : "显示桌面悬浮窗",
            action: #selector(menuToggleFloating),
            keyEquivalent: ""
        )
        floatingItem.target = self
        menu.addItem(floatingItem)

        if settings.floatingClickThrough {
            let unlockItem = NSMenuItem(
                title: "关闭悬浮窗鼠标穿透",
                action: #selector(menuDisableClickThrough),
                keyEquivalent: ""
            )
            unlockItem.target = self
            menu.addItem(unlockItem)
        }

        menu.addItem(.separator())

        // 快速切换菜单栏常驻币种
        let switchMenu = NSMenu()
        let candidates = watchlist.floatingAssets.prefix(8)
        for asset in candidates {
            let item = NSMenuItem(title: asset.pairLabel, action: #selector(menuSelectMenuBarAsset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = asset
            if asset == settings.menuBarAsset {
                item.state = .on
            }
            switchMenu.addItem(item)
        }
        let switchRoot = NSMenuItem(title: "菜单栏显示币种", action: nil, keyEquivalent: "")
        switchRoot.submenu = switchMenu
        menu.addItem(switchRoot)

        let refreshItem = NSMenuItem(title: "立即刷新行情", action: #selector(menuRefreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出 bitcoin-bar", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuTogglePanel() {
        onTogglePanel(buttonScreenFrame)
    }

    @objc private func menuToggleFloating() {
        onToggleFloating()
    }

    @objc private func menuDisableClickThrough() {
        settings.floatingClickThrough = false
    }

    @objc private func menuSelectMenuBarAsset(_ sender: NSMenuItem) {
        if let asset = sender.representedObject as? CryptoAsset {
            settings.menuBarAsset = asset
        }
    }

    @objc private func menuRefreshNow() {
        hub.reconnectNow()
    }

    @objc private func menuOpenSettings() {
        onOpenSettings()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
