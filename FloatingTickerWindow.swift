import AppKit
import SwiftUI

// MARK: - 桌面悬浮窗控制器

@MainActor
final class FloatingTickerWindowController: NSObject, NSWindowDelegate {
    private var panel: FloatingTickerPanel?
    private var hostingController: NSHostingController<FloatingTickerView>?
    private var settings: AppSettings?
    private var hub: MarketQuoteHub?
    private var watchlist: WatchlistStore?
    private var portfolio: PortfolioStore?
    private var openAssetDetail: ((CryptoAsset?) -> Void)?
    private var openPortfolio: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle(
        hub: MarketQuoteHub,
        watchlist: WatchlistStore,
        portfolio: PortfolioStore,
        settings: AppSettings,
        openAssetDetail: @escaping (CryptoAsset?) -> Void,
        openPortfolio: @escaping () -> Void
    ) {
        if let panel, panel.isVisible {
            close()
        } else {
            open(
                hub: hub,
                watchlist: watchlist,
                portfolio: portfolio,
                settings: settings,
                openAssetDetail: openAssetDetail,
                openPortfolio: openPortfolio
            )
        }
    }

    func open(
        hub: MarketQuoteHub,
        watchlist: WatchlistStore,
        portfolio: PortfolioStore,
        settings: AppSettings,
        openAssetDetail: @escaping (CryptoAsset?) -> Void,
        openPortfolio: @escaping () -> Void
    ) {
        self.hub = hub
        self.watchlist = watchlist
        self.portfolio = portfolio
        self.settings = settings
        self.openAssetDetail = openAssetDetail
        self.openPortfolio = openPortfolio

        hub.setDemand(watchlist.floatingAssets, for: "floating")
        portfolio.setFloatingBalanceActive(settings.floatingShowsBalance)

        if let panel {
            panel.ignoresMouseEvents = settings.floatingClickThrough
            panel.orderFrontRegardless()
            onVisibilityChanged?(true)
            return
        }

        let rootView = FloatingTickerView(
            hub: hub,
            watchlist: watchlist,
            portfolio: portfolio,
            settings: settings,
            onSelectAsset: { asset in openAssetDetail(asset) },
            onOpenMainPanel: { openAssetDetail(nil) },
            onOpenPortfolio: openPortfolio,
            onClose: { [weak self] in self?.close() }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let idealHeight = idealWindowHeight(rowCount: watchlist.floatingAssets.count)
        let initialRect = resolvedInitialFrame(defaultHeight: idealHeight, settings: settings)

        let panel = FloatingTickerPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: 214, height: 112)
        panel.maxSize = NSSize(width: 380, height: 520)
        panel.ignoresMouseEvents = settings.floatingClickThrough
        panel.contextMenuBuilder = { [weak self] in
            self?.buildContextMenu()
        }

        self.panel = panel
        self.hostingController = hostingController

        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
    }

    func close() {
        if let frame = panel?.frame {
            settings?.saveFloatingFrame(frame)
        }
        panel?.orderOut(nil)
        hub?.setDemand([], for: "floating")
        portfolio?.setFloatingBalanceActive(false)
        onVisibilityChanged?(false)
    }

    func updateClickThrough(_ enabled: Bool) {
        panel?.ignoresMouseEvents = enabled
    }

    func syncBalancePreference() {
        guard isVisible, let settings else { return }
        portfolio?.setFloatingBalanceActive(settings.floatingShowsBalance)
    }

    func syncWatchlistDemand() {
        guard isVisible, let watchlist else { return }
        hub?.setDemand(watchlist.floatingAssets, for: "floating")
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if let frame = panel?.frame {
            settings?.saveFloatingFrame(frame)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let frame = panel?.frame {
            settings?.saveFloatingFrame(frame)
        }
    }

    // MARK: 右键上下文菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开行情面板", action: #selector(handleOpenMainPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let changeItem = NSMenuItem(title: "显示 24h 涨跌幅", action: #selector(handleToggleChange), keyEquivalent: "")
        changeItem.target = self
        changeItem.state = (settings?.floatingShowsChange ?? true) ? .on : .off
        menu.addItem(changeItem)

        let balanceItem = NSMenuItem(title: "顶部栏显示账户余额", action: #selector(handleToggleBalance), keyEquivalent: "")
        balanceItem.target = self
        balanceItem.state = (settings?.floatingShowsBalance ?? true) ? .on : .off
        menu.addItem(balanceItem)

        let opacityMenu = NSMenu()
        let presets: [(String, Double)] = [
            ("极致轻透（35%）", 0.35),
            ("半透明（60%）", 0.60),
            ("标准质感（82%）", 0.82),
            ("深邃沉浸（95%）", 0.95)
        ]
        for (title, value) in presets {
            let item = NSMenuItem(title: title, action: #selector(handleOpacityPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            if let current = settings?.floatingWindowOpacity, abs(current - value) < 0.06 {
                item.state = .on
            }
            opacityMenu.addItem(item)
        }
        let opacityRoot = NSMenuItem(title: "背景透明度", action: nil, keyEquivalent: "")
        opacityRoot.submenu = opacityMenu
        menu.addItem(opacityRoot)

        let passThroughItem = NSMenuItem(title: "开启鼠标穿透模式", action: #selector(handleEnableClickThrough), keyEquivalent: "")
        passThroughItem.target = self
        menu.addItem(passThroughItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "隐藏悬浮窗", action: #selector(handleClose), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        return menu
    }

    @objc private func handleOpenMainPanel() {
        openAssetDetail?(nil)
    }

    @objc private func handleToggleChange() {
        settings?.floatingShowsChange.toggle()
    }

    @objc private func handleToggleBalance() {
        settings?.floatingShowsBalance.toggle()
    }

    @objc private func handleOpacityPreset(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            settings?.floatingWindowOpacity = value
        }
    }

    @objc private func handleEnableClickThrough() {
        settings?.floatingClickThrough = true
    }

    @objc private func handleClose() {
        close()
    }

    // MARK: 窗口初始位置计算

    private func idealWindowHeight(rowCount: Int) -> CGFloat {
        let clampedRows = min(max(rowCount, 2), 8)
        return CGFloat(clampedRows) * 32 + 44
    }

    private func resolvedInitialFrame(defaultHeight: CGFloat, settings: AppSettings) -> NSRect {
        if let saved = settings.loadFloatingFrame() {
            // 确保上次保存的位置仍在当前连接的某个屏幕内
            let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(saved) }
            if isOnScreen {
                return saved
            }
        }

        let width: CGFloat = 246
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            return NSRect(
                x: visible.maxX - width - 20,
                y: visible.maxY - defaultHeight - 20,
                width: width,
                height: defaultHeight
            )
        }
        return NSRect(x: 120, y: 120, width: width, height: defaultHeight)
    }
}

// MARK: - 自定义悬浮窗 Panel

final class FloatingTickerPanel: NSPanel {
    var contextMenuBuilder: (() -> NSMenu?)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuBuilder?(), let contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, handlePossibleWindowDrag(downEvent: event) {
            return
        }
        super.sendEvent(event)
    }

    /// 让无标题栏悬浮窗支持“按住任意位置拖动移动，轻点币种行仍正常跳转详情”
    private func handlePossibleWindowDrag(downEvent: NSEvent) -> Bool {
        guard let contentView else { return false }

        // 有弹窗（如透明度调节 Popover）时交由系统正常处理
        if childWindows?.isEmpty == false {
            return false
        }

        let point = downEvent.locationInWindow
        let bounds = contentView.bounds

        // 保留四周 6pt 边缘用于原生拖拽缩放尺寸
        let resizeMargin: CGFloat = 6
        if point.x <= resizeMargin || point.x >= bounds.width - resizeMargin ||
            point.y <= resizeMargin || point.y >= bounds.height - resizeMargin {
            return false
        }

        // 右上角顶部工具按钮热区（透明度 / 展开主面板 / 隐藏），直接放行点击
        let inHeaderZone = point.y >= bounds.height - 32
        if inHeaderZone && point.x >= bounds.width - 84 {
            return false
        }

        // 顶部栏及主体区域统一采用“拖动 ≥ 4pt 移动窗口，轻点则正常响应按钮（如点击余额跳资产页 / 点击币种跳详情）”
        let startLocation = point
        let dragThreshold: CGFloat = 4

        while true {
            guard let nextEvent = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                return true
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                let current = nextEvent.locationInWindow
                let distance = hypot(current.x - startLocation.x, current.y - startLocation.y)
                if distance >= dragThreshold {
                    performDrag(with: downEvent)
                    return true
                }
            case .leftMouseUp:
                // 位移未达拖动阈值：按普通单击透传给 SwiftUI 按钮
                super.sendEvent(downEvent)
                super.sendEvent(nextEvent)
                return true
            default:
                break
            }
        }
    }
}

// MARK: - 毛玻璃材质封装

private final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = DraggableVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - 悬浮窗 SwiftUI 视图

struct FloatingTickerView: View {
    let hub: MarketQuoteHub
    let watchlist: WatchlistStore
    let portfolio: PortfolioStore
    @Bindable var settings: AppSettings
    let onSelectAsset: (CryptoAsset) -> Void
    let onOpenMainPanel: () -> Void
    let onOpenPortfolio: () -> Void
    let onClose: () -> Void

    @State private var isHoveringWindow = false
    @State private var isShowingOpacityPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerBar
            rowsList
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(min(settings.floatingWindowOpacity * 1.05, 0.95))
                Color(red: 0.08, green: 0.09, blue: 0.12)
                    .opacity(settings.floatingWindowOpacity * 0.78)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
        )
        .foregroundStyle(.white)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHoveringWindow = hovering
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)

            Text("自选行情")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .layoutPriority(1)

            if settings.floatingShowsBalance && portfolio.enabledAccounts.isEmpty == false {
                balanceBadge
            }

            Spacer(minLength: 4)

            if isHoveringWindow || isShowingOpacityPopover {
                HStack(spacing: 6) {
                    Button {
                        isShowingOpacityPopover.toggle()
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.76))
                    .help("调整透明度")
                    .popover(isPresented: $isShowingOpacityPopover, arrowEdge: .bottom) {
                        opacityPopover
                    }

                    Button(action: onOpenMainPanel) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.76))
                    .help("打开主行情面板")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.76))
                    .help("隐藏悬浮窗")
                }
                .transition(.opacity)
            } else if let updatedAt = hub.lastUpdatedAt {
                Text(MarketFormatter.clockTime(updatedAt))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 18)
    }

    private var opacityPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("背景透明度")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int((settings.floatingWindowOpacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $settings.floatingWindowOpacity, in: AppSettings.floatingOpacityRange)
                .frame(width: 160)

            Toggle("显示 24h 涨跌幅", isOn: $settings.floatingShowsChange)
                .font(.caption)

            Toggle("顶部栏显示账户余额", isOn: $settings.floatingShowsBalance)
                .font(.caption)
        }
        .padding(12)
    }

    private var balanceBadge: some View {
        let hasSnapshot = portfolio.enabledAccounts.contains { portfolio.snapshots[$0.id] != nil }
        let equity = portfolio.totalEquityUSD()
        let text: String = {
            if portfolio.hideAmounts { return "****" }
            guard hasSnapshot else { return "--" }
            return MarketFormatter.price(equity)
        }()

        return Button(action: onOpenPortfolio) {
            HStack(spacing: 3) {
                Image(systemName: "wallet.bifold.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.62))
                Text(text)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.11), in: Capsule())
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("已绑定账户总余额（点击查看资产与仓位）")
    }

    private var rowsList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(watchlist.floatingAssets) { asset in
                    FloatingQuoteRow(
                        asset: asset,
                        quote: hub.quotes[asset.id],
                        flash: hub.flashes[asset.id],
                        showsChange: settings.floatingShowsChange,
                        settings: settings,
                        onTap: { onSelectAsset(asset) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var statusDotColor: Color {
        switch hub.connectionState {
        case .live:
            return MarketColors.green
        case .offline:
            return MarketColors.red
        default:
            return .orange
        }
    }
}

// MARK: - 悬浮窗单行

private struct FloatingQuoteRow: View {
    let asset: CryptoAsset
    let quote: CryptoQuote?
    let flash: PriceTickFlash?
    let showsChange: Bool
    let settings: AppSettings
    let onTap: () -> Void

    @State private var isHovering = false
    @State private var flashColor: Color?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                CoinAvatar(symbol: asset.symbol, size: 18)

                HStack(spacing: 4) {
                    Text(asset.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    if let badge = asset.kindBadge {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 4)

                Text(quote.map { MarketFormatter.price($0.price) } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)

                if showsChange, let quote {
                    Text(MarketFormatter.changePercent(quote.changePercentage24h))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(settings.changeColor(for: quote.changePercentage24h))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .frame(minWidth: 52, alignment: .trailing)
                        .background(
                            settings.changeColor(for: quote.changePercentage24h).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 29)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onChange(of: flash?.sequence) { _, _ in
            guard let flash else { return }
            flashColor = flash.direction == .up ? settings.upColor : settings.downColor
            withAnimation(.easeOut(duration: 0.65)) {
                flashColor = nil
            }
        }
    }

    private var rowBackground: Color {
        if let flashColor {
            return flashColor.opacity(0.22)
        }
        return .white.opacity(isHovering ? 0.13 : 0.05)
    }
}
