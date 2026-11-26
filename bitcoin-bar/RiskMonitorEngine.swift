import Foundation

// MARK: - 风控规则配置

nonisolated struct RiskAlertConfig: Equatable, Codable, Sendable {
    /// 强平距离预警（|标记价 - 强平价| / 标记价）
    var liquidationEnabled = true
    var liquidationWarningPercent: Double = 10.0
    var liquidationCriticalPercent: Double = 5.0

    /// 单仓浮亏 / ROE 预警
    var positionLossEnabled = true
    /// 亏损收益率百分比绝对值（如 25 表示 ROE <= -25%）
    var positionLossROEPercent: Double = 25.0
    /// 单仓浮亏金额阈值（USD，0 表示不启用金额阈值）
    var positionLossUSD: Double = 0

    /// 账户当日净值回撤预警
    var drawdownEnabled = true
    var drawdownThresholdPercent: Double = 8.0

    /// 短时剧烈异动 / 插针预警（针对自选与持仓币种）
    var volatilityEnabled = true
    var volatilityWindowMinutes: Int = 5
    var volatilityThresholdPercent: Double = 3.0

    var hasPortfolioRiskRuleEnabled: Bool {
        liquidationEnabled || positionLossEnabled || drawdownEnabled
    }
}

nonisolated struct ActiveRiskWarning: Identifiable, Equatable, Sendable {
    let id: String
    let severity: AlertSeverity
    let title: String
    let detail: String
}

// MARK: - 主动风控预警引擎

@MainActor
@Observable
final class RiskMonitorEngine {
    private enum Keys {
        static let config = "RiskMonitorEngine.config"
        static let dailyPeakDate = "RiskMonitorEngine.dailyPeakDate"
        static let dailyPeakEquity = "RiskMonitorEngine.dailyPeakEquity"
    }

    private static let criticalCooldownSeconds: TimeInterval = 180
    private static let warningCooldownSeconds: TimeInterval = 600

    var config: RiskAlertConfig {
        didSet {
            persistConfig()
            onConfigChanged?(config)
            syncVolatilityDemand()
            evaluatePortfolioRisks()
        }
    }

    /// 当前仍处于风险状态的活跃预警（用于在资产页醒目高亮展示）
    private(set) var activePortfolioRisks: [ActiveRiskWarning] = []
    /// 今日记录的账户总净值峰值（用于回撤计算与展示）
    private(set) var dailyPeakEquityUSD: Double = 0

    @ObservationIgnored private let hub: MarketQuoteHub
    @ObservationIgnored private let watchlist: WatchlistStore
    @ObservationIgnored private let portfolio: PortfolioStore
    @ObservationIgnored private let dispatcher: NotificationDispatcher

    /// 冷却记录表：key -> 上次触发时间
    @ObservationIgnored private var cooldowns: [String: Date] = [:]
    /// 短时异动价格采样窗口：assetID -> [(时间, 价格)]
    @ObservationIgnored private var priceSamples: [String: [(Date, Double)]] = [:]
    @ObservationIgnored var onConfigChanged: ((RiskAlertConfig) -> Void)?

    init(
        hub: MarketQuoteHub,
        watchlist: WatchlistStore,
        portfolio: PortfolioStore,
        dispatcher: NotificationDispatcher
    ) {
        self.hub = hub
        self.watchlist = watchlist
        self.portfolio = portfolio
        self.dispatcher = dispatcher

        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config),
           let decoded = try? JSONDecoder().decode(RiskAlertConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = RiskAlertConfig()
        }

        let today = Self.dayStamp(Date())
        if defaults.string(forKey: Keys.dailyPeakDate) == today {
            self.dailyPeakEquityUSD = defaults.double(forKey: Keys.dailyPeakEquity)
        }

        hub.addListener { [weak self] assetID, quote in
            self?.handleLivePriceForVolatility(assetID: assetID, quote: quote)
        }

        syncVolatilityDemand()
    }

    /// 当开启短时异动监控时，持续向行情中枢注册自选与持仓币种，确保收起面板后仍能实时监测插针
    func syncVolatilityDemand() {
        guard config.volatilityEnabled else {
            hub.setDemand([], for: "volatility")
            return
        }
        var targets = watchlist.favoriteAssets
        for position in portfolio.positions() {
            if targets.contains(position.marketAsset) == false {
                targets.append(position.marketAsset)
            }
        }
        hub.setDemand(Array(targets.prefix(20)), for: "volatility")
    }

    /// 计算单个仓位距离强平价的百分比（返回 nil 表示无强平价）
    nonisolated static func liquidationDistancePercent(for position: AccountPositionItem) -> Double? {
        guard let liq = position.liquidationPrice, liq > 0, position.markPrice > 0 else { return nil }
        return abs(position.markPrice - liq) / position.markPrice * 100
    }

    // MARK: 1. 仓位与账户风控评估

    func evaluatePortfolioRisks() {
        var warnings: [ActiveRiskWarning] = []
        var activeKeys = Set<String>()
        let positions = portfolio.positions()

        // A. 强平距离预警 & B. 单仓浮亏预警
        for position in positions {
            if config.liquidationEnabled,
               let distance = Self.liquidationDistancePercent(for: position) {
                let critLimit = min(config.liquidationCriticalPercent, config.liquidationWarningPercent)
                let warnLimit = max(config.liquidationWarningPercent, critLimit)

                if distance <= critLimit {
                    let key = "liq-crit-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单距强平仅 \(String(format: "%.1f", distance))%"
                    let detail = "\(position.exchange.shortLabel) 标记价 \(MarketFormatter.price(position.markPrice))，预估强平 \(MarketFormatter.price(position.liquidationPrice ?? 0))，请立即关注保证金！"
                    warnings.append(ActiveRiskWarning(id: key, severity: .critical, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        severity: .critical,
                        category: "强平极危预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                } else if distance <= warnLimit {
                    let key = "liq-warn-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单距强平 \(String(format: "%.1f", distance))%"
                    let detail = "\(position.exchange.shortLabel) 标记价 \(MarketFormatter.price(position.markPrice))，预估强平 \(MarketFormatter.price(position.liquidationPrice ?? 0))。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .warning, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        severity: .warning,
                        category: "强平距离预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                }
            }

            if config.positionLossEnabled {
                let roeBreached = config.positionLossROEPercent > 0 && position.roePercent <= -config.positionLossROEPercent
                let usdBreached = config.positionLossUSD > 0 && position.unrealizedPnL <= -config.positionLossUSD

                if roeBreached || usdBreached {
                    let key = "loss-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单浮亏 \(MarketFormatter.changeAmount(position.unrealizedPnL)) (\(MarketFormatter.changePercent(position.roePercent)))"
                    let detail = "\(position.exchange.shortLabel) · \(position.accountName)，开仓价 \(MarketFormatter.price(position.entryPrice))，现标记价 \(MarketFormatter.price(position.markPrice))。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .warning, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        severity: .warning,
                        category: "单仓浮亏预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                }
            }
        }

        // C. 账户当日净值回撤预警
        if config.drawdownEnabled,
           portfolio.enabledAccounts.isEmpty == false,
           portfolio.enabledAccounts.allSatisfy({ portfolio.snapshots[$0.id] != nil }) {
            let currentEquity = portfolio.totalEquityUSD()
            updateDailyPeakIfNeeded(currentEquity: currentEquity)

            if dailyPeakEquityUSD > 10, currentEquity > 0 {
                let drawdownPct = (dailyPeakEquityUSD - currentEquity) / dailyPeakEquityUSD * 100
                if drawdownPct >= config.drawdownThresholdPercent {
                    let key = "drawdown-daily"
                    activeKeys.insert(key)
                    let title = "账户当日净值回撤 \(String(format: "%.1f", drawdownPct))%"
                    let detail = "今日峰值 \(MarketFormatter.price(dailyPeakEquityUSD))，当前总净值 \(MarketFormatter.price(currentEquity))，注意控制仓位风险。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .critical, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        severity: .critical,
                        category: "净值回撤预警",
                        title: title,
                        body: detail,
                        assetID: nil,
                        openPortfolio: true
                    )
                }
            }
        }

        // 风险已解除的仓位清除冷却，确保下次真实触发可立即告警
        for existingKey in cooldowns.keys where existingKey.hasPrefix("vol-") == false {
            if activeKeys.contains(existingKey) == false {
                cooldowns.removeValue(forKey: existingKey)
            }
        }

        activePortfolioRisks = warnings.sorted { $0.severity > $1.severity }
    }

    func resetDailyPeak() {
        let current = portfolio.totalEquityUSD()
        dailyPeakEquityUSD = current
        UserDefaults.standard.set(Self.dayStamp(Date()), forKey: Keys.dailyPeakDate)
        UserDefaults.standard.set(current, forKey: Keys.dailyPeakEquity)
        cooldowns.removeValue(forKey: "drawdown-daily")
        evaluatePortfolioRisks()
    }

    // MARK: 2. 短时剧烈异动 / 插针监测

    private func handleLivePriceForVolatility(assetID: String, quote: CryptoQuote) {
        guard config.volatilityEnabled, quote.price > 0 else { return }

        // 只监控用户自选或当前持仓关联的品种，避免无关榜单噪音
        let watchedIDs = Set(watchlist.favoriteAssets.map(\.id))
            .union(portfolio.positions().map(\.marketAsset.id))
        guard watchedIDs.contains(assetID) else { return }

        let now = Date()
        let windowSeconds = TimeInterval(max(config.volatilityWindowMinutes, 1) * 60)
        var history = priceSamples[assetID] ?? []

        // 至少间隔 5 秒采样一次，保持内存极低占用
        if let last = history.last, now.timeIntervalSince(last.0) < 5 {
            // 仍检查是否相对窗口最早采样已突破异动阈值
        } else {
            history.append((now, quote.price))
        }

        // 裁剪超过滑动窗口的旧采样
        let cutoff = now.addingTimeInterval(-windowSeconds)
        history.removeAll { $0.0 < cutoff }
        priceSamples[assetID] = history

        guard let oldest = history.first,
              oldest.1 > 0,
              now.timeIntervalSince(oldest.0) >= 20 else { return }

        let changePct = (quote.price - oldest.1) / oldest.1 * 100
        guard abs(changePct) >= config.volatilityThresholdPercent else { return }

        let directionWord = changePct > 0 ? "急速拉升" : "快速下挫"
        let symbol = assetID.split(separator: "-").first.map(String.init) ?? assetID
        let key = "vol-\(assetID)"
        let title = "\(symbol) \(config.volatilityWindowMinutes)分钟\(directionWord) \(MarketFormatter.changePercent(changePct))"
        let body = "\(assetID) 现价 \(MarketFormatter.price(quote.price))（\(config.volatilityWindowMinutes) 分钟前 \(MarketFormatter.price(oldest.1))）"

        fireIfAllowed(
            key: key,
            severity: .warning,
            category: "短时异动提醒",
            title: title,
            body: body,
            assetID: assetID,
            openPortfolio: false
        )
    }

    // MARK: 辅助逻辑

    private func updateDailyPeakIfNeeded(currentEquity: Double) {
        let today = Self.dayStamp(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Keys.dailyPeakDate) != today {
            dailyPeakEquityUSD = currentEquity
            defaults.set(today, forKey: Keys.dailyPeakDate)
            defaults.set(currentEquity, forKey: Keys.dailyPeakEquity)
        } else if currentEquity > dailyPeakEquityUSD {
            dailyPeakEquityUSD = currentEquity
            defaults.set(currentEquity, forKey: Keys.dailyPeakEquity)
        }
    }

    private func fireIfAllowed(
        key: String,
        severity: AlertSeverity,
        category: String,
        title: String,
        body: String,
        assetID: String?,
        openPortfolio: Bool
    ) {
        let now = Date()
        let cooldown = severity == .critical ? Self.criticalCooldownSeconds : Self.warningCooldownSeconds
        if let last = cooldowns[key], now.timeIntervalSince(last) < cooldown {
            return
        }
        cooldowns[key] = now

        dispatcher.dispatch(
            AlertPayload(
                severity: severity,
                category: category,
                title: title,
                body: body,
                assetID: assetID,
                openPortfolio: openPortfolio
            )
        )
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.config)
        }
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
