import AppKit
import SwiftUI

// MARK: - 币种详情页

struct AssetDetailView: View {
    let asset: CryptoAsset
    let hub: MarketQuoteHub
    let tickerStore: CryptoTickerStore
    let watchlist: WatchlistStore
    let alertStore: PriceAlertStore
    @Bindable var tradingStore: OKXTradingStore
    let settings: AppSettings
    let aiCache: AIAnalysisCache
    let onBack: () -> Void
    let onOpenAISettings: () -> Void
    let onOpenTradingSettings: () -> Void
    let onShowToast: (String) -> Void

    @State private var quickOrderSide: TradeOrderSide?
    @State private var isShowingAddAlert = false
    @State private var alertDirection: PriceAlertDirection = .above
    @State private var alertPriceInput = ""
    @State private var alertRepeating = false
    @State private var alertNote = ""

    @State private var isGeneratingAI = false
    @State private var aiError: String?

    private var quote: CryptoQuote? {
        hub.quotes[asset.id]
    }

    private var isFavorite: Bool {
        watchlist.isFavorite(asset)
    }

    private var isMenuBarAsset: Bool {
        settings.menuBarAsset == asset
    }

    private var assetAlerts: [PriceAlert] {
        alertStore.alerts(for: asset)
    }

    private var cachedReport: AIAnalysisReport? {
        aiCache.report(for: asset, interval: tickerStore.selectedInterval)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailNavBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    priceOverviewCard
                    quickTradeBar
                    chartCard
                    quickAlertCard
                    aiAnalysisCard
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $quickOrderSide) { side in
            QuickOrderSheet(
                asset: asset,
                referencePrice: quote?.price ?? 0,
                settings: settings,
                tradingStore: tradingStore,
                initialSide: side,
                onOpenTradingSettings: onOpenTradingSettings,
                onOrderSucceeded: { msg in onShowToast(msg) }
            )
        }
        .onAppear {
            tickerStore.activateDetail(for: asset)
        }
        .onChange(of: asset) { _, newAsset in
            aiError = nil
            isShowingAddAlert = false
            tickerStore.activateDetail(for: newAsset)
        }
        .onDisappear {
            tickerStore.deactivateDetail()
        }
    }

    // MARK: 快捷交易操作条

    private var quickTradeBar: some View {
        HStack(spacing: 8) {
            if tradingStore.config.tradingEnabled {
                Button {
                    quickOrderSide = .buy
                } label: {
                    Label(TradeOrderSide.buy.label(for: asset.instrumentKind), systemImage: "arrow.up.right.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.upColor)

                Button {
                    quickOrderSide = .sell
                } label: {
                    Label(TradeOrderSide.sell.label(for: asset.instrumentKind), systemImage: "arrow.down.right.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.downColor)
            } else {
                Button {
                    quickOrderSide = .buy
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("OKX 快捷下单（前往设置开启交易模式）")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
    }

    // MARK: 顶部导航条

    private var detailNavBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("行情")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            CoinAvatar(symbol: asset.symbol, size: 22)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(asset.pairLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let badge = asset.kindBadge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(asset.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                iconButton(
                    systemImage: isFavorite ? "star.fill" : "star",
                    tint: isFavorite ? .orange : .secondary,
                    help: isFavorite ? "移出自选" : "加入自选"
                ) {
                    let added = watchlist.toggleFavorite(asset)
                    onShowToast(added ? "已加入自选" : "已移出自选")
                }

                iconButton(
                    systemImage: isMenuBarAsset ? "menubar.dock.rectangle.badge.record" : "menubar.rectangle",
                    tint: isMenuBarAsset ? Color.accentColor : .secondary,
                    help: isMenuBarAsset ? "当前正在菜单栏展示" : "固定到菜单栏展示"
                ) {
                    settings.menuBarAsset = asset
                    onShowToast("菜单栏已切换为 \(asset.symbol)")
                }

                iconButton(
                    systemImage: assetAlerts.contains(where: \.isEnabled) ? "bell.badge.fill" : "bell",
                    tint: assetAlerts.contains(where: \.isEnabled) ? .orange : .secondary,
                    help: "添加价格提醒"
                ) {
                    prepareAlertSheet()
                }

                Menu {
                    if let quote {
                        Button("复制最新价格") {
                            copyToPasteboard(MarketFormatter.price(quote.price))
                            onShowToast("已复制 \(MarketFormatter.price(quote.price))")
                        }
                    }

                    if watchlist.customGroups.isEmpty == false {
                        Menu("加入自定义分组") {
                            ForEach(watchlist.customGroups) { group in
                                let exists = watchlist.contains(asset, inGroup: group.id)
                                Button {
                                    let added = watchlist.toggle(asset, inGroup: group.id)
                                    onShowToast(added ? "已加入“\(group.name)”" : "已从“\(group.name)”移除")
                                } label: {
                                    HStack {
                                        Text(group.name)
                                        if exists { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }

                    if let url = asset.okxTradeURL {
                        Divider()
                        Button("在 OKX 网页版查看") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func iconButton(systemImage: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 报价总览卡片

    private var priceOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if let quote {
                        Text(MarketFormatter.price(quote.price))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .onTapGesture {
                                copyToPasteboard(MarketFormatter.price(quote.price))
                                onShowToast("已复制价格")
                            }

                        HStack(spacing: 6) {
                            let color = settings.changeColor(for: quote.changePercentage24h)
                            Text(MarketFormatter.changePercent(quote.changePercentage24h))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(color)

                            Text(MarketFormatter.changeAmount(quote.changeAmount24h))
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(color.opacity(0.9))

                            Text("UTC+0")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("加载实时报价...")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    metricChip(title: "24h 成交额", value: quote.map { MarketFormatter.compactVolume($0.volumeCurrency24h, isCurrency: true) } ?? "--")
                    metricChip(title: "24h 成交量", value: quote.map { "\(MarketFormatter.compactVolume($0.volume24h)) \(asset.symbol)" } ?? "--")
                }
            }

            if let quote, quote.high24h > quote.low24h {
                DayRangeBar(
                    low: quote.low24h,
                    high: quote.high24h,
                    current: quote.price,
                    accent: settings.changeColor(for: quote.changePercentage24h)
                )
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: K 线图表卡片

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(KlineInterval.allCases) { interval in
                    let isSelected = interval == tickerStore.selectedInterval
                    Button {
                        tickerStore.selectInterval(interval)
                    } label: {
                        Text(interval.shortLabel)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            InteractiveMarketChart(
                klines: tickerStore.klines,
                interval: tickerStore.selectedInterval,
                isLoading: tickerStore.isLoadingKlines,
                errorMessage: tickerStore.klineError,
                settings: settings,
                onRetry: { tickerStore.reloadKlines() }
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    // MARK: 快捷价格提醒卡片

    private var quickAlertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("价格提醒", systemImage: "bell.badge")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(isShowingAddAlert ? "收起" : "添加提醒") {
                    if isShowingAddAlert {
                        withAnimation(.easeInOut(duration: 0.16)) { isShowingAddAlert = false }
                    } else {
                        prepareAlertSheet()
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }

            if isShowingAddAlert {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Picker("", selection: $alertDirection) {
                            ForEach(PriceAlertDirection.allCases) { dir in
                                Text(dir.label).tag(dir)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 112)

                        TextField("目标价格 (USDT)", text: $alertPriceInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12).monospacedDigit())

                        Button("保存") {
                            saveAlert()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(parsedAlertPrice == nil)
                    }

                    HStack(spacing: 10) {
                        TextField("备注（可选，如：止盈位）", text: $alertNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)

                        Toggle("重复提醒", isOn: $alertRepeating)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(10)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if assetAlerts.isEmpty == false {
                VStack(spacing: 6) {
                    ForEach(assetAlerts) { alert in
                        HStack(spacing: 8) {
                            Image(systemName: alert.direction.symbol)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                                .frame(width: 18, height: 18)
                                .background(
                                    (alert.direction == .above ? settings.upColor : settings.downColor).opacity(0.14),
                                    in: Circle()
                                )

                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(alert.direction.label) \(MarketFormatter.price(alert.targetPrice))")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                if alert.note.isEmpty == false {
                                    Text(alert.note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if let triggered = alert.lastTriggeredAt {
                                    Text("已于 \(MarketFormatter.clockTime(triggered)) 触发")
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
                            .controlSize(.mini)

                            Button {
                                alertStore.deleteAlert(id: alert.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if isShowingAddAlert == false {
                Text("到达目标价时通过 macOS 系统通知第一时间提醒您。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    // MARK: AI 智能行情解读卡片

    private var aiAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 行情解读", systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))

                if let report = cachedReport {
                    Text(MarketFormatter.clockTime(report.generatedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let report = cachedReport {
                    Button {
                        copyToPasteboard(report.content)
                        onShowToast("已复制 AI 分析报告")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制分析报告")
                }

                Button("配置") {
                    onOpenAISettings()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }

            if settings.aiConfiguration.isReady == false {
                HStack(spacing: 10) {
                    Text("配置 OpenAI、DeepSeek、通义千问或本地 Ollama 模型后，即可基于实时 K 线生成结构化解读。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("去配置") {
                        onOpenAISettings()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task { await runAIAnalysis() }
                    } label: {
                        HStack(spacing: 6) {
                            if isGeneratingAI {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11))
                            }
                            Text(isGeneratingAI ? "分析中..." : (cachedReport == nil ? "生成 \(tickerStore.selectedInterval.shortLabel) 解读" : "重新生成"))
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isGeneratingAI || tickerStore.klines.isEmpty)

                    Text("模型：\(settings.aiConfiguration.model)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let aiError {
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(MarketColors.red)
                }

                if let report = cachedReport {
                    Text(report.content)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    // MARK: 业务逻辑

    private var parsedAlertPrice: Double? {
        let cleaned = alertPriceInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        return value
    }

    private func prepareAlertSheet() {
        if let price = quote?.price, alertPriceInput.isEmpty {
            let suggested = alertDirection == .above ? price * 1.02 : price * 0.98
            alertPriceInput = MarketFormatter.price(suggested, includeSymbol: false).replacingOccurrences(of: ",", with: "")
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            isShowingAddAlert = true
        }
    }

    private func saveAlert() {
        guard let price = parsedAlertPrice else { return }
        alertStore.addAlert(
            asset: asset,
            direction: alertDirection,
            targetPrice: price,
            isRepeating: alertRepeating,
            note: alertNote
        )
        alertPriceInput = ""
        alertNote = ""
        withAnimation(.easeInOut(duration: 0.16)) {
            isShowingAddAlert = false
        }
        onShowToast("已添加 \(asset.symbol) \(alertDirection.label) \(MarketFormatter.price(price)) 提醒")
    }

    private func runAIAnalysis() async {
        isGeneratingAI = true
        aiError = nil
        defer { isGeneratingAI = false }

        do {
            let context = MarketAnalysisContext(
                asset: asset,
                interval: tickerStore.selectedInterval,
                quote: quote,
                klines: tickerStore.klines
            )
            let report = try await AIAnalysisService().analyze(
                context: context,
                configuration: settings.aiConfiguration
            )
            aiCache.store(report, for: asset, interval: tickerStore.selectedInterval)
        } catch {
            aiError = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
