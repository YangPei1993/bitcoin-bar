import Charts
import SwiftUI

// MARK: - 图表样式

nonisolated enum DetailChartStyle: String, CaseIterable, Identifiable, Sendable {
    case candle
    case area

    var id: String { rawValue }

    var label: String {
        switch self {
        case .candle: return "K线"
        case .area: return "分时"
        }
    }
}

// MARK: - 24h 价格区间条

struct DayRangeBar: View {
    let low: Double
    let high: Double
    let current: Double
    let accent: Color

    var body: some View {
        let span = max(high - low, 0.00000001)
        let ratio = min(max((current - low) / span, 0), 1)

        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let knobX = max(4, min(width - 4, width * ratio))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)

                    Capsule()
                        .fill(accent.opacity(0.75))
                        .frame(width: max(4, knobX), height: 4)

                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .offset(x: knobX - 4)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)

            HStack {
                Text("24h 低 \(MarketFormatter.price(low))")
                Spacer()
                Text("24h 高 \(MarketFormatter.price(high))")
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 专业交互式行情图表（K 线 / 分时 / 均线 / 十字光标 / 缩放平移）

struct InteractiveMarketChart: View {
    let klines: [KlinePoint]
    let interval: KlineInterval
    let isLoading: Bool
    let errorMessage: String?
    let settings: AppSettings
    let onRetry: () -> Void

    @State private var chartStyle: DetailChartStyle = .candle
    @State private var showMA = true
    @State private var visibleCount = 56
    @State private var trailingOffset = 0
    @State private var dragStartOffset = 0
    @State private var magnifyStartCount = 56
    @State private var hoveredPoint: KlinePoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartToolbar
            crosshairHUD

            if isLoading && klines.isEmpty {
                loadingPlaceholder
            } else if let errorMessage, klines.isEmpty {
                errorPlaceholder(errorMessage)
            } else if visibleKlines.isEmpty {
                loadingPlaceholder
            } else {
                VStack(spacing: 4) {
                    mainPriceChart
                    volumeSubChart
                }
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
            }
        }
        .onChange(of: interval) { _, _ in
            resetViewport()
        }
    }

    // MARK: 顶部工具条

    private var chartToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DetailChartStyle.allCases) { style in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            chartStyle = style
                        }
                    } label: {
                        Text(style.label)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(chartStyle == style ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(chartStyle == style ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))

            if chartStyle == .candle {
                Button {
                    showMA.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text("MA")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(showMA ? Color.orange.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(showMA ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("显示/隐藏 MA7 与 MA25 均线")
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    zoom(by: 0.78)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("放大")

                Button {
                    zoom(by: 1.28)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("缩小")

                if trailingOffset > 0 {
                    Button("最新") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            trailingOffset = 0
                            dragStartOffset = 0
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 十字光标 OHLCV 信息条

    private var crosshairHUD: some View {
        Group {
            if let point = hoveredPoint ?? visibleKlines.last {
                let change = point.open == 0 ? 0 : ((point.close - point.open) / point.open) * 100
                let isHovered = hoveredPoint != nil
                HStack(spacing: 8) {
                    Text(MarketFormatter.chartTimestamp(point.openTime, interval: interval))
                        .foregroundStyle(isHovered ? .primary : .secondary)

                    hudItem("开", MarketFormatter.price(point.open, includeSymbol: false))
                    hudItem("高", MarketFormatter.price(point.high, includeSymbol: false))
                    hudItem("低", MarketFormatter.price(point.low, includeSymbol: false))
                    hudItem("收", MarketFormatter.price(point.close, includeSymbol: false))

                    Spacer(minLength: 0)

                    Text(MarketFormatter.changePercent(change))
                        .foregroundStyle(settings.changeColor(for: change))
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                Text("悬停图表查看单根 K 线详情")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 15)
    }

    private func hudItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: 主图（K 线 / 分时面积）

    private var mainPriceChart: some View {
        let series = visibleKlines
        let ma7Series = showMA && chartStyle == .candle ? movingAveragePoints(period: 7) : []
        let ma25Series = showMA && chartStyle == .candle ? movingAveragePoints(period: 25) : []
        let areaTrendColor: Color = {
            guard let first = series.first, let last = series.last else { return settings.upColor }
            return last.close >= first.close ? settings.upColor : settings.downColor
        }()

        return Chart {
            if chartStyle == .candle {
                ForEach(series) { point in
                    RuleMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("低", point.low),
                        yEnd: .value("高", point.high)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(settings.candleColor(for: point))

                    RectangleMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("下", bodyLower(for: point)),
                        yEnd: .value("上", bodyUpper(for: point)),
                        width: .fixed(candleWidth)
                    )
                    .foregroundStyle(settings.candleColor(for: point))
                    .cornerRadius(0.8)
                }

                ForEach(ma7Series) { item in
                    LineMark(
                        x: .value("时间", item.time),
                        y: .value("MA7", item.value),
                        series: .value("均线", "MA7")
                    )
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.1))
                }

                ForEach(ma25Series) { item in
                    LineMark(
                        x: .value("时间", item.time),
                        y: .value("MA25", item.value),
                        series: .value("均线", "MA25")
                    )
                    .foregroundStyle(Color.purple.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.1))
                }
            } else {
                ForEach(series) { point in
                    AreaMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("底", yDomain.lowerBound),
                        yEnd: .value("收", point.close)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [areaTrendColor.opacity(0.28), areaTrendColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("时间", point.openTime),
                        y: .value("收", point.close)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .foregroundStyle(areaTrendColor)
                }
            }

            // 最新价虚线
            if let last = series.last {
                RuleMark(y: .value("最新价", last.close))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }

            // 鼠标悬停十字光标
            if let hoveredPoint {
                RuleMark(x: .value("悬停时间", hoveredPoint.openTime))
                    .foregroundStyle(Color.primary.opacity(0.32))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 2]))

                RuleMark(y: .value("悬停价", hoveredPoint.close))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 2]))

                PointMark(
                    x: .value("悬停时间", hoveredPoint.openTime),
                    y: .value("悬停价", hoveredPoint.close)
                )
                .symbolSize(26)
                .foregroundStyle(settings.candleColor(for: hoveredPoint))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(MarketFormatter.price(price, includeSymbol: false))
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let originX = geometry[plotFrame].origin.x
                            let xInPlot = location.x - originX
                            if let hoveredDate: Date = proxy.value(atX: xInPlot) {
                                hoveredPoint = nearestPoint(to: hoveredDate, in: series)
                            }
                        case .ended:
                            hoveredPoint = nil
                        }
                    }
            }
        }
        .frame(height: 176)
    }

    // MARK: 成交量副图

    private var volumeSubChart: some View {
        Chart(visibleKlines) { point in
            BarMark(
                x: .value("时间", point.openTime),
                y: .value("量", point.volume),
                width: .fixed(max(candleWidth - 0.8, 1.5))
            )
            .foregroundStyle(settings.candleColor(for: point).opacity(0.45))
        }
        .chartXScale(domain: xDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(MarketFormatter.chartTimestamp(date, interval: interval))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 44)
    }

    // MARK: 占位视图

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary.opacity(0.35))
            .frame(height: 224)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载 K 线行情...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func errorPlaceholder(_ message: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary.opacity(0.35))
            .frame(height: 224)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新加载", action: onRetry)
                        .controlSize(.small)
                }
            }
    }

    // MARK: 视图窗口计算与手势

    private var visibleRange: Range<Int> {
        guard klines.isEmpty == false else { return 0..<0 }
        let count = min(max(visibleCount, 16), klines.count)
        let maxOffset = max(klines.count - count, 0)
        let clampedOffset = min(max(trailingOffset, 0), maxOffset)
        let end = klines.count - clampedOffset
        let start = max(end - count, 0)
        return start..<end
    }

    private var visibleKlines: [KlinePoint] {
        let range = visibleRange
        guard range.lowerBound < range.upperBound else { return [] }
        return Array(klines[range])
    }

    private var candleWidth: CGFloat {
        let count = max(visibleKlines.count, 1)
        return min(max(240.0 / CGFloat(count), 2.0), 8.5)
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = visibleKlines.first, let last = visibleKlines.last else {
            let now = Date()
            return now...now.addingTimeInterval(Double(interval.rawValue))
        }
        let step = Double(interval.rawValue)
        return first.openTime.addingTimeInterval(-step * 0.6)...last.openTime.addingTimeInterval(step * 0.8)
    }

    private var yDomain: ClosedRange<Double> {
        guard let minVal = visibleKlines.map(\.low).min(),
              let maxVal = visibleKlines.map(\.high).max() else {
            return 0...1
        }
        let span = max(maxVal - minVal, maxVal * 0.0005, 0.00000001)
        let padding = span * 0.10
        return (minVal - padding)...(maxVal + padding)
    }

    private var minBodyHeight: Double {
        (yDomain.upperBound - yDomain.lowerBound) * 0.005
    }

    private func bodyLower(for point: KlinePoint) -> Double {
        let low = min(point.open, point.close)
        let high = max(point.open, point.close)
        guard high - low < minBodyHeight else { return low }
        return (low + high) / 2 - minBodyHeight / 2
    }

    private func bodyUpper(for point: KlinePoint) -> Double {
        let low = min(point.open, point.close)
        let high = max(point.open, point.close)
        guard high - low < minBodyHeight else { return high }
        return (low + high) / 2 + minBodyHeight / 2
    }

    private struct MAPoint: Identifiable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    private func movingAveragePoints(period: Int) -> [MAPoint] {
        guard klines.count >= period else { return [] }
        let range = visibleRange
        var points: [MAPoint] = []
        var windowSum = 0.0

        for idx in 0..<klines.count {
            windowSum += klines[idx].close
            if idx >= period {
                windowSum -= klines[idx - period].close
            }
            if idx >= period - 1 && range.contains(idx) {
                points.append(MAPoint(time: klines[idx].openTime, value: windowSum / Double(period)))
            }
        }
        return points
    }

    private func nearestPoint(to date: Date, in points: [KlinePoint]) -> KlinePoint? {
        points.min {
            abs($0.openTime.timeIntervalSince(date)) < abs($1.openTime.timeIntervalSince(date))
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let stepPixels = max(260.0 / Double(max(visibleKlines.count, 1)), 3.0)
                let deltaCandles = Int((Double(value.translation.width) / stepPixels).rounded())
                let maxOffset = max(klines.count - min(max(visibleCount, 16), klines.count), 0)
                trailingOffset = min(max(dragStartOffset + deltaCandles, 0), maxOffset)
            }
            .onEnded { _ in
                dragStartOffset = trailingOffset
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard scale > 0 else { return }
                let next = Int((Double(magnifyStartCount) / Double(scale)).rounded())
                visibleCount = min(max(next, 16), min(max(klines.count, 16), 180))
            }
            .onEnded { _ in
                magnifyStartCount = visibleCount
            }
    }

    private func zoom(by factor: Double) {
        let next = Int((Double(visibleCount) * factor).rounded())
        visibleCount = min(max(next, 16), min(max(klines.count, 16), 180))
        magnifyStartCount = visibleCount
    }

    private func resetViewport() {
        visibleCount = 56
        trailingOffset = 0
        dragStartOffset = 0
        magnifyStartCount = 56
        hoveredPoint = nil
    }
}
