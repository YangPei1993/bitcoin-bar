import AppKit
import SwiftUI

// MARK: - 设置分栏

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case display
    case accounts
    case alerts
    case channels
    case ai
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "通用"
        case .display: return "显示"
        case .accounts: return "账户"
        case .alerts: return "风控提醒"
        case .channels: return "推送通道"
        case .ai: return "AI 助手"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "menubar.rectangle"
        case .accounts: return "wallet.bifold"
        case .alerts: return "shield.lefthalf.filled"
        case .channels: return "paperplane.circle"
        case .ai: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 设置窗口主视图

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let hub: MarketQuoteHub
    let watchlist: WatchlistStore
    let alertStore: PriceAlertStore
    let portfolioStore: PortfolioStore
    let tradingStore: OKXTradingStore
    let riskEngine: RiskMonitorEngine
    let dispatcher: NotificationDispatcher
    let tickerStore: CryptoTickerStore
    let toggleFloatingWindow: () -> Void

    @State private var selectedTab: SettingsTab = .general

    // AI 连接测试
    @State private var isTestingAI = false
    @State private var aiTestMessage: String?
    @State private var aiTestSucceeded = false

    // 交易所账户表单状态
    @State private var isShowingAccountForm = false
    @State private var editingAccountID: UUID?
    @State private var draftExchange: ExchangeKind = .okx
    @State private var draftAccountName = ""
    @State private var draftAPIKey = ""
    @State private var draftSecretKey = ""
    @State private var draftPassphrase = ""
    @State private var draftCustomBaseURL = ""
    @State private var draftIsSimulated = false
    @State private var showAdvancedExchangeFields = false
    @State private var isTestingExchange = false
    @State private var exchangeTestMessage: String?
    @State private var exchangeTestSucceeded = false

    init(
        settings: AppSettings,
        hub: MarketQuoteHub,
        watchlist: WatchlistStore,
        alertStore: PriceAlertStore,
        portfolioStore: PortfolioStore,
        tradingStore: OKXTradingStore,
        riskEngine: RiskMonitorEngine,
        dispatcher: NotificationDispatcher,
        tickerStore: CryptoTickerStore,
        initialTab: SettingsTab = .general,
        toggleFloatingWindow: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.hub = hub
        self.watchlist = watchlist
        self.alertStore = alertStore
        self.portfolioStore = portfolioStore
        self.tradingStore = tradingStore
        self.riskEngine = riskEngine
        self.dispatcher = dispatcher
        self.tickerStore = tickerStore
        self.toggleFloatingWindow = toggleFloatingWindow
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                Group {
                    switch selectedTab {
                    case .general: generalTab
                    case .display: displayTab
                    case .accounts: accountsTab
                    case .alerts: alertsTab
                    case .channels: NotificationChannelsSettingsView(dispatcher: dispatcher)
                    case .ai: aiTab
                    case .about: aboutTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 540)
    }

    // MARK: 顶部图标分栏

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15.5, weight: .medium))
                        Text(tab.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 72, height: 48)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: 1. 通用

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("启动与驻留") {
                Toggle("登录 macOS 时自动启动", isOn: launchAtLoginBinding)

                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                Toggle("在程序坞（Dock）中显示图标", isOn: $settings.showDockIcon)
                Text("关闭后将作为纯菜单栏应用轻量运行，点击顶部状态栏图标随时呼出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("启动时自动显示桌面悬浮窗", isOn: $settings.floatingVisibleOnLaunch)
            }

            settingsSection("外观与配色") {
                HStack {
                    Text("界面主题")
                    Spacer()
                    Picker("", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                Divider()

                HStack {
                    Text("涨跌配色")
                    Spacer()
                    Picker("", selection: $settings.priceColorStyle) {
                        ForEach(PriceColorStyle.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                HStack(spacing: 12) {
                    Text("预览：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("+3.42%")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(settings.upColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(settings.upColor)
                    Text("-1.85%")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(settings.downColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(settings.downColor)
                }
            }
        }
    }

    // MARK: 2. 显示

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("菜单栏展示") {
                HStack {
                    Text("固定展示币种")
                    Spacer()
                    Picker("", selection: $settings.menuBarAsset) {
                        ForEach(menuBarCandidateAssets) { asset in
                            Text(asset.pairLabel + (asset.kindBadge.map { " (\($0))" } ?? ""))
                                .tag(asset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                Text("菜单栏币种将固定显示，浏览其他币种时不会跳变。也可以在行情列表右键任意币种“设为菜单栏显示”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("显示样式")
                    Spacer()
                    Picker("", selection: $settings.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                Divider()

                Toggle("高价币使用紧凑缩写（如 $86.4K）", isOn: $settings.menuBarCompactPrice)
                Toggle("涨跌幅在菜单栏显示涨跌色", isOn: $settings.menuBarColoredChange)
            }

            settingsSection("桌面悬浮窗") {
                HStack {
                    Text("背景不透明度")
                    Spacer()
                    Slider(value: $settings.floatingWindowOpacity, in: AppSettings.floatingOpacityRange)
                        .frame(width: 170)
                    Text("\(Int((settings.floatingWindowOpacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                Divider()

                Toggle("显示涨跌幅徽章 (UTC+0)", isOn: $settings.floatingShowsChange)

                Divider()

                Toggle("在顶部栏显示账户总余额", isOn: $settings.floatingShowsBalance)

                Divider()

                Toggle("鼠标穿透模式（点击穿透到下方窗口）", isOn: $settings.floatingClickThrough)
                Text("开启后悬浮窗不拦截鼠标事件，适合边工作边看盘；可在菜单栏右键菜单中随时关闭穿透。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("显示 / 隐藏悬浮窗", action: toggleFloatingWindow)
                }
            }
        }
    }

    // MARK: 3. 交易所账户（OKX / 币安）

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(MarketColors.green)
                Text("安全提示：仅看资产请创建「只读」API Key；如需启用 OKX 交易请仅勾选「读取 + 交易」，严禁勾选提币权限，强烈建议绑定 IP 白名单。密钥仅加密存于本机 macOS 钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MarketColors.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            settingsSection("OKX 交易与安全护栏") {
                TradingSecuritySettingsContent(tradingStore: tradingStore)
            }

            settingsSection("已绑定账户（\(portfolioStore.accounts.count)）") {
                if portfolioStore.accounts.isEmpty {
                    HStack {
                        Text("尚未绑定 OKX 或币安账户。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("添加账户") {
                            openNewAccountForm(exchange: .okx)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(portfolioStore.accounts) { account in
                            HStack(spacing: 10) {
                                Text(account.exchange.shortLabel)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 24)
                                    .background(
                                        account.exchange == .okx ? Color.primary.opacity(0.82) : Color(red: 0.92, green: 0.72, blue: 0.12),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(account.name)
                                            .font(.subheadline.weight(.semibold))
                                        if account.isSimulated {
                                            Text("模拟盘")
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.16), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                        if let snap = portfolioStore.snapshots[account.id] {
                                            Text(MarketFormatter.price(snap.totalEquityUSD))
                                                .font(.caption.weight(.semibold).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let err = portfolioStore.accountErrors[account.id] {
                                        Text(err)
                                            .font(.caption2)
                                            .foregroundStyle(MarketColors.red)
                                            .lineLimit(2)
                                    } else {
                                        Text("API Key：\(account.maskedKey)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { account.isEnabled },
                                    set: { _ in portfolioStore.toggleAccountEnabled(id: account.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Button("编辑") {
                                    openEditAccountForm(account)
                                }
                                .controlSize(.small)

                                Button(role: .destructive) {
                                    portfolioStore.deleteAccount(id: account.id)
                                    if editingAccountID == account.id {
                                        isShowingAccountForm = false
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)

                            if account.id != portfolioStore.accounts.last?.id {
                                Divider()
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button {
                            openNewAccountForm(exchange: .okx)
                        } label: {
                            Label("新增 OKX / 币安账户", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }

            if isShowingAccountForm {
                accountEditorCard
            }
        }
    }

    private var accountEditorCard: some View {
        settingsSection(editingAccountID == nil ? "新增交易所只读账户" : "编辑交易所账户") {
            HStack {
                Text("交易所")
                    .frame(width: 82, alignment: .leading)
                Picker("", selection: $draftExchange) {
                    ForEach(ExchangeKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingAccountID != nil)
            }

            labeledField("账户备注") {
                TextField("例如：\(draftExchange.shortLabel) 主账户", text: $draftAccountName)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("API Key") {
                SecureField(editingAccountID == nil ? "输入只读 API Key（支持 ⌘V）" : "留空表示保持原 API Key 不变", text: $draftAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("Secret Key") {
                SecureField(editingAccountID == nil ? "输入 Secret Key（支持 ⌘V）" : "留空表示保持原 Secret Key 不变", text: $draftSecretKey)
                    .textFieldStyle(.roundedBorder)
            }

            if draftExchange.requiresPassphrase {
                labeledField("Passphrase") {
                    SecureField(editingAccountID == nil ? "创建 OKX API 时设置的密码短语" : "留空表示保持原 Passphrase 不变", text: $draftPassphrase)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("这是 OKX 模拟盘 API（x-simulated-trading）", isOn: $draftIsSimulated)
                    .font(.caption)
            }

            DisclosureGroup("高级选项（自定义域名/代理）", isExpanded: $showAdvancedExchangeFields) {
                labeledField("自定义域名") {
                    TextField(draftExchange.defaultBaseURL, text: $draftCustomBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let exchangeTestMessage {
                HStack(spacing: 6) {
                    Image(systemName: exchangeTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(exchangeTestSucceeded ? MarketColors.green : MarketColors.red)
                    Text(exchangeTestMessage)
                        .font(.caption)
                        .foregroundStyle(exchangeTestSucceeded ? .primary : MarketColors.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await runExchangeTest() }
                } label: {
                    HStack(spacing: 5) {
                        if isTestingExchange {
                            ProgressView().controlSize(.mini)
                        }
                        Text(isTestingExchange ? "验证中..." : "测试连接")
                    }
                }
                .disabled(isTestingExchange)

                Spacer()

                Button("取消") {
                    isShowingAccountForm = false
                    exchangeTestMessage = nil
                }

                Button("保存账户") {
                    saveExchangeAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSaveAccount == false)
            }
        }
    }

    // MARK: 4. 价格提醒 & 余额提醒

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection("系统通知与外部通道") {
                HStack {
                    Image(systemName: alertStore.notificationAuthorized ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(alertStore.notificationAuthorized ? MarketColors.green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alertStore.notificationAuthorized ? "macOS 系统通知已就绪" : "尚未获得系统通知权限，将使用提示音/外部通道提醒")
                            .font(.subheadline)
                        Text("已启用 \(dispatcher.enabledChannelCount) 个外部推送通道（微信 / Bark / 飞书 / TG / 短信）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("配置通道") {
                        selectedTab = .channels
                    }
                    .controlSize(.small)
                    Button("测试通知") {
                        Task {
                            await alertStore.requestAuthorizationIfNeeded()
                            alertStore.sendTestNotification()
                        }
                    }
                    .controlSize(.small)
                }
            }

            // 主动风控预警规则（强平距离 / 单仓浮亏 / 日内回撤 / 短时异动）
            RiskRulesSettingsSection(riskEngine: riskEngine)

            // 余额提醒分区
            settingsSection("账户余额提醒（\(portfolioStore.balanceAlerts.count)）") {
                if portfolioStore.balanceAlerts.isEmpty {
                    Text("暂无余额提醒。在主面板切换到「资产」页，点击“余额提醒”或任意币种右侧铃铛即可添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(portfolioStore.balanceAlerts) { alert in
                            HStack(spacing: 10) {
                                Image(systemName: "wallet.bifold.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: 24, height: 24)
                                    .background(Color.orange.opacity(0.14), in: Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(alert.scope.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(alert.direction.label) \(alert.formattedThreshold)")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                                        if alert.isRepeating {
                                            Text("重复")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    if let triggeredAt = alert.lastTriggeredAt {
                                        Text("上次触发：\(MarketFormatter.clockTime(triggeredAt))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if alert.note.isEmpty == false {
                                        Text(alert.note)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { alert.isEnabled },
                                    set: { _ in portfolioStore.toggleBalanceAlert(id: alert.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Button(role: .destructive) {
                                    portfolioStore.deleteBalanceAlert(id: alert.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)

                            if alert.id != portfolioStore.balanceAlerts.last?.id {
                                Divider()
                            }
                        }
                    }

                    if portfolioStore.balanceAlerts.contains(where: { $0.isEnabled == false && $0.lastTriggeredAt != nil }) {
                        HStack {
                            Spacer()
                            Button("清理已触发的余额提醒") {
                                portfolioStore.clearTriggeredBalanceAlerts()
                            }
                            .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            // 价格提醒分区
            settingsSection("币种价格提醒（\(alertStore.alerts.count)）") {
                if alertStore.alerts.isEmpty {
                    Text("暂无价格提醒。在行情列表右键任意币种，或在币种详情页点击铃铛图标添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(alertStore.alerts) { alert in
                            HStack(spacing: 10) {
                                CoinAvatar(symbol: alert.asset.symbol, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(alert.asset.pairLabel)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(alert.direction.label) \(MarketFormatter.price(alert.targetPrice))")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                                        if alert.isRepeating {
                                            Text("重复")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    if let triggeredAt = alert.lastTriggeredAt {
                                        Text("上次触发：\(MarketFormatter.clockTime(triggeredAt))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if alert.note.isEmpty == false {
                                        Text(alert.note)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { alert.isEnabled },
                                    set: { _ in alertStore.toggleAlert(id: alert.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Button(role: .destructive) {
                                    alertStore.deleteAlert(id: alert.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)

                            if alert.id != alertStore.alerts.last?.id {
                                Divider()
                            }
                        }
                    }

                    if alertStore.alerts.contains(where: { $0.isEnabled == false && $0.lastTriggeredAt != nil }) {
                        HStack {
                            Spacer()
                            Button("清理已触发的价格提醒") {
                                alertStore.clearTriggeredHistory()
                            }
                            .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .task {
            await alertStore.refreshAuthorizationStatus()
        }
    }

    // MARK: 5. AI 助手

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection("模型服务商") {
                HStack {
                    Text("服务预设")
                    Spacer()
                    Picker("", selection: aiProviderBinding) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Text(settings.aiConfiguration.provider.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    labeledField("Base URL") {
                        TextField("https://api.openai.com/v1", text: $settings.aiConfiguration.baseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledField("模型名称") {
                        TextField("gpt-4o-mini", text: $settings.aiConfiguration.model)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledField("API Key") {
                        SecureField(
                            settings.aiConfiguration.provider.requiresAPIKey ? "请输入 API Key（支持 ⌘V 粘贴）" : "本地模型可留空",
                            text: $settings.aiConfiguration.apiKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 10) {
                    Label("API Key 自动加密存储于 macOS 钥匙串", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await runAITest() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingAI {
                                ProgressView().controlSize(.small)
                            }
                            Text(isTestingAI ? "测试中..." : "测试连接")
                        }
                    }
                    .disabled(isTestingAI)
                }

                if let aiTestMessage {
                    HStack(spacing: 6) {
                        Image(systemName: aiTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(aiTestSucceeded ? MarketColors.green : MarketColors.red)
                        Text(aiTestMessage)
                            .font(.caption)
                            .foregroundStyle(aiTestSucceeded ? .primary : MarketColors.red)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: 6. 关于

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection("应用信息") {
                HStack(spacing: 14) {
                    CoinAvatar(symbol: "BTC", size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("bitcoin-bar")
                            .font(.title3.weight(.bold))
                        Text("轻量级 macOS 菜单栏与桌面加密行情 & 资产助手")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("版本 \(appVersionText)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }

            settingsSection("行情数据源与连接") {
                HStack {
                    Circle()
                        .fill(hub.connectionState.isHealthy ? MarketColors.green : .orange)
                        .frame(width: 8, height: 8)
                    Text("当前状态：\(hub.connectionState.label)")
                        .font(.subheadline)
                    Spacer()
                    Button("重新连接") {
                        hub.reconnectNow()
                    }
                    .controlSize(.small)
                }

                Text("主数据源：OKX 实时行情；自动容灾备份：Gate.io。账户查询支持 OKX V5 与 币安官方只读接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsSection("常用快捷键") {
                shortcutRow("⌘K", "快速搜索全市场币种与永续合约")
                shortcutRow("⌘,", "打开设置窗口")
                shortcutRow("⌘R", "手动刷新行情或同步账户资产")
                shortcutRow("Esc", "返回列表或收起行情面板")
            }
        }
    }

    // MARK: 交易所账户表单逻辑

    private var canSaveAccount: Bool {
        if editingAccountID != nil {
            return true
        }
        let hasKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSecret = draftSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasPass = draftExchange.requiresPassphrase == false || draftPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasKey && hasSecret && hasPass
    }

    private func openNewAccountForm(exchange: ExchangeKind) {
        editingAccountID = nil
        draftExchange = exchange
        draftAccountName = ""
        draftAPIKey = ""
        draftSecretKey = ""
        draftPassphrase = ""
        draftCustomBaseURL = ""
        draftIsSimulated = false
        showAdvancedExchangeFields = false
        exchangeTestMessage = nil
        isShowingAccountForm = true
    }

    private func openEditAccountForm(_ account: ExchangeAccountProfile) {
        editingAccountID = account.id
        draftExchange = account.exchange
        draftAccountName = account.name
        draftAPIKey = ""
        draftSecretKey = ""
        draftPassphrase = ""
        draftCustomBaseURL = account.customBaseURL
        draftIsSimulated = account.isSimulated
        showAdvancedExchangeFields = account.customBaseURL.isEmpty == false
        exchangeTestMessage = nil
        isShowingAccountForm = true
    }

    private func resolvedDraftCredentials() -> ExchangeCredentials {
        let existing = editingAccountID.map { portfolioStore.credentials(for: $0) }
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = draftSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = draftPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExchangeCredentials(
            apiKey: apiKey.isEmpty ? (existing?.apiKey ?? "") : apiKey,
            secretKey: secret.isEmpty ? (existing?.secretKey ?? "") : secret,
            passphrase: pass.isEmpty ? (existing?.passphrase ?? "") : pass
        )
    }

    private func runExchangeTest() async {
        isTestingExchange = true
        exchangeTestMessage = nil
        defer { isTestingExchange = false }

        let tempProfile = ExchangeAccountProfile(
            id: editingAccountID ?? UUID(),
            exchange: draftExchange,
            name: draftAccountName.isEmpty ? draftExchange.shortLabel : draftAccountName,
            customBaseURL: draftCustomBaseURL,
            isSimulated: draftIsSimulated
        )

        do {
            let snap = try await portfolioStore.testConnection(
                profile: tempProfile,
                credentials: resolvedDraftCredentials()
            )
            exchangeTestSucceeded = true
            var msg = "连接成功！总权益约 \(MarketFormatter.price(snap.totalEquityUSD))，当前持仓 \(snap.positions.count) 个。"
            if let warn = snap.warningMessage {
                msg += "（\(warn)）"
            }
            exchangeTestMessage = msg
        } catch {
            exchangeTestSucceeded = false
            exchangeTestMessage = error.localizedDescription
        }
    }

    private func saveExchangeAccount() {
        portfolioStore.saveAccount(
            editingID: editingAccountID,
            exchange: draftExchange,
            name: draftAccountName,
            customBaseURL: draftCustomBaseURL,
            isSimulated: draftIsSimulated,
            credentials: ExchangeCredentials(
                apiKey: draftAPIKey,
                secretKey: draftSecretKey,
                passphrase: draftPassphrase
            )
        )
        isShowingAccountForm = false
        exchangeTestMessage = nil
    }

    // MARK: 辅助组件与方法

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
            )
        }
    }

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .frame(width: 82, alignment: .leading)
            field()
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var menuBarCandidateAssets: [CryptoAsset] {
        var result: [CryptoAsset] = [settings.menuBarAsset]
        for asset in watchlist.favoriteAssets + tickerStore.featuredSpotAssets {
            if result.contains(asset) == false {
                result.append(asset)
            }
        }
        return result
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.isLaunchAtLoginEnabled },
            set: { settings.setLaunchAtLogin($0) }
        )
    }

    private var aiProviderBinding: Binding<AIProvider> {
        Binding(
            get: { settings.aiConfiguration.provider },
            set: { provider in
                var config = settings.aiConfiguration
                config.provider = provider
                config.baseURL = provider.defaultBaseURL
                config.model = provider.defaultModel
                settings.aiConfiguration = config
                aiTestMessage = nil
            }
        )
    }

    private var appVersionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func runAITest() async {
        isTestingAI = true
        aiTestMessage = nil
        defer { isTestingAI = false }

        do {
            let reply = try await AIAnalysisService().testConnection(configuration: settings.aiConfiguration)
            aiTestSucceeded = true
            aiTestMessage = "连接正常，模型响应：\(reply)"
        } catch {
            aiTestSucceeded = false
            aiTestMessage = error.localizedDescription
        }
    }
}
