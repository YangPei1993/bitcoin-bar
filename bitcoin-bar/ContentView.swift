import AppKit
import SwiftUI

// MARK: - 面板导航与状态协调

enum PanelSection: String, CaseIterable, Identifiable {
    case market
    case portfolio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .market: return "行情"
        case .portfolio: return "资产"
        }
    }

    var systemImage: String {
        switch self {
        case .market: return "chart.line.uptrend.xyaxis"
        case .portfolio: return "wallet.bifold"
        }
    }
}

@MainActor
@Observable
final class PanelNavigationState {
    var activeSection: PanelSection = .market
    var detailAsset: CryptoAsset?
    var isPanelVisible = true
    var isPinned = false
    var isFloatingVisible = false
    var searchFocusToken = 0
    var toastMessage: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self?.toastMessage = nil
            }
        }
    }
}

// MARK: - 分组与排序模型

private enum MarketTab: Hashable {
    case favorites
    case hot
    case gainers
    case losers
    case spot
    case contract
    case custom(String)
}

private enum SortField {
    case defaultOrder
    case price
    case change24h
}

// MARK: - 主行情面板视图

struct ContentView: View {
    let hub: MarketQuoteHub
    let tickerStore: CryptoTickerStore
    let watchlist: WatchlistStore
    let alertStore: PriceAlertStore
    let portfolioStore: PortfolioStore
    let riskEngine: RiskMonitorEngine
    @Bindable var settings: AppSettings
    let aiCache: AIAnalysisCache
    @Bindable var navigation: PanelNavigationState

    let toggleFloatingWindow: () -> Void
    let openSettings: (SettingsTab) -> Void
    let onPinChanged: (Bool) -> Void
    let onDismissPanel: () -> Void

    @State private var selectedTab: MarketTab = .favorites
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sortField: SortField = .defaultOrder
    @State private var sortAscending = false
    @State private var dropTargetAssetID: String?

    // 新建 / 重命名自定义分组弹窗
    @State private var isShowingNewGroupPopover = false
    @State private var newGroupName = ""
    @State private var renamingGroup: CustomWatchGroup?
    @State private var renameGroupText = ""

    // 行内快速添加价格提醒 Sheet
    @State private var quickAlertAsset: CryptoAsset?
    @State private var quickAlertDirection: PriceAlertDirection = .above
    @State private var quickAlertPrice = ""
    @State private var quickAlertRepeating = false

    var body: some View {
        Group {
            if navigation.isPanelVisible {
                panelRootContent
            } else {
                // 面板隐藏时卸载子树，避免后台继续响应行情节流刷新消耗 CPU
                Color.clear
            }
        }
        .frame(minWidth: 400, idealWidth: 424, maxWidth: .infinity, minHeight: 540, idealHeight: 620, maxHeight: .infinity)
    }

    private var panelRootContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let asset = navigation.detailAsset {
                    AssetDetailView(
                        asset: asset,
                        hub: hub,
                        tickerStore: tickerStore,
                        watchlist: watchlist,
                        alertStore: alertStore,
                        settings: settings,
                        aiCache: aiCache,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                navigation.detailAsset = nil
                            }
                        },
                        onOpenAISettings: { openSettings(.ai) },
                        onShowToast: { navigation.showToast($0) }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    topWindowHeaderBar
                    if navigation.activeSection == .market {
                        marketListScreen
                            .transition(.opacity)
                    } else {
                        Divider()
                        PortfolioView(
                            portfolio: portfolioStore,
                            riskEngine: riskEngine,
                            settings: settings,
                            onOpenAccountSettings: { openSettings(.accounts) },
                            onOpenAlertSettings: { openSettings(.alerts) },
                            onSelectPositionAsset: { asset in
                                openDetail(for: asset)
                            },
                            onShowToast: { navigation.showToast($0) }
                        )
                        .transition(.opacity)
                    }
                }

                Divider()
                bottomStatusBar
            }

            if let toast = navigation.toastMessage {
                Text(toast)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.82), in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .padding(.bottom, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 400, idealWidth: 424, maxWidth: .infinity, minHeight: 540, idealHeight: 620, maxHeight: .infinity)
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.18), value: navigation.detailAsset?.id)
        .animation(.easeInOut(duration: 0.2), value: navigation.toastMessage)
        .onAppear {
            syncPanelDemand()
            tickerStore.prewarmSearchIndex()
        }
        .onDisappear {
            hub.setDemand([], for: "panel")
        }
        .onChange(of: selectedTab) { _, newTab in
            sortField = .defaultOrder
            if needsOverview(for: newTab) {
                Task {
                    await tickerStore.loadOverview()
                    syncPanelDemand()
                }
            } else {
                syncPanelDemand()
            }
        }
        .onChange(of: watchlist.favoriteAssets) { _, _ in
            if selectedTab == .favorites { syncPanelDemand() }
        }
        .onChange(of: watchlist.customGroups) { _, groups in
            if case .custom(let id) = selectedTab,
               groups.contains(where: { $0.id == id }) == false {
                selectedTab = .favorites
            }
            syncPanelDemand()
        }
        .onChange(of: navigation.searchFocusToken) { _, _ in
            navigation.detailAsset = nil
            navigation.activeSection = .market
            isSearchFocused = true
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                await tickerStore.search("")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard Task.isCancelled == false else { return }
            await tickerStore.search(trimmed)
        }
        .sheet(item: $quickAlertAsset) { asset in
            quickAlertSheet(for: asset)
        }
        .sheet(item: $renamingGroup) { group in
            renameGroupSheet(for: group)
        }
    }

    // MARK: 面板顶级导航条（行情 / 资产 + 窗口工具）

    private var topWindowHeaderBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PanelSection.allCases) { section in
                    let isSelected = navigation.activeSection == section
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            navigation.activeSection = section
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                            Text(section.label)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.11) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()

            // 固定窗口图钉
            topToolButton(
                systemImage: navigation.isPinned ? "pin.fill" : "pin",
                isActive: navigation.isPinned,
                help: navigation.isPinned ? "取消固定（失焦自动收起）" : "固定面板在屏幕上"
            ) {
                navigation.isPinned.toggle()
                onPinChanged(navigation.isPinned)
                navigation.showToast(navigation.isPinned ? "面板已固定" : "已取消固定")
            }

            // 桌面悬浮窗
            topToolButton(
                systemImage: "macwindow.on.rectangle",
                isActive: navigation.isFloatingVisible,
                help: "显示 / 隐藏桌面悬浮窗"
            ) {
                toggleFloatingWindow()
            }

            // 设置
            topToolButton(
                systemImage: "gearshape",
                isActive: false,
                help: "设置（⌘,）"
            ) {
                openSettings(.general)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: 市场列表主屏

    private var marketListScreen: some View {
        VStack(spacing: 0) {
            searchInputBar
            if isSearchingMode == false {
                groupTabStrip
                Divider()
                columnSortBar
            } else {
                Divider()
            }
            listContentArea
        }
        .onAppear {
            syncPanelDemand()
        }
    }

    // MARK: 全局搜索栏

    private var searchInputBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索币种、永续合约（⌘K）", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFocused)
                .onExitCommand {
                    if searchText.isEmpty == false {
                        searchText = ""
                    } else {
                        onDismissPanel()
                    }
                }

            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSearchFocused ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func topToolButton(
        systemImage: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 横向分组胶囊栏

    private var groupTabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                tabPill(title: "自选", tab: .favorites)
                tabPill(title: "热门", tab: .hot)
                tabPill(title: "涨幅", tab: .gainers)
                tabPill(title: "跌幅", tab: .losers)
                tabPill(title: "现货", tab: .spot)
                tabPill(title: "合约", tab: .contract)

                ForEach(watchlist.customGroups) { group in
                    tabPill(title: group.name, tab: .custom(group.id))
                        .contextMenu {
                            Button("重命名分组") {
                                renamingGroup = group
                                renameGroupText = group.name
                            }
                            Button("删除分组", role: .destructive) {
                                watchlist.deleteGroup(id: group.id)
                                navigation.showToast("已删除分组“\(group.name)”")
                            }
                        }
                }

                Button {
                    newGroupName = ""
                    isShowingNewGroupPopover.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .help("新建自定义分组")
                .popover(isPresented: $isShowingNewGroupPopover, arrowEdge: .bottom) {
                    newGroupPopover
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func tabPill(title: String, tab: MarketTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                selectedTab = tab
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary.opacity(0.78))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private var newGroupPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建自定义分组")
                .font(.subheadline.weight(.semibold))
            TextField("例如：AI 概念、主流观察", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { confirmCreateGroup() }

            HStack {
                Spacer()
                Button("取消") {
                    isShowingNewGroupPopover = false
                }
                Button("创建") {
                    confirmCreateGroup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private func confirmCreateGroup() {
        if let created = watchlist.createGroup(named: newGroupName) {
            selectedTab = .custom(created.id)
            navigation.showToast("已创建分组“\(created.name)”")
        }
        newGroupName = ""
        isShowingNewGroupPopover = false
    }

    // MARK: 列表排序表头

    private var columnSortBar: some View {
        HStack(spacing: 8) {
            Text("交易对")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            sortHeaderButton(title: "最新价", field: .price)
                .frame(width: 96, alignment: .trailing)

            sortHeaderButton(title: "24h 涨跌", field: .change24h)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func sortHeaderButton(title: String, field: SortField) -> some View {
        Button {
            if sortField == field {
                if sortAscending {
                    sortField = .defaultOrder
                    sortAscending = false
                } else {
                    sortAscending = true
                }
            } else {
                sortField = field
                sortAscending = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 10.5, weight: sortField == field ? .semibold : .medium))
            .foregroundStyle(sortField == field ? Color.accentColor : Color.secondary.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: 主列表区域（搜索结果 / 分组行情）

    @ViewBuilder
    private var listContentArea: some View {
        if isSearchingMode {
            searchResultsList
        } else if needsOverview(for: selectedTab) && tickerStore.isLoadingOverview && rawTabAssets.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在加载实时榜单...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let overviewError = tickerStore.overviewError, needsOverview(for: selectedTab), rawTabAssets.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(overviewError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task {
                        await tickerStore.loadOverview(force: true)
                        syncPanelDemand()
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedAssets.isEmpty {
            emptyTabState
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    let canDragReorder = selectedTab == .favorites && sortField == .defaultOrder
                    ForEach(Array(displayedAssets.enumerated()), id: \.element.id) { index, asset in
                        let row = MarketQuoteRowView(
                            asset: asset,
                            quote: hub.quotes[asset.id],
                            flash: hub.flashes[asset.id],
                            isFavorite: watchlist.isFavorite(asset),
                            isMenuBarAsset: settings.menuBarAsset == asset,
                            hasActiveAlert: alertStore.alerts(for: asset).contains(where: \.isEnabled),
                            showsVolumeSubtitle: selectedTab == .hot || selectedTab == .gainers || selectedTab == .losers,
                            isDropTargeted: dropTargetAssetID == asset.id,
                            settings: settings,
                            onSelect: {
                                openDetail(for: asset)
                            },
                            onToggleFavorite: {
                                let added = watchlist.toggleFavorite(asset)
                                navigation.showToast(added ? "已加入自选" : "已移出自选")
                            }
                        )
                        .contextMenu {
                            rowContextMenu(for: asset, index: index)
                        }

                        if canDragReorder {
                            row
                                .draggable(asset.id)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let sourceID = items.first else { return false }
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        watchlist.moveFavorite(sourceID: sourceID, toTargetID: asset.id)
                                    }
                                    return true
                                } isTargeted: { targeted in
                                    dropTargetAssetID = targeted ? asset.id : (dropTargetAssetID == asset.id ? nil : dropTargetAssetID)
                                }
                        } else {
                            row
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 搜索结果列表

    private var searchResultsList: some View {
        Group {
            if tickerStore.isSearching && tickerStore.searchResults.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tickerStore.hasLoadedSearchIndex ? "搜索中..." : "首次拉取全市场交易对索引...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = tickerStore.searchError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tickerStore.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("未找到匹配 “\(searchText)” 的交易对")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tickerStore.searchResults) { asset in
                            SearchResultRow(
                                asset: asset,
                                quote: hub.quotes[asset.id],
                                isFavorite: watchlist.isFavorite(asset),
                                settings: settings,
                                onSelect: {
                                    searchText = ""
                                    openDetail(for: asset)
                                },
                                onToggleFavorite: {
                                    let added = watchlist.toggleFavorite(asset)
                                    navigation.showToast(added ? "已加入自选" : "已移出自选")
                                }
                            )
                            .contextMenu {
                                rowContextMenu(for: asset, index: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: 空状态引导

    private var emptyTabState: some View {
        VStack(spacing: 10) {
            Image(systemName: selectedTab == .favorites ? "star" : "folder")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(selectedTab == .favorites ? "自选列表为空" : "该分组暂无币种")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(selectedTab == .favorites ? "点击顶部搜索框（⌘K）或在其他榜单点击星标添加自选。" : "在任意行情行右键选择“加入自定义分组”即可添加。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 行右键菜单

    @ViewBuilder
    private func rowContextMenu(for asset: CryptoAsset, index: Int) -> some View {
        let isFav = watchlist.isFavorite(asset)

        Button(isFav ? "移出自选" : "加入自选") {
            let added = watchlist.toggleFavorite(asset)
            navigation.showToast(added ? "已加入自选" : "已移出自选")
        }

        if selectedTab == .favorites && sortField == .defaultOrder {
            if index > 0 {
                Button("置顶到自选首位") {
                    watchlist.pinFavoriteToTop(asset)
                }
                Button("上移一位") {
                    watchlist.moveFavorite(asset, by: -1)
                }
            }
            if index < displayedAssets.count - 1 {
                Button("下移一位") {
                    watchlist.moveFavorite(asset, by: 1)
                }
            }
        }

        if case .custom(let groupID) = selectedTab {
            Button("从此分组移除", role: .destructive) {
                watchlist.remove(asset, fromGroup: groupID)
            }
        } else if watchlist.customGroups.isEmpty == false {
            Menu("加入自定义分组") {
                ForEach(watchlist.customGroups) { group in
                    let inGroup = watchlist.contains(asset, inGroup: group.id)
                    Button {
                        let added = watchlist.toggle(asset, inGroup: group.id)
                        navigation.showToast(added ? "已加入“\(group.name)”" : "已从“\(group.name)”移除")
                    } label: {
                        Text(inGroup ? "✓ \(group.name)" : group.name)
                    }
                }
            }
        }

        Divider()

        Button("设为菜单栏显示") {
            settings.menuBarAsset = asset
            navigation.showToast("菜单栏已切换为 \(asset.symbol)")
        }

        Button("添加价格提醒...") {
            openQuickAlert(for: asset)
        }

        Divider()

        if let quote = hub.quotes[asset.id] {
            Button("复制最新价格（\(MarketFormatter.price(quote.price))）") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MarketFormatter.price(quote.price), forType: .string)
                navigation.showToast("已复制价格")
            }
        }

        if let url = asset.okxTradeURL {
            Button("在 OKX 中查看") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 底部极简状态条

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                Text(hub.connectionState.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let updated = hub.lastUpdatedAt {
                    Text("· \(MarketFormatter.clockTime(updated))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if riskEngine.activePortfolioRisks.isEmpty == false {
                let hasCritical = riskEngine.activePortfolioRisks.contains { $0.severity == .critical }
                Button {
                    navigation.detailAsset = nil
                    navigation.activeSection = .portfolio
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: hasCritical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("\(riskEngine.activePortfolioRisks.count) 风险")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(hasCritical ? .white : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(hasCritical ? MarketColors.red : Color.orange.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("存在活跃仓位风险预警，点击查看资产页")
            }

            let totalAlerts = alertStore.activeAlertCount + portfolioStore.activeBalanceAlertCount
            if totalAlerts > 0 {
                Button {
                    openSettings(.alerts)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9))
                        Text("\(totalAlerts)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("查看已启用的价格与余额提醒")
            }

            Button {
                Task {
                    if navigation.activeSection == .portfolio {
                        await portfolioStore.refreshAll()
                    } else {
                        if needsOverview(for: selectedTab) {
                            await tickerStore.loadOverview(force: true)
                        }
                        await hub.refreshNow()
                        if hub.connectionState.isHealthy == false {
                            hub.reconnectNow()
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(hub.isRefreshingSnapshot || portfolioStore.isRefreshing)
            .help("刷新实时行情 / 同步资产（⌘R）")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.ultraThinMaterial)
    }

    // MARK: 弹窗 Sheet（快速提醒 / 重命名分组）

    private func quickAlertSheet(for asset: CryptoAsset) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CoinAvatar(symbol: asset.symbol, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("为 \(asset.pairLabel) 添加价格提醒")
                        .font(.headline)
                    if let quote = hub.quotes[asset.id] {
                        Text("当前价格：\(MarketFormatter.price(quote.price))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Picker("条件", selection: $quickAlertDirection) {
                    ForEach(PriceAlertDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                TextField("输入目标价格", text: $quickAlertPrice)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .onSubmit {
                        submitQuickAlert(for: asset)
                    }
            }

            Toggle("到达后重复提醒（5 分钟冷却）", isOn: $quickAlertRepeating)
                .font(.caption)

            HStack {
                Spacer()
                Button("取消") {
                    quickAlertAsset = nil
                }
                Button("确认添加") {
                    submitQuickAlert(for: asset)
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedQuickAlertPrice == nil)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func renameGroupSheet(for group: CustomWatchGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名分组")
                .font(.headline)
            TextField("分组名称", text: $renameGroupText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    renamingGroup = nil
                }
                Button("保存") {
                    watchlist.renameGroup(id: group.id, to: renameGroupText)
                    renamingGroup = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameGroupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 280)
    }

    // MARK: 数据源与辅助计算

    private var isSearchingMode: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var rawTabAssets: [CryptoAsset] {
        switch selectedTab {
        case .favorites:
            return watchlist.favoriteAssets
        case .hot:
            return tickerStore.hotAssets
        case .gainers:
            return tickerStore.gainerAssets
        case .losers:
            return tickerStore.loserAssets
        case .spot:
            return tickerStore.featuredSpotAssets
        case .contract:
            return tickerStore.featuredContractAssets
        case .custom(let id):
            return watchlist.customGroups.first(where: { $0.id == id })?.assets ?? []
        }
    }

    private var displayedAssets: [CryptoAsset] {
        let base = rawTabAssets
        guard sortField != .defaultOrder else { return base }

        return base.sorted { lhs, rhs in
            let lQuote = hub.quotes[lhs.id]
            let rQuote = hub.quotes[rhs.id]
            let lVal: Double
            let rVal: Double
            switch sortField {
            case .price:
                lVal = lQuote?.price ?? -Double.greatestFiniteMagnitude
                rVal = rQuote?.price ?? -Double.greatestFiniteMagnitude
            case .change24h:
                lVal = lQuote?.changePercentage24h ?? -Double.greatestFiniteMagnitude
                rVal = rQuote?.changePercentage24h ?? -Double.greatestFiniteMagnitude
            case .defaultOrder:
                return false
            }
            return sortAscending ? (lVal < rVal) : (lVal > rVal)
        }
    }

    private var statusDotColor: Color {
        switch hub.connectionState {
        case .live: return MarketColors.green
        case .offline: return MarketColors.red
        default: return .orange
        }
    }

    private func needsOverview(for tab: MarketTab) -> Bool {
        tab == .hot || tab == .gainers || tab == .losers
    }

    private func syncPanelDemand() {
        hub.setDemand(Array(rawTabAssets.prefix(30)), for: "panel")
    }

    private func openDetail(for asset: CryptoAsset) {
        withAnimation(.easeInOut(duration: 0.18)) {
            navigation.detailAsset = asset
        }
    }

    private var parsedQuickAlertPrice: Double? {
        let cleaned = quickAlertPrice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        return value
    }

    private func submitQuickAlert(for asset: CryptoAsset) {
        guard let value = parsedQuickAlertPrice else { return }
        alertStore.addAlert(
            asset: asset,
            direction: quickAlertDirection,
            targetPrice: value,
            isRepeating: quickAlertRepeating
        )
        navigation.showToast("已添加 \(asset.symbol) 价格提醒")
        quickAlertAsset = nil
    }

    private func openQuickAlert(for asset: CryptoAsset) {
        quickAlertDirection = .above
        quickAlertRepeating = false
        if let price = hub.quotes[asset.id]?.price {
            quickAlertPrice = MarketFormatter.price(price * 1.02, includeSymbol: false).replacingOccurrences(of: ",", with: "")
        } else {
            quickAlertPrice = ""
        }
        quickAlertAsset = asset
    }
}

// MARK: - 消费级行情列表行

private struct MarketQuoteRowView: View {
    let asset: CryptoAsset
    let quote: CryptoQuote?
    let flash: PriceTickFlash?
    let isFavorite: Bool
    let isMenuBarAsset: Bool
    let hasActiveAlert: Bool
    let showsVolumeSubtitle: Bool
    let isDropTargeted: Bool
    let settings: AppSettings
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovering = false
    @State private var flashColor: Color?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    CoinAvatar(symbol: asset.symbol, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(asset.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text("/\(asset.quoteCurrency)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)

                            if let badge = asset.kindBadge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(Color.accentColor)
                            }

                            if isMenuBarAsset {
                                Image(systemName: "menubar.rectangle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.accentColor)
                                    .help("当前固定在菜单栏")
                            }

                            if hasActiveAlert {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.orange)
                                    .help("已设置价格提醒")
                            }
                        }
                        .lineLimit(1)

                        Text(subtitleText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    // 实时价格
                    Text(quote.map { MarketFormatter.price($0.price) } ?? "--")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(minWidth: 82, alignment: .trailing)

                    // 24h 涨跌幅色块徽章
                    changeBadge
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 悬停或已收藏时展示星标
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFavorite ? .orange : .secondary.opacity(0.65))
                    .frame(width: 20, height: 20)
                    .opacity(isFavorite || isHovering ? 1 : 0.28)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "移出自选" : "加入自选")
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .onHover { isHovering = $0 }
        .onChange(of: flash?.sequence) { _, _ in
            guard let flash else { return }
            flashColor = flash.direction == .up ? settings.upColor : settings.downColor
            withAnimation(.easeOut(duration: 0.65)) {
                flashColor = nil
            }
        }
    }

    @ViewBuilder
    private var changeBadge: some View {
        if let quote {
            let color = settings.changeColor(for: quote.changePercentage24h)
            Text(MarketFormatter.changePercent(quote.changePercentage24h))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 68, height: 24)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Text("--")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 68, height: 24)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var subtitleText: String {
        if showsVolumeSubtitle, let quote, quote.volumeCurrency24h > 0 {
            return "24h 额 \(MarketFormatter.compactVolume(quote.volumeCurrency24h, isCurrency: true))"
        }
        return asset.name
    }

    private var rowBackground: Color {
        if let flashColor {
            return flashColor.opacity(0.14)
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }
}

// MARK: - 搜索结果行

private struct SearchResultRow: View {
    let asset: CryptoAsset
    let quote: CryptoQuote?
    let isFavorite: Bool
    let settings: AppSettings
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    CoinAvatar(symbol: asset.symbol, size: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(asset.pairLabel)
                                .font(.system(size: 12.5, weight: .semibold))
                            if let badge = asset.kindBadge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(asset.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let quote {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(MarketFormatter.price(quote.price))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text(MarketFormatter.changePercent(quote.changePercentage24h))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(settings.changeColor(for: quote.changePercentage24h))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorite ? .orange : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }
}
