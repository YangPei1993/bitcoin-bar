import SwiftUI

// MARK: - 资产与仓位总览视图

private enum PortfolioSubTab: String, CaseIterable, Identifiable {
    case positions
    case balances

    var id: String { rawValue }

    var label: String {
        switch self {
        case .positions: return "合约仓位"
        case .balances: return "账户余额"
        }
    }
}

struct PortfolioView: View {
    @Bindable var portfolio: PortfolioStore
    let riskEngine: RiskMonitorEngine
    let settings: AppSettings
    let onOpenAccountSettings: () -> Void
    let onOpenAlertSettings: () -> Void
    let onSelectPositionAsset: (CryptoAsset) -> Void
    let onShowToast: (String) -> Void

    @State private var selectedAccountID: UUID?
    @State private var subTab: PortfolioSubTab = .positions

    // 快速添加余额提醒 Sheet
    @State private var isShowingAddBalanceAlert = false
    @State private var draftScopeSelection = "total"
    @State private var draftCurrency = "USDT"
    @State private var draftDirection: BalanceAlertDirection = .below
    @State private var draftThreshold = ""
    @State private var draftRepeating = false
    @State private var draftNote = ""

    var body: some View {
        Group {
            if portfolio.accounts.isEmpty {
                emptyAccountsGuide
            } else {
                portfolioContent
            }
        }
        .onAppear {
            if portfolio.enabledAccounts.isEmpty == false {
                portfolio.startAutoRefresh()
            }
        }
        .onDisappear {
            portfolio.stopAutoRefresh()
        }
        .sheet(isPresented: $isShowingAddBalanceAlert) {
            addBalanceAlertSheet
        }
    }

    // MARK: 未绑定账号时的消费级引导页

    private var emptyAccountsGuide: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "wallet.bifold")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("连接交易所只读账户")
                    .font(.headline)
                Text("支持接入 OKX 与 币安（Binance）只读 API，在一个面板里实时查看账户净值、现货/合约余额、当前持仓盈亏，并设置余额提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            VStack(alignment: .leading, spacing: 6) {
                securityBullet("仅需“只读”权限，严禁开启提币与交易权限")
                securityBullet("API Key / Secret 加密存储于 macOS 钥匙串")
                securityBullet("本地直连交易所官方接口，不经任何中转服务")
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)

            Button {
                onOpenAccountSettings()
            } label: {
                Label("前往绑定 OKX / 币安账户", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func securityBullet(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(MarketColors.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 资产与仓位主体内容

    private var portfolioContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if portfolio.enabledAccounts.count > 1 {
                    accountFilterStrip
                }

                equitySummaryCard
                activeRiskAlertsBannerIfNeeded
                warningsBannerIfNeeded
                subTabHeader

                if subTab == .positions {
                    positionsListSection
                } else {
                    balancesListSection
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 多账户筛选胶囊

    private var accountFilterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                filterPill(title: "全部账户", isSelected: selectedAccountID == nil) {
                    selectedAccountID = nil
                }
                ForEach(portfolio.enabledAccounts) { account in
                    filterPill(title: account.name, isSelected: selectedAccountID == account.id) {
                        selectedAccountID = account.id
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func filterPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary.opacity(0.78))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 总资产净值大卡片

    private var equitySummaryCard: some View {
        let totalEquity = portfolio.totalEquityUSD(accountID: selectedAccountID)
        let totalPnL = portfolio.totalUnrealizedPnL(accountID: selectedAccountID)
        let positionCount = portfolio.positions(accountID: selectedAccountID).count
        let pnlColor = settings.changeColor(for: totalPnL)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(selectedAccountName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    portfolio.hideAmounts.toggle()
                } label: {
                    Image(systemName: portfolio.hideAmounts ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(portfolio.hideAmounts ? "显示金额" : "隐藏金额（防窥）")

                Spacer()

                Button {
                    prepareBalanceAlert(scopeKey: selectedAccountID.map { "account:\($0.uuidString)" } ?? "total", currency: "USDT", suggestedValue: totalEquity)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: portfolio.activeBalanceAlertCount > 0 ? "bell.badge.fill" : "bell")
                            .font(.system(size: 10.5))
                        Text("余额提醒")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(portfolio.activeBalanceAlertCount > 0 ? .orange : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("添加账户净值或币种余额提醒")

                Button {
                    Task { await portfolio.refreshAll() }
                } label: {
                    Group {
                        if portfolio.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(portfolio.isRefreshing)
                .help("立即同步账户资产")

                Button {
                    onOpenAccountSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("管理 OKX / 币安账户")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(maskedUSD(totalEquity))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("合约未实现盈亏")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Text(portfolio.hideAmounts ? "****" : MarketFormatter.changeAmount(totalPnL))
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(portfolio.hideAmounts ? .secondary : pnlColor)
                }
            }

            HStack(spacing: 12) {
                Label("\(positionCount) 个持仓", systemImage: "chart.bar.xaxis")
                if portfolio.activeBalanceAlertCount > 0 {
                    Button {
                        onOpenAlertSettings()
                    } label: {
                        Label("\(portfolio.activeBalanceAlertCount) 条余额提醒", systemImage: "bell.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let updated = portfolio.lastUpdatedAt {
                    Text("同步于 \(MarketFormatter.clockTime(updated))")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var activeRiskAlertsBannerIfNeeded: some View {
        if riskEngine.activePortfolioRisks.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(riskEngine.activePortfolioRisks) { risk in
                    let color: Color = risk.severity == .critical ? MarketColors.red : .orange
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: risk.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color)
                            Text(risk.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (riskEngine.activePortfolioRisks.contains(where: { $0.severity == .critical }) ? MarketColors.red : Color.orange).opacity(0.11),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
    }

    @ViewBuilder
    private var warningsBannerIfNeeded: some View {
        let warnings = portfolio.activeWarnings(accountID: selectedAccountID)
        if warnings.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("\(item.0)：\(item.1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: 仓位 / 余额切换栏

    private var subTabHeader: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(PortfolioSubTab.allCases) { tab in
                    let isSelected = subTab == tab
                    let count = tab == .positions
                        ? portfolio.positions(accountID: selectedAccountID).count
                        : portfolio.balances(accountID: selectedAccountID).count
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            subTab = tab
                        }
                    } label: {
                        Text("\(tab.label) (\(count))")
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 25)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            if subTab == .balances {
                Toggle("隐藏 <$1", isOn: $portfolio.hideSmallBalances)
                    .font(.caption2)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 合约仓位列表

    @ViewBuilder
    private var positionsListSection: some View {
        let items = portfolio.positions(accountID: selectedAccountID)
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(portfolio.isRefreshing ? "正在同步合约仓位..." : "当前没有持仓")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("开仓后此处将实时展示开仓均价、标记价、预估强平价与未实现盈亏。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(items) { position in
                    PositionCardView(
                        position: position,
                        hideAmounts: portfolio.hideAmounts,
                        settings: settings,
                        onTap: {
                            onSelectPositionAsset(position.marketAsset)
                        }
                    )
                }
            }
        }
    }

    // MARK: 账户余额列表

    @ViewBuilder
    private var balancesListSection: some View {
        let items = portfolio.balances(accountID: selectedAccountID)
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "banknote")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(portfolio.isRefreshing ? "正在同步账户余额..." : "暂无符合条件的资产余额")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            LazyVStack(spacing: 4) {
                ForEach(items) { item in
                    BalanceRowView(
                        item: item,
                        hideAmounts: portfolio.hideAmounts,
                        onAddAlert: {
                            prepareBalanceAlert(
                                scopeKey: "ccy:\(item.accountID.uuidString):\(item.currency)",
                                currency: item.currency,
                                suggestedValue: item.total
                            )
                        }
                    )
                }
            }
        }
    }

    // MARK: 添加余额提醒弹窗

    private var addBalanceAlertSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("添加余额提醒", systemImage: "bell.badge")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("监控对象")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $draftScopeSelection) {
                    Text("全部账户总资产 (USD)").tag("total")
                    ForEach(portfolio.enabledAccounts) { account in
                        Text("\(account.name) 总权益 (USD)").tag("account:\(account.id.uuidString)")
                        Text("\(account.name) 指定币种数量").tag("currency:\(account.id.uuidString)")
                    }
                }
                .labelsHidden()

                if draftScopeSelection.hasPrefix("currency:") {
                    HStack {
                        Text("币种代码")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("如 USDT、BTC、ETH", text: $draftCurrency)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $draftDirection) {
                    ForEach(BalanceAlertDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 112)

                TextField(draftScopeSelection.hasPrefix("currency:") ? "阈值数量" : "阈值金额 (USD)", text: $draftThreshold)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }

            TextField("备注（可选，如：提醒补充保证金）", text: $draftNote)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Toggle("到达后重复提醒（10 分钟冷却）", isOn: $draftRepeating)
                .font(.caption)

            HStack {
                Spacer()
                Button("取消") {
                    isShowingAddBalanceAlert = false
                }
                Button("保存提醒") {
                    submitBalanceAlert()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedDraftThreshold == nil)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    // MARK: 辅助方法

    private var selectedAccountName: String {
        guard let selectedAccountID,
              let account = portfolio.accounts.first(where: { $0.id == selectedAccountID }) else {
            return "总资产估值 (USD)"
        }
        return "\(account.name) · 净值 (USD)"
    }

    private func maskedUSD(_ value: Double) -> String {
        portfolio.hideAmounts ? "****" : MarketFormatter.price(value)
    }

    private var parsedDraftThreshold: Double? {
        let cleaned = draftThreshold
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        return value
    }

    private func prepareBalanceAlert(scopeKey: String, currency: String, suggestedValue: Double) {
        if scopeKey.hasPrefix("ccy:") {
            let parts = scopeKey.split(separator: ":")
            if parts.count == 3 {
                draftScopeSelection = "currency:\(parts[1])"
                draftCurrency = String(parts[2])
            }
        } else {
            draftScopeSelection = scopeKey
            draftCurrency = currency
        }
        draftDirection = .below
        draftRepeating = false
        draftNote = ""
        if suggestedValue > 0 {
            let suggested = max(suggestedValue * 0.85, 0)
            draftThreshold = MarketFormatter.price(suggested, includeSymbol: false).replacingOccurrences(of: ",", with: "")
        } else {
            draftThreshold = ""
        }
        isShowingAddBalanceAlert = true
    }

    private func submitBalanceAlert() {
        guard let threshold = parsedDraftThreshold else { return }

        let scope: BalanceAlertScope
        if draftScopeSelection == "total" {
            scope = .totalEquity
        } else if draftScopeSelection.hasPrefix("account:"),
                  let uuid = UUID(uuidString: String(draftScopeSelection.dropFirst("account:".count))),
                  let account = portfolio.accounts.first(where: { $0.id == uuid }) {
            scope = .accountEquity(accountID: account.id, accountName: account.name)
        } else if draftScopeSelection.hasPrefix("currency:"),
                  let uuid = UUID(uuidString: String(draftScopeSelection.dropFirst("currency:".count))),
                  let account = portfolio.accounts.first(where: { $0.id == uuid }) {
            let ccy = draftCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard ccy.isEmpty == false else { return }
            scope = .currencyBalance(accountID: account.id, accountName: account.name, currency: ccy)
        } else {
            scope = .totalEquity
        }

        portfolio.addBalanceAlert(
            scope: scope,
            direction: draftDirection,
            threshold: threshold,
            isRepeating: draftRepeating,
            note: draftNote
        )
        isShowingAddBalanceAlert = false
        onShowToast("已添加余额提醒：\(scope.title)")
    }
}

// MARK: - 合约仓位卡片

private struct PositionCardView: View {
    let position: AccountPositionItem
    let hideAmounts: Bool
    let settings: AppSettings
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        let sideColor = position.side == .long ? settings.upColor : settings.downColor
        let pnlColor = settings.changeColor(for: position.unrealizedPnL)
        let liqDistance = RiskMonitorEngine.liquidationDistancePercent(for: position)

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CoinAvatar(symbol: position.marketAsset.symbol, size: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(position.displayPair)
                                .font(.system(size: 13, weight: .semibold))
                            Text(position.side.label)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(sideColor, in: RoundedRectangle(cornerRadius: 4))
                            Text("\(Int(position.leverage.rounded()))x \(position.marginMode)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))

                            if let liqDistance, liqDistance <= 12 {
                                let isCrit = liqDistance <= 5
                                Text("距强平 \(String(format: "%.1f", liqDistance))%")
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(isCrit ? .white : .orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        isCrit ? MarketColors.red : Color.orange.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                            }
                        }

                        Text("\(position.exchange.shortLabel) · \(position.accountName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(hideAmounts ? "****" : MarketFormatter.changeAmount(position.unrealizedPnL))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(hideAmounts ? .secondary : pnlColor)
                        Text(MarketFormatter.changePercent(position.roePercent))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(pnlColor.opacity(0.9))
                    }
                }

                HStack(spacing: 6) {
                    positionMetric("持仓价值", hideAmounts ? "****" : MarketFormatter.price(position.notionalUSD))
                    positionMetric("开仓均价", MarketFormatter.price(position.entryPrice))
                    positionMetric("标记价格", MarketFormatter.price(position.markPrice))
                    positionMetric(
                        "预估强平",
                        position.liquidationPrice.map { MarketFormatter.price($0) } ?? "--",
                        accent: position.liquidationPrice != nil ? .orange : nil
                    )
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("点击查看该合约 K 线详情")
    }

    private func positionMetric(_ title: String, _ value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 账户余额行

private struct BalanceRowView: View {
    let item: AccountBalanceItem
    let hideAmounts: Bool
    let onAddAlert: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            CoinAvatar(symbol: item.currency, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.currency)
                        .font(.system(size: 13, weight: .semibold))
                    Text(item.bucket.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                    Text(item.exchange.shortLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.accentColor)
                }

                Text(frozenText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(hideAmounts ? "****" : MarketFormatter.price(item.total, includeSymbol: false))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(hideAmounts ? "****" : (item.usdValue > 0 ? "≈ \(MarketFormatter.price(item.usdValue))" : "--"))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(action: onAddAlert) {
                Image(systemName: "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .opacity(isHovering ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .help("为此币种余额设置提醒")
        }
        .padding(.horizontal, 9)
        .frame(height: 46)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("为 \(item.currency) 余额添加提醒...") {
                onAddAlert()
            }
        }
    }

    private var frozenText: String {
        if hideAmounts {
            return item.accountName
        }
        if item.frozen > 0.000001 {
            return "\(item.accountName) · 冻结 \(MarketFormatter.price(item.frozen, includeSymbol: false))"
        }
        return item.accountName
    }
}
