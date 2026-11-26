import SwiftUI

// MARK: - 主动风控规则配置卡片（嵌入「设置 → 提醒与风控」）

struct RiskRulesSettingsSection: View {
    @Bindable var riskEngine: RiskMonitorEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("主动风控预警（实时监控）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                // 1. 强平距离预警
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("合约强平距离预警（P0 极危 / P1 预警）", isOn: $riskEngine.config.liquidationEnabled)
                        .font(.subheadline.weight(.medium))

                    if riskEngine.config.liquidationEnabled {
                        HStack(spacing: 14) {
                            compactPercentStepper(
                                title: "预警线",
                                value: $riskEngine.config.liquidationWarningPercent,
                                range: 3...40,
                                step: 1
                            )
                            compactPercentStepper(
                                title: "极危线",
                                value: $riskEngine.config.liquidationCriticalPercent,
                                range: 1...25,
                                step: 1
                            )
                        }
                        Text("当 |标记价 - 强平价| ÷ 标记价 低于阈值时立即报警，极危线将触发最高级强推送。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // 2. 单仓浮亏预警
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("单仓浮亏 / ROE 预警（P1）", isOn: $riskEngine.config.positionLossEnabled)
                        .font(.subheadline.weight(.medium))

                    if riskEngine.config.positionLossEnabled {
                        HStack(spacing: 14) {
                            compactPercentStepper(
                                title: "亏损 ROE ≥",
                                value: $riskEngine.config.positionLossROEPercent,
                                range: 5...95,
                                step: 5
                            )
                            HStack(spacing: 4) {
                                Text("或浮亏额 ≥ $")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0=关闭", value: $riskEngine.config.positionLossUSD, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 68)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }

                Divider()

                // 3. 当日净值回撤预警
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("账户当日净值回撤预警（P0 极危）", isOn: $riskEngine.config.drawdownEnabled)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if riskEngine.dailyPeakEquityUSD > 0 {
                            Button("重置今日峰值") {
                                riskEngine.resetDailyPeak()
                            }
                            .font(.caption2)
                            .controlSize(.mini)
                        }
                    }

                    if riskEngine.config.drawdownEnabled {
                        HStack(spacing: 12) {
                            compactPercentStepper(
                                title: "较今日峰值回撤 ≥",
                                value: $riskEngine.config.drawdownThresholdPercent,
                                range: 2...50,
                                step: 1
                            )
                            if riskEngine.dailyPeakEquityUSD > 0 {
                                Text("今日峰值 \(MarketFormatter.price(riskEngine.dailyPeakEquityUSD))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Divider()

                // 4. 短时剧烈异动 / 插针预警
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("自选与持仓短时剧烈异动 / 插针提醒（P1）", isOn: $riskEngine.config.volatilityEnabled)
                        .font(.subheadline.weight(.medium))

                    if riskEngine.config.volatilityEnabled {
                        HStack(spacing: 14) {
                            HStack(spacing: 4) {
                                Text("时间窗口")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $riskEngine.config.volatilityWindowMinutes) {
                                    Text("3 分钟").tag(3)
                                    Text("5 分钟").tag(5)
                                    Text("15 分钟").tag(15)
                                }
                                .labelsHidden()
                                .frame(width: 82)
                            }

                            compactPercentStepper(
                                title: "涨跌幅 ≥",
                                value: $riskEngine.config.volatilityThresholdPercent,
                                range: 1...20,
                                step: 0.5
                            )
                        }
                    }
                }
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

    private func compactPercentStepper(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 32, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

// MARK: - 推送通道与语音告警设置页（「设置 → 推送」）

struct NotificationChannelsSettingsView: View {
    @Bindable var dispatcher: NotificationDispatcher

    @State private var isShowingChannelForm = false
    @State private var editingChannelID: UUID?
    @State private var draftKind: NotificationChannelKind = .wecom
    @State private var draftName = ""
    @State private var draftRouting: ChannelRoutingRule = .all
    @State private var draftSecret = ""
    @State private var draftExtra1 = ""
    @State private var draftExtra2 = ""
    @State private var draftExtra3 = ""

    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            localEnhancementSection
            channelsListSection
            if isShowingChannelForm {
                channelEditorSection
            }
            recentHistorySection
        }
    }

    // MARK: 1. macOS 本机语音增强提醒

    private var localEnhancementSection: some View {
        sectionCard("macOS 本机增强提醒") {
            HStack {
                Text("中文语音播报")
                Spacer()
                Picker("", selection: $dispatcher.voiceMode) {
                    ForEach(VoiceAlertMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }

            HStack {
                Text("触发告警时使用系统语音大声播报风险内容，配合强提示音防止漏看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("试听播报") {
                    dispatcher.speakAlert("极危告警。BTC 永续多单距离强平不足 5%，请立即关注保证金。")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: 2. 外部推送通道列表（微信 / Bark / 飞书 / 钉钉 / TG / 短信 / Webhook）

    private var channelsListSection: some View {
        sectionCard("外部强触达通道（\(dispatcher.channels.count)）") {
            if dispatcher.channels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未配置微信、Bark、飞书、Telegram 或短信通道。离开电脑或锁屏时配置外部推送可第一时间叫醒。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        quickAddButton("企业微信", kind: .wecom)
                        quickAddButton("微信 Server酱", kind: .serverChan)
                        quickAddButton("Bark 强提醒", kind: .bark)
                        quickAddButton("更多通道...", kind: .feishu)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(dispatcher.channels) { channel in
                        HStack(spacing: 10) {
                            Text(channel.kind.shortLabel)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 24)
                                .background(badgeColor(for: channel.kind), in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(channel.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(channel.routingRule.shortLabel)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text("\(channel.kind.label) · \(channel.maskedSecret)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { channel.isEnabled },
                                set: { _ in dispatcher.toggleChannel(id: channel.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            Button("编辑") {
                                openEditForm(channel)
                            }
                            .controlSize(.small)

                            Button(role: .destructive) {
                                dispatcher.deleteChannel(id: channel.id)
                                if editingChannelID == channel.id {
                                    isShowingChannelForm = false
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)

                        if channel.id != dispatcher.channels.last?.id {
                            Divider()
                        }
                    }
                }

                HStack {
                    Label("所有 Webhook 与密钥均加密存储于钥匙串", systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        openNewForm(kind: .wecom)
                    } label: {
                        Label("添加推送通道", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private func quickAddButton(_ title: String, kind: NotificationChannelKind) -> some View {
        Button(title) {
            openNewForm(kind: kind)
        }
        .controlSize(.small)
    }

    // MARK: 3. 添加 / 编辑通道表单

    private var channelEditorSection: some View {
        sectionCard(editingChannelID == nil ? "添加外部推送通道" : "编辑推送通道") {
            HStack {
                Text("通道类型")
                    .font(.subheadline)
                    .frame(width: 84, alignment: .leading)
                Picker("", selection: $draftKind) {
                    ForEach(NotificationChannelKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .disabled(editingChannelID != nil)
            }

            Text(draftKind.hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            labeledField("通道备注") {
                TextField(draftKind.label, text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("推送范围") {
                Picker("", selection: $draftRouting) {
                    ForEach(ChannelRoutingRule.allCases) { rule in
                        Text(rule.label).tag(rule)
                    }
                }
                .labelsHidden()
            }

            labeledField(draftKind.primarySecretLabel) {
                SecureField(
                    editingChannelID == nil ? draftKind.primarySecretPlaceholder : "留空表示保持原配置不变",
                    text: $draftSecret
                )
                .textFieldStyle(.roundedBorder)
            }

            // 按通道动态展示附加字段
            if draftKind == .telegram {
                labeledField("Chat ID") {
                    TextField("例如：123456789 或 -100xxxx", text: $draftExtra1)
                        .textFieldStyle(.roundedBorder)
                }
            } else if draftKind == .twilioSMS {
                labeledField("Account SID") {
                    TextField("ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", text: $draftExtra1)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("发送号码") {
                    TextField("Twilio From 号码，如 +15005550006", text: $draftExtra2)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("接收手机号") {
                    TextField("接收短信的手机号，如 +8613800138000", text: $draftExtra3)
                        .textFieldStyle(.roundedBorder)
                }
            } else if draftKind == .customWebhook {
                labeledField("鉴权 Token") {
                    TextField("可选，自动附带 Authorization: Bearer ...", text: $draftExtra1)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let testMessage {
                HStack(spacing: 6) {
                    Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSucceeded ? MarketColors.green : MarketColors.red)
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testSucceeded ? .primary : MarketColors.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await runChannelTest() }
                } label: {
                    HStack(spacing: 5) {
                        if isTesting { ProgressView().controlSize(.mini) }
                        Text(isTesting ? "发送中..." : "发送测试消息")
                    }
                }
                .disabled(isTesting)

                Spacer()

                Button("取消") {
                    isShowingChannelForm = false
                    testMessage = nil
                }

                Button("保存通道") {
                    saveDraftChannel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSaveChannel == false)
            }
        }
    }

    // MARK: 4. 最近告警与推送送达记录

    private var recentHistorySection: some View {
        sectionCard("最近告警与推送记录（\(dispatcher.recentEvents.count)）") {
            if dispatcher.recentEvents.isEmpty {
                Text("暂无触发记录。价格、余额或风险预警触发后，这里将记录详情及各推送通道送达状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(dispatcher.recentEvents.prefix(10)) { record in
                        HStack(alignment: .top, spacing: 8) {
                            Text(record.severity.badge)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(severityColor(record.severity), in: RoundedRectangle(cornerRadius: 4))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(record.title)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(MarketFormatter.clockTime(record.timestamp))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(record.deliverySummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if record.id != dispatcher.recentEvents.prefix(10).last?.id {
                            Divider()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("清空记录") {
                        dispatcher.clearHistory()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: 表单操作

    private var canSaveChannel: Bool {
        if editingChannelID != nil { return true }
        let hasSecret = draftSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch draftKind {
        case .telegram:
            return hasSecret && draftExtra1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .twilioSMS:
            return hasSecret
                && draftExtra1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && draftExtra2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && draftExtra3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        default:
            return hasSecret
        }
    }

    private func openNewForm(kind: NotificationChannelKind) {
        editingChannelID = nil
        draftKind = kind
        draftName = ""
        draftRouting = (kind == .twilioSMS || kind == .bark) ? .riskOnly : .all
        draftSecret = ""
        draftExtra1 = ""
        draftExtra2 = ""
        draftExtra3 = ""
        testMessage = nil
        isShowingChannelForm = true
    }

    private func openEditForm(_ config: NotificationChannelConfig) {
        editingChannelID = config.id
        draftKind = config.kind
        draftName = config.name
        draftRouting = config.routingRule
        draftSecret = ""
        draftExtra1 = config.extraField1
        draftExtra2 = config.extraField2
        draftExtra3 = config.extraField3
        testMessage = nil
        isShowingChannelForm = true
    }

    private func resolvedSecret() -> String {
        let trimmed = draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        return editingChannelID.map { dispatcher.secret(for: $0) } ?? ""
    }

    private func runChannelTest() async {
        isTesting = true
        testMessage = nil
        defer { isTesting = false }

        let tempConfig = NotificationChannelConfig(
            id: editingChannelID ?? UUID(),
            kind: draftKind,
            name: draftName.isEmpty ? draftKind.label : draftName,
            routingRule: draftRouting,
            extraField1: draftExtra1,
            extraField2: draftExtra2,
            extraField3: draftExtra3
        )

        do {
            try await dispatcher.testChannel(config: tempConfig, secret: resolvedSecret())
            testSucceeded = true
            testMessage = "测试消息发送成功！请检查对应客户端是否已收到。"
        } catch {
            testSucceeded = false
            testMessage = error.localizedDescription
        }
    }

    private func saveDraftChannel() {
        dispatcher.saveChannel(
            editingID: editingChannelID,
            kind: draftKind,
            name: draftName,
            routingRule: draftRouting,
            secret: draftSecret,
            extraField1: draftExtra1,
            extraField2: draftExtra2,
            extraField3: draftExtra3
        )
        isShowingChannelForm = false
        testMessage = nil
    }

    // MARK: 样式辅助

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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
                .frame(width: 84, alignment: .leading)
            field()
        }
    }

    private func badgeColor(for kind: NotificationChannelKind) -> Color {
        switch kind {
        case .wecom, .serverChan, .pushPlus:
            return Color(red: 0.08, green: 0.68, blue: 0.36)
        case .bark:
            return Color(red: 0.94, green: 0.32, blue: 0.32)
        case .feishu:
            return Color(red: 0.16, green: 0.54, blue: 0.96)
        case .dingtalk:
            return Color(red: 0.10, green: 0.56, blue: 0.94)
        case .telegram:
            return Color(red: 0.14, green: 0.64, blue: 0.88)
        case .twilioSMS:
            return Color(red: 0.86, green: 0.18, blue: 0.24)
        case .customWebhook:
            return Color.purple
        }
    }

    private func severityColor(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .critical: return MarketColors.red
        case .warning: return .orange
        case .info: return Color.accentColor
        }
    }
}
