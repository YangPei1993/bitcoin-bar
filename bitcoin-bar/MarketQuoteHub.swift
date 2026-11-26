import AppKit
import Foundation
import Network

// MARK: - 连接状态与价格跳动模型

nonisolated enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int)
    case fallbackPolling
    case offline

    var label: String {
        switch self {
        case .idle:
            return "等待行情"
        case .connecting:
            return "连接实时行情..."
        case .live:
            return "实时推送"
        case .reconnecting(let attempt):
            return "重连中（第 \(attempt) 次）"
        case .fallbackPolling:
            return "快照轮询中"
        case .offline:
            return "网络已断开"
        }
    }

    var isHealthy: Bool {
        self == .live
    }
}

nonisolated enum PriceDirection: Equatable, Sendable {
    case up
    case down
}

nonisolated struct PriceTickFlash: Equatable, Sendable {
    let direction: PriceDirection
    let sequence: Int
}

// MARK: - 统一行情中枢

/// 全局唯一行情中枢：
/// - 汇总菜单栏、悬浮窗、行情列表、详情页、价格提醒的品种需求，合并去重后仅维护一条 WS
/// - 300ms 节流合并提交到 UI，兼顾顺滑与低耗电
/// - 断线指数退避重连 + REST 批量兜底轮询 + 断网/休眠唤醒自动恢复
@MainActor
@Observable
final class MarketQuoteHub {
    private static let maxSubscribedAssets = 60

    private(set) var quotes: [String: CryptoQuote] = [:]
    private(set) var flashes: [String: PriceTickFlash] = [:]
    private(set) var connectionState: ConnectionState = .idle
    private(set) var lastUpdatedAt: Date?
    private(set) var isRefreshingSnapshot = false

    @ObservationIgnored private let service: OKXMarketDataService
    @ObservationIgnored private var demands: [String: [CryptoAsset]] = [:]
    @ObservationIgnored private var activeAssets: [CryptoAsset] = []
    @ObservationIgnored private var activeAssetIDs: [String] = []
    @ObservationIgnored private var pendingQuotes: [String: CryptoQuote] = [:]
    @ObservationIgnored private var listeners: [(String, CryptoQuote) -> Void] = []
    @ObservationIgnored private var flashSequence = 0

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackPollTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var isNetworkAvailable = true
    @ObservationIgnored private var isStarted = false

    init(service: OKXMarketDataService = OKXMarketDataService()) {
        self.service = service
    }

    func start() {
        guard isStarted == false else { return }
        isStarted = true
        setupSystemMonitors()
        startFlushLoop()
        startFallbackPollLoop()
        rebuildStreamIfNeeded(force: true)
    }

    func stop() {
        isStarted = false
        streamTask?.cancel()
        fallbackPollTask?.cancel()
        flushTask?.cancel()
        snapshotTask?.cancel()
        streamTask = nil
        fallbackPollTask = nil
        flushTask = nil
        snapshotTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        connectionState = .idle
    }

    /// 订阅实时行情变化（不经过 300ms UI 节流，用于价格提醒与 K 线实时合成）
    func addListener(_ listener: @escaping (String, CryptoQuote) -> Void) {
        listeners.append(listener)
    }

    /// 按业务来源声明需要的品种列表（如 "menubar" / "floating" / "panel" / "detail" / "alerts"）
    func setDemand(_ assets: [CryptoAsset], for source: String) {
        demands[source] = assets
        recomputeActiveAssets()
    }

    /// 注入外部已拉取的行情（例如市场榜单接口顺带返回的全量价格）
    func ingest(_ incoming: [String: CryptoQuote]) {
        guard incoming.isEmpty == false else { return }
        applyBatch(incoming, notifyListeners: true)
    }

    /// 立即刷新当前所有订阅品种的快照
    func refreshNow() async {
        let targets = activeAssets
        guard targets.isEmpty == false else { return }
        isRefreshingSnapshot = true
        defer { isRefreshingSnapshot = false }

        let fetched = await service.fetchQuotes(for: targets)
        if fetched.isEmpty == false {
            applyBatch(fetched, notifyListeners: true)
        }
    }

    /// 手动重连实时推送
    func reconnectNow() {
        ProviderHealth.shared.markOKXHealthy()
        rebuildStreamIfNeeded(force: true)
        Task { await refreshNow() }
    }

    // MARK: 需求合并与订阅调度

    private func recomputeActiveAssets() {
        // 优先级：菜单栏 > 详情 > 价格提醒 > 悬浮窗 > 面板列表
        let priorityOrder = ["menubar", "detail", "alerts", "floating", "panel"]
        var merged: [CryptoAsset] = []
        var seen = Set<String>()

        for key in priorityOrder {
            for asset in demands[key] ?? [] where seen.insert(asset.id).inserted {
                merged.append(asset)
                if merged.count >= Self.maxSubscribedAssets { break }
            }
            if merged.count >= Self.maxSubscribedAssets { break }
        }

        for (key, list) in demands where priorityOrder.contains(key) == false {
            for asset in list where seen.insert(asset.id).inserted {
                merged.append(asset)
                if merged.count >= Self.maxSubscribedAssets { break }
            }
            if merged.count >= Self.maxSubscribedAssets { break }
        }

        let newIDs = merged.map(\.id).sorted()
        activeAssets = merged

        // 立即为缺失报价的新增品种补拉一次快照，确保界面切换秒出数字
        let missingAssets = merged.filter { quotes[$0.id] == nil }
        if missingAssets.isEmpty == false, isStarted {
            scheduleSnapshot(for: missingAssets)
        }

        guard newIDs != activeAssetIDs else { return }
        activeAssetIDs = newIDs
        if isStarted {
            rebuildStreamIfNeeded(force: true)
        }
    }

    private func scheduleSnapshot(for assets: [CryptoAsset]) {
        snapshotTask?.cancel()
        let service = service
        snapshotTask = Task { [weak self] in
            let fetched = await service.fetchQuotes(for: assets)
            guard Task.isCancelled == false, let self else { return }
            if fetched.isEmpty == false {
                self.applyBatch(fetched, notifyListeners: true)
            }
        }
    }

    private func rebuildStreamIfNeeded(force: Bool) {
        guard isStarted else { return }
        if force {
            streamTask?.cancel()
            streamTask = nil
        }

        guard activeAssets.isEmpty == false else {
            connectionState = .idle
            return
        }

        guard isNetworkAvailable else {
            connectionState = .offline
            return
        }

        let subscribedAssets = activeAssets
        let service = service
        connectionState = .connecting

        // 首屏兜底：并发拉一次最新快照，避免等待 WS 首次推送前显示 --
        scheduleSnapshot(for: subscribedAssets)

        streamTask = Task { [weak self] in
            var attempt = 0

            while Task.isCancelled == false {
                guard let self else { return }
                if attempt == 0 {
                    self.connectionState = .connecting
                } else {
                    self.connectionState = .reconnecting(attempt: attempt)
                }

                let startTime = Date()
                do {
                    try await service.streamQuotes(for: subscribedAssets) { assetID, quote in
                        await MainActor.run { [weak self] in
                            self?.enqueueLiveQuote(assetID: assetID, quote: quote)
                        }
                    }
                    // 正常结束也视为需要重连
                    attempt += 1
                } catch is CancellationError {
                    return
                } catch {
                    // 如果连接曾稳定维持超过 20 秒，重置退避计数
                    if Date().timeIntervalSince(startTime) > 20 {
                        attempt = 1
                    } else {
                        attempt += 1
                    }
                }

                guard Task.isCancelled == false else { return }

                if self.isNetworkAvailable == false {
                    self.connectionState = .offline
                    return
                }

                // 指数退避（1s → 2s → 4s → 8s → 15s → 30s）叠加随机抖动
                let baseDelay = min(pow(2.0, Double(max(attempt - 1, 0))), 30.0)
                let jitter = Double.random(in: 0...0.8)
                self.connectionState = attempt >= 3 ? .fallbackPolling : .reconnecting(attempt: attempt)
                try? await Task.sleep(for: .seconds(baseDelay + jitter))
            }
        }
    }

    // MARK: 节流批量刷新与兜底轮询

    private func enqueueLiveQuote(assetID: String, quote: CryptoQuote) {
        if connectionState != .live {
            connectionState = .live
        }
        pendingQuotes[assetID] = quote
        for listener in listeners {
            listener(assetID, quote)
        }
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(300))
                guard Task.isCancelled == false, let self else { return }
                self.flushPendingQuotes()
            }
        }
    }

    private func flushPendingQuotes() {
        guard pendingQuotes.isEmpty == false else { return }
        let batch = pendingQuotes
        pendingQuotes.removeAll(keepingCapacity: true)
        applyBatch(batch, notifyListeners: false)
    }

    private func applyBatch(_ batch: [String: CryptoQuote], notifyListeners: Bool) {
        var latestDate = lastUpdatedAt
        for (assetID, newQuote) in batch {
            if let oldQuote = quotes[assetID], oldQuote.price != newQuote.price {
                flashSequence &+= 1
                flashes[assetID] = PriceTickFlash(
                    direction: newQuote.price > oldQuote.price ? .up : .down,
                    sequence: flashSequence
                )
            }
            quotes[assetID] = newQuote
            if let current = latestDate {
                if newQuote.updatedAt > current { latestDate = newQuote.updatedAt }
            } else {
                latestDate = newQuote.updatedAt
            }

            if notifyListeners {
                for listener in listeners {
                    listener(assetID, newQuote)
                }
            }
        }
        lastUpdatedAt = latestDate ?? Date()
    }

    /// WS 未处于健康实时推送态时，每 8 秒执行一次 REST 批量轮询兜底
    private func startFallbackPollLoop() {
        fallbackPollTask?.cancel()
        fallbackPollTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(8))
                guard Task.isCancelled == false, let self else { return }
                guard self.isNetworkAvailable,
                      self.activeAssets.isEmpty == false,
                      self.connectionState != .live else { continue }

                let fetched = await self.service.fetchQuotes(for: self.activeAssets)
                guard Task.isCancelled == false else { return }
                if fetched.isEmpty == false {
                    self.applyBatch(fetched, notifyListeners: true)
                }
            }
        }
    }

    // MARK: 网络状态与睡眠唤醒监听

    private func setupSystemMonitors() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available
                if available == false {
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    self.connectionState = .offline
                } else if wasAvailable == false {
                    // 网络恢复，清除降级标记并立即重连
                    ProviderHealth.shared.markOKXHealthy()
                    self.rebuildStreamIfNeeded(force: true)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.paul.bitcoin-bar.network-monitor"))
        pathMonitor = monitor

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                ProviderHealth.shared.markOKXHealthy()
                self.rebuildStreamIfNeeded(force: true)
            }
        }
    }
}
