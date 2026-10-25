// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AISettingsView: NSView, NSTextFieldDelegate {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView(), document = Document()
    private var contentStack: NSStackView?
    private let endpoint = NSTextField(), model = NSTextField(), key = NSSecureTextField(), recipient = NSTextField()
    private let channelPicker = NSPopUpButton(), modelPicker = NSPopUpButton(), channelName = NSTextField(), modelName = NSTextField()
    private let defaultButton = NSButton(title: "设为默认", target: nil, action: nil)
    private let fetchModels = NSButton(title: "获取模型列表…", target: nil, action: nil), stopModels = NSButton(title: "取消获取", target: nil, action: nil)
    private var discovery: AIModelDiscoveryClient?, discoveryToken = UUID()
    private var catalog: [AIChannelConfiguration], channelIndex = 0, modelIndex = 0
    private var defaultSelection: AIModelSelection?
    private let effort = NSPopUpButton()
    private let timeout = NSTextField(), limit = NSTextField(), outputLimit = NSTextField(), language = NSPopUpButton(), apiType = NSPopUpButton(), provider = NSPopUpButton()
    private var selectedProvider = AIProviderPreset.custom
    private let protocolHint = NSTextField(wrappingLabelWithString: "")
    private let images = NSButton(checkboxWithTitle: "此模型支持图片输入", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: "加密保存对话历史到本机（图片不保存）", target: nil, action: nil)
    private let permission = NSPopUpButton()
    private let contextTokens = NSTextField(), compactPercent = NSTextField()
    private let executionWait = NSButton(checkboxWithTitle: "AI 终端操作执行前等待 8 秒（默认关闭）", target: nil, action: nil)
    private let detailed = NSButton(checkboxWithTitle: "优先给出详细解释", target: nil, action: nil)
    private let recorder = ShortcutRecorder(), shortcutLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let test = NSButton(title: "测试连接", target: nil, action: nil)
    private let cancel = NSButton(title: "停止测试", target: nil, action: nil)
    private var shortcut: KeyboardShortcut?, client: AIClient?, testToken = UUID()
    private var editorGeneration = UUID()
    private let original: AISettings, loadError: Error?
    init() {
        let result = Result { try AISettings.load() }; original = (try? result.get()) ?? .init(); shortcut = original.shortcut
        catalog = original.editableChannels; if catalog.isEmpty { catalog = [AIChannelConfiguration()] }
        defaultSelection = original.defaultModelSelection
        if case .failure(let error) = result { loadError = error } else { loadError = nil }
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        recipient.stringValue = original.recipientNote ?? ""; recipient.placeholderString = "可选：服务方、租户/项目、模型路由；仅为声明，客户端不能验证"
        endpoint.stringValue = original.endpoint; model.stringValue = original.model; key.stringValue = original.apiKey
        endpoint.placeholderString = "https://服务地址/v1（或完整接口地址）"
        for field in [endpoint, model, key, recipient, timeout, limit, outputLimit, contextTokens, compactPercent, channelName, modelName] { field.delegate = self }
        model.placeholderString = "服务端提供的模型名称"; key.placeholderString = "API 密钥；无需认证的本机服务可留空"
        selectedProvider = original.provider; outputLimit.stringValue = String(original.maxOutputTokens)
        timeout.stringValue = String(original.timeout); limit.stringValue = String(original.contextLimit)
        images.state = original.supportsImages ? .on : .off; history.state = original.saveHistory ? .on : .off; detailed.state = original.detailed ? .on : .off
        language.addItems(withTitles: ["中文", "English"]); language.selectItem(withTitle: original.language)
        language.target = self; language.action = #selector(optionChanged)
        permission.addItems(withTitles: AIPermissionMode.allCases.map { $0.title + " · " + $0.explanation })
        permission.selectItem(at: AIPermissionMode.allCases.firstIndex(of: original.permissions) ?? 0)
        permission.target = self; permission.action = #selector(optionChanged)
        permission.identifier = .init("ai.settings.permission")
        contextTokens.identifier = .init("ai.settings.contextTokens"); compactPercent.identifier = .init("ai.settings.compactPercent")
        executionWait.state = original.waitBeforeTerminalExecution == true ? .on : .off
        executionWait.identifier = .init("ai.settings.executionWait")
        executionWait.toolTip = "关闭后，操作通过 ask 审批或只读授权即执行；开启后，每条命令执行前留出 8 秒接管时间。点击停止并接管、Ctrl+C 或双击 Esc 可终止任务。"
        for button in [images, history, detailed, executionWait] { button.target = self; button.action = #selector(optionChanged) }
        apiType.addItems(withTitles: AIAPIType.allCases.map(\.title)); apiType.selectItem(at: AIAPIType.allCases.firstIndex(of: original.protocolType) ?? 0)
        apiType.target = self; apiType.action = #selector(protocolChanged)
        provider.addItems(withTitles: AIProviderPreset.allCases.map(\.title)); provider.selectItem(at: AIProviderPreset.allCases.firstIndex(of: selectedProvider) ?? 0)
        provider.target = self; provider.action = #selector(providerChanged)
        channelPicker.target = self; channelPicker.action = #selector(channelChanged); channelPicker.identifier = .init("ai.settings.channel")
        modelPicker.target = self; modelPicker.action = #selector(modelChanged); modelPicker.identifier = .init("ai.settings.modelChoice")
        channelName.identifier = .init("ai.settings.channelName"); modelName.identifier = .init("ai.settings.modelName")
        modelName.placeholderString = "可选，例如：快速回答、复杂排障"
        func action(_ title: String, _ selector: Selector, _ id: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: selector); button.bezelStyle = .rounded; button.identifier = .init(id); return button
        }
        let channelRow = NSStackView(views: [channelPicker, action("新增渠道", #selector(addChannel), "ai.settings.addChannel"), action("删除", #selector(removeChannel), "ai.settings.removeChannel")]); channelRow.spacing = 6
        defaultButton.target = self; defaultButton.action = #selector(setDefaultModel); defaultButton.bezelStyle = .rounded; defaultButton.identifier = .init("ai.settings.defaultModel")
        fetchModels.target = self; fetchModels.action = #selector(discoverModels); fetchModels.bezelStyle = .rounded; fetchModels.identifier = .init("ai.settings.fetchModels")
        fetchModels.toolTip = "仅使用当前渠道密钥查询模型列表，不发送问题、会话或历史。"
        stopModels.target = self; stopModels.action = #selector(stopModelDiscovery); stopModels.bezelStyle = .rounded; stopModels.isHidden = true; stopModels.identifier = .init("ai.settings.stopModels")
        let modelRow = NSStackView(views: [modelPicker, action("新增模型", #selector(addModel), "ai.settings.addModel"), action("删除", #selector(removeModel), "ai.settings.removeModel"), defaultButton, fetchModels, stopModels]); modelRow.spacing = 6
        channelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal); modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for picker in [channelPicker, modelPicker] { picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); picker.cell?.lineBreakMode = .byTruncatingMiddle }
        effort.addItems(withTitles: ["服务端默认"] + AIReasoningEffort.allCases.map(\.title))
        effort.identifier = .init("ai.settings.reasoningEffort"); effort.target = self; effort.action = #selector(optionChanged)
        effort.toolTip = "按模型能力选择；服务端默认不发送参数。第三方兼容渠道可能仅支持部分档位，不会自动降级或重试。"
        let labels = ["配置渠道", "渠道名称", "渠道预设", "接口类型", "接口地址", "API 密钥", "接收方/路由声明", "超时（秒）", "配置模型", "显示名称", "模型 ID", "资料字符上限", "最大上下文 Token", "自动压缩阈值 %", "权限", "输出 Token 上限", "思考强度", "回答语言"]
        let controls: [NSView] = [channelRow, channelName, provider, apiType, endpoint, key, recipient, timeout, modelRow, modelName, model, limit, contextTokens, compactPercent, permission, outputLimit, effort, language]
        for (control, id) in zip([provider, apiType, endpoint, model, key, recipient, timeout, limit, outputLimit, language], ["provider", "protocol", "endpoint", "model", "key", "recipient", "timeout", "limit", "outputLimit", "language"]) { control.identifier = .init("ai.settings." + id) }
        let grid = NSGridView(views: zip(labels, controls).map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 10; grid.columnSpacing = 14; grid.column(at: 0).width = 112; grid.column(at: 1).width = 610
        let title = NSTextField(labelWithString: "AI 助手"); title.font = .systemFont(ofSize: 18, weight: .semibold)
        let budgetHint = NSTextField(wrappingLabelWithString: "按服务商填写模型最大上下文，支持最高 2,097,152 Token；默认 262,144 Token，80% 自动压缩。Token 为估算值，预留输出和系统指令空间；原始聊天记录保留。")
        budgetHint.font = .systemFont(ofSize: 11); budgetHint.textColor = .secondaryLabelColor
        let resetBudget = action("使用默认预算", #selector(resetBudgets), "ai.settings.resetBudgets")
        let budgetRow = NSStackView(views: [budgetHint, resetBudget]); budgetRow.spacing = 10
        let intro = NSTextField(wrappingLabelWithString: "每个渠道独立保存接口和密钥，同一渠道可添加多个模型。对话中可直接选模型；设为默认只影响新对话。选择已保存渠道会保留密钥，切换渠道预设才会清空该渠道的旧密钥。点击应用后保存。")
        recorder.title = "录入快捷键"; recorder.bezelStyle = .rounded
        recorder.onShortcut = { [weak self] value in self?.shortcut = value; self?.refreshShortcut() }
        let clear = NSButton(title: "取消快捷键", target: self, action: #selector(clearShortcut)); clear.bezelStyle = .rounded
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "显示 / 隐藏助手"), shortcutLabel, recorder, clear]); shortcutRow.spacing = 12
        refreshShortcut()
        test.target = self; test.action = #selector(testConnection); test.identifier = .init("ai.settings.test")
        test.toolTip = "只发送一条固定测试文字，不附加任何终端内容。"
        cancel.target = self; cancel.action = #selector(cancelTest); cancel.isEnabled = false
        let erase = NSButton(title: "清空已保存历史…", target: self, action: #selector(clearHistory))
        for button in [test, cancel, erase] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [test, cancel, erase]); buttons.spacing = 10
        let hint = NSTextField(wrappingLabelWithString: "服务设置、密钥和历史仅保存在当前 Mac 的 AI 独立加密目录，不参与同步或导出。历史最多保留 50 条对话；关闭保存后仅保留本次运行的新增对话。自动遮盖常见密钥格式不能识别全部敏感内容，发送前请检查预览。")
        for label in [intro, hint, status, protocolHint] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
        let stack = NSStackView(views: [title, intro, grid, budgetRow, protocolHint, images, history, detailed, executionWait, shortcutRow, buttons, status, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.frame = bounds; scroll.documentView = document; addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); contentStack = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20)] + [intro, hint, status, protocolHint, budgetRow].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        if let selected = defaultSelection, let index = catalog.firstIndex(where: { $0.id == selected.channelID }) {
            channelIndex = index; modelIndex = catalog[index].models.firstIndex(where: { $0.id == selected.modelID }) ?? 0
        }
        loadSelection()
        if let loadError {
            status.stringValue = "AI 设置读取失败，此页只读：" + loadError.localizedDescription
            func disable(_ view: NSView) { (view as? NSControl)?.isEnabled = false; view.subviews.forEach(disable) }; controls.forEach(disable)
            for control in [images, history, detailed, executionWait, recorder, clear, test, resetBudget] { control.isEnabled = false }
        }
    }
    override func layout() {
        super.layout(); document.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.frame.height)); document.layoutSubtreeIfNeeded()
        let height = max(scroll.contentSize.height, (contentStack?.fittingSize.height ?? 0) + 40)
        if abs(document.frame.height - height) > 0.5 { document.setFrameSize(NSSize(width: scroll.contentSize.width, height: height)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { client?.cancel(); discovery?.cancel() }
    func dispose() { recorder.stopRecording(); cancelTest() }
    private var selection: AIModelSelection { .init(channelID: catalog[channelIndex].id, modelID: catalog[channelIndex].models[modelIndex].id) }
    private func captureSelection() {
        var channel = catalog[channelIndex], item = channel.models[modelIndex]
        channel.name = channelName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        channel.providerPreset = selectedProvider; channel.apiType = AIAPIType.allCases[max(0, apiType.indexOfSelectedItem)]
        channel.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); channel.apiKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        channel.recipientNote = recipient.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); channel.timeout = Int(timeout.stringValue) ?? 0
        item.name = modelName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); item.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        item.reasoningEffort = effort.indexOfSelectedItem > 0 ? AIReasoningEffort.allCases[effort.indexOfSelectedItem - 1] : nil
        item.outputTokenLimit = Int(outputLimit.stringValue) ?? 0; item.contextLimit = Int(limit.stringValue) ?? 0; item.supportsImages = images.state == .on
        item.contextWindowTokens = Int(contextTokens.stringValue) ?? 0; item.autoCompactPercent = Int(compactPercent.stringValue) ?? 0
        channel.models[modelIndex] = item; catalog[channelIndex] = channel
    }
    private func refreshPickers() {
        channelPicker.removeAllItems(); channelPicker.addItems(withTitles: catalog.map { $0.name.isEmpty ? "未命名渠道" : $0.name }); channelPicker.selectItem(at: channelIndex)
        modelPicker.removeAllItems(); modelPicker.addItems(withTitles: catalog[channelIndex].models.map { $0.title + (defaultSelection == .init(channelID: catalog[channelIndex].id, modelID: $0.id) ? " · 默认" : "") }); modelPicker.selectItem(at: modelIndex)
        defaultButton.title = defaultSelection == selection ? "默认模型" : "设为默认"
        defaultButton.isEnabled = defaultSelection != selection
    }
    private func loadSelection() {
        let channel = catalog[channelIndex], item = channel.models[modelIndex]
        channelName.stringValue = channel.name; selectedProvider = channel.providerPreset
        provider.selectItem(at: AIProviderPreset.allCases.firstIndex(of: channel.providerPreset) ?? 0)
        apiType.selectItem(at: AIAPIType.allCases.firstIndex(of: channel.apiType) ?? 0)
        endpoint.stringValue = channel.endpoint; key.stringValue = channel.apiKey; recipient.stringValue = channel.recipientNote ?? ""; timeout.stringValue = String(channel.timeout)
        effort.selectItem(at: item.reasoningEffort.flatMap { AIReasoningEffort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        modelName.stringValue = item.name; model.stringValue = item.model; outputLimit.stringValue = String(item.outputTokenLimit); limit.stringValue = String(item.contextLimit); images.state = item.supportsImages ? .on : .off
        contextTokens.stringValue = String(item.contextWindowTokens ?? 262144); compactPercent.stringValue = String(item.autoCompactPercent ?? 80)
        refreshPickers(); protocolChanged()
    }
    @objc private func channelChanged() { editorGeneration = UUID(); cancelTest(); let index = channelPicker.indexOfSelectedItem; captureSelection(); channelIndex = max(0, index); modelIndex = 0; loadSelection() }
    @objc private func modelChanged() { editorGeneration = UUID(); cancelTest(); let index = modelPicker.indexOfSelectedItem; captureSelection(); modelIndex = max(0, index); loadSelection() }
    @objc private func addChannel() {
        editorGeneration = UUID(); cancelTest()
        captureSelection(); guard catalog.count < 32 else { status.stringValue = "最多配置 32 个渠道。"; return }
        var channel = AIChannelConfiguration(); channel.name = "渠道 \(catalog.count + 1)"; catalog.append(channel)
        channelIndex = catalog.count - 1; modelIndex = 0; loadSelection(); window?.makeFirstResponder(channelName)
    }
    @objc private func removeChannel() {
        guard Dialogs.confirm("删除此 AI 渠道？", text: "移除该渠道的本机密钥及所有模型；使用它的对话将需要重新选择模型。点击应用后生效。", action: "删除") else { return }
        editorGeneration = UUID(); cancelTest()
        let removed = catalog.remove(at: channelIndex).id
        if defaultSelection?.channelID == removed { defaultSelection = nil }
        if catalog.isEmpty { catalog = [AIChannelConfiguration()] }
        channelIndex = min(channelIndex, catalog.count - 1); modelIndex = 0; loadSelection()
    }
    @objc private func addModel() {
        editorGeneration = UUID(); cancelTest()
        captureSelection(); guard catalog[channelIndex].models.count < 32 else { status.stringValue = "每个渠道最多配置 32 个模型。"; return }
        catalog[channelIndex].models.append(AIModelConfiguration()); modelIndex = catalog[channelIndex].models.count - 1
        loadSelection(); window?.makeFirstResponder(model)
    }
    @objc private func removeModel() {
        guard Dialogs.confirm("删除此模型？", text: "使用它的对话将需要重新选择模型。点击应用后生效。", action: "删除") else { return }
        editorGeneration = UUID(); cancelTest()
        captureSelection(); if defaultSelection == selection { defaultSelection = nil }
        catalog[channelIndex].models.remove(at: modelIndex)
        if catalog[channelIndex].models.isEmpty { catalog[channelIndex].models = [AIModelConfiguration()] }
        modelIndex = min(modelIndex, catalog[channelIndex].models.count - 1); loadSelection()
    }
    @objc private func setDefaultModel() { editorGeneration = UUID(); captureSelection(); defaultSelection = selection; refreshPickers(); status.stringValue = "已设为新对话的默认模型，点击应用后保存。" }
    @objc private func optionChanged() { editorGeneration = UUID() }
    @objc private func resetBudgets() {
        guard loadError == nil else { return }
        cancelTest(); editorGeneration = UUID()
        outputLimit.stringValue = String(AISettings.defaultOutputTokens); limit.stringValue = String(AISettings.defaultContextCharacters)
        contextTokens.stringValue = "262144"; compactPercent.stringValue = "80"
        captureSelection(); status.stringValue = "已填入当前模型的默认预算，点击“应用”保存；服务端仍可能有更低的限制。"
    }
    @objc private func providerChanged() {
        let next = AIProviderPreset.allCases[max(0, provider.indexOfSelectedItem)]
        guard next != selectedProvider else { return }
        editorGeneration = UUID(); cancelTest()
        var value = original; value.channels = nil; value.providerPreset = selectedProvider == .custom ? nil : selectedProvider
        value.selectProvider(next); selectedProvider = next
        if next != .custom {
            endpoint.stringValue = value.endpoint; model.stringValue = value.model; key.stringValue = ""
            recipient.stringValue = value.recipientNote ?? ""; images.state = .off
            outputLimit.stringValue = String(value.maxOutputTokens)
            limit.stringValue = String(value.contextLimit)
            effort.selectItem(at: 0)
            apiType.selectItem(at: AIAPIType.allCases.firstIndex(of: value.protocolType) ?? 0)
            status.stringValue = "已填入“" + next.title + "”预设并清空旧密钥。请填写对应密钥；尚未保存或联网。"
        } else { status.stringValue = "已切换为自定义，保留当前地址、模型和密钥；请检查接口参数。" }
        captureSelection(); refreshPickers()
        protocolChanged()
    }
    @objc private func protocolChanged() {
        cancelModelDiscovery()
        editorGeneration = UUID()
        let selected = AIAPIType.allCases[max(0, apiType.indexOfSelectedItem)]
        effort.menu?.autoenablesItems = false
        for (index, item) in effort.itemArray.enumerated() { item.isEnabled = index == 0 || AIReasoningEffort.allCases[index - 1].supports(selected) }
        let example = selectedProvider != .custom && selected == selectedProvider.protocolType ? selectedProvider.endpoint : selected.exampleEndpoint
        endpoint.placeholderString = example
        var candidate = original; candidate.apiType = selected
        candidate.endpoint = endpoint.stringValue; candidate.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = candidate.endpoint.isEmpty ? "地址示例：" + example : (try? candidate.validatedURL()).map { "实际请求地址：" + $0.absoluteString } ?? "请检查地址与接口类型、模型是否匹配。"
        protocolHint.stringValue = selectedProvider.note + "\n" + resolved + "\n支持基础地址或完整端点，补全地址后再授权；鉴权：" + selected.authentication + "。切换类型不会修改已填地址或密钥。"
        needsLayout = true
    }
    func controlTextDidChange(_ notification: Notification) {
        editorGeneration = UUID()
        if let field = notification.object as? NSTextField, field === channelName || field === modelName || field === model { captureSelection(); refreshPickers() }
        protocolChanged()
    }
    private func refreshShortcut() { shortcutLabel.stringValue = shortcut?.display ?? "未设置" }
    @objc private func clearShortcut() { shortcut = nil; recorder.stopRecording(); refreshShortcut() }
    func values() throws -> AISettings {
        if let loadError { throw loadError }
        captureSelection(); var value = original
        value.version = 4; value.channels = catalog; value.defaultModel = defaultSelection
        if value.defaultModel == nil { value.defaultModel = value.modelChoices.first?.selection }
        value.waitBeforeTerminalExecution = executionWait.state == .on
        value.permissionMode = AIPermissionMode.allCases[max(0, permission.indexOfSelectedItem)]
        value.autoApproveReadOnly = value.permissions == .assist
        value.saveHistory = history.state == .on; value.detailed = detailed.state == .on
        value.language = language.titleOfSelectedItem ?? "中文"; value.shortcut = shortcut
        value.mirrorDefaultModel()
        try value.validate(allowEmpty: true)
        return value
    }
    func validateShortcut(against shortcuts: KeyboardShortcuts) throws {
        guard loadError == nil, let shortcut = try values().shortcut else { return }
        guard shortcuts.action(for: shortcut) == nil, shortcut != WorkspaceController.deepFocusShortcut else { throw ModelError.invalid("AI 快捷键与现有功能冲突，请重新录入。") }
    }
    func validateForApply() throws {
        guard loadError == nil else { return }
        let value = try values()
        if value != original, try AISettings.load() != original { throw ModelError.invalid("AI 设置已在其他窗口更改，请重新打开设置。") }
    }
    func apply() throws { if loadError != nil { return }; try validateForApply(); let value = try values(); if value != original { try value.save() } }
    @objc private func testConnection() {
        guard client == nil else { return }
        cancelModelDiscovery()
        do {
            let settings = try values().resolved(for: selection)
            let scope = UUID()
            let request = try AIRequest.connectionTest(settings: settings, scope: scope)
            let generation = editorGeneration
            guard AISendReview.reviewTest(request) else { return }
            let authorization = try AISendAuthorization.approve(request) { [weak self] in
                guard let self, self.editorGeneration == generation, let current = try? self.values().resolved(for: self.selection) else { return false }
                return request.isCurrent(settings: current, scope: scope, revision: scope)
            }
            let token = UUID(); testToken = token
            let client = AIClient()
            try client.start(authorization) { [weak self] result in
                guard let self, self.testToken == token else { return }
                self.client = nil; self.test.isEnabled = true; self.cancel.isEnabled = false
                switch result { case .success: self.status.stringValue = "连接成功：" + request.channelName + " · " + request.model; case .failure(let error): self.status.stringValue = error.localizedDescription }
            }
            self.client = client; test.isEnabled = false; cancel.isEnabled = true; status.stringValue = "正在测试…仅发送已授权的固定测试文字。"
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelTest() { testToken = UUID(); client?.cancel(); client = nil; test.isEnabled = true; cancel.isEnabled = false; cancelModelDiscovery() }
    private func cancelModelDiscovery() {
        discoveryToken = UUID(); let pending = discovery; discovery = nil; pending?.cancel()
        fetchModels.title = "获取模型列表…"; fetchModels.isEnabled = loadError == nil; stopModels.isHidden = true
        if pending != nil { status.stringValue = "已停止获取模型列表，现有模型未修改。" }
    }
    @objc private func stopModelDiscovery() { cancelModelDiscovery(); status.stringValue = "已停止获取模型列表，现有配置未修改。" }
    @objc private func discoverModels() {
        guard loadError == nil else { return }
        cancelTest(); captureSelection()
        let channel = catalog[channelIndex], generation = editorGeneration, token = UUID()
        do {
            let request = try AIModelListRequest(channel: channel), client = AIModelDiscoveryClient()
            discoveryToken = token; discovery = client; fetchModels.isEnabled = false; fetchModels.title = "正在获取…"; stopModels.isHidden = false
            status.stringValue = "正在查询：" + request.url.absoluteString + "\n仅发送此渠道的鉴权，不含会话、历史或图片。"
            try client.start(request) { [weak self] result in
                guard let self, self.discoveryToken == token else { return }
                self.discovery = nil; self.fetchModels.isEnabled = true; self.fetchModels.title = "获取模型列表…"; self.stopModels.isHidden = true
                guard self.editorGeneration == generation, self.catalog[self.channelIndex].id == channel.id else { self.status.stringValue = "配置已变化，结果已丢弃，请重新获取。"; return }
                do {
                    let models = try result.get()
                    guard !models.isEmpty else { self.status.stringValue = "接口未返回可选模型，仍可手动填写模型 ID。"; return }
                    guard let chosen = AIModelDiscoveryPicker.choose(models: models, channel: channel) else { self.status.stringValue = "已取消添加模型，配置未修改。"; return }
                    self.captureSelection()
                    guard self.discoveryToken == token, self.editorGeneration == generation, self.catalog[self.channelIndex].id == channel.id,
                          try AIModelListRequest(channel: self.catalog[self.channelIndex]) == request else { self.status.stringValue = "渠道配置已变化，未添加模型，请重新获取。"; return }
                    let imported = try self.catalog[self.channelIndex].addingDiscovered(chosen, totalModels: self.catalog.reduce(0, { $0 + $1.models.count }))
                    self.catalog[self.channelIndex] = imported.channel
                    if let first = imported.firstIndex { self.modelIndex = first }
                    self.loadSelection()
                    self.status.stringValue = "已加入所选模型；请核对图片能力和输出上限，点击“应用”保存。"
                } catch { self.status.stringValue = error.localizedDescription }
            }
        } catch { cancelModelDiscovery(); status.stringValue = error.localizedDescription }
    }
    @objc private func clearHistory() {
        guard Dialogs.confirm("清空已保存的 AI 历史？", text: "删除本机历史列表；当前打开的对话仍保留。", action: "清空历史") else { return }
        AIHistory.shared.clear(); status.stringValue = "已清空历史列表。"
    }
}
