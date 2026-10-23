// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AISettingsView: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView(), document = Document()
    private var contentStack: NSStackView?
    private let endpoint = NSTextField(), model = NSTextField(), key = NSSecureTextField(), recipient = NSTextField()
    private let timeout = NSTextField(), limit = NSTextField(), outputLimit = NSTextField(), language = NSPopUpButton(), apiType = NSPopUpButton(), provider = NSPopUpButton()
    private var selectedProvider = AIProviderPreset.custom
    private let protocolHint = NSTextField(wrappingLabelWithString: "")
    private let images = NSButton(checkboxWithTitle: "此模型支持图片输入", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: "加密保存对话历史到本机（图片不保存）", target: nil, action: nil)
    private let detailed = NSButton(checkboxWithTitle: "优先给出详细解释", target: nil, action: nil)
    private let recorder = ShortcutRecorder(), shortcutLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let test = NSButton(title: "测试连接", target: nil, action: nil)
    private let cancel = NSButton(title: "停止测试", target: nil, action: nil)
    private var shortcut: KeyboardShortcut?, client: AIClient?, testToken = UUID()
    private let original: AISettings, loadError: Error?
    init() {
        let result = Result { try AISettings.load() }; original = (try? result.get()) ?? .init(); shortcut = original.shortcut
        if case .failure(let error) = result { loadError = error } else { loadError = nil }
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        recipient.stringValue = original.recipientNote ?? ""; recipient.placeholderString = "可选：服务方、租户/项目、模型路由；仅为声明，客户端不能验证"
        endpoint.stringValue = original.endpoint; model.stringValue = original.model; key.stringValue = original.apiKey
        endpoint.placeholderString = "https://服务地址/v1/chat/completions（填写完整接口）"
        model.placeholderString = "服务端提供的模型名称"; key.placeholderString = "API 密钥；无需认证的本机服务可留空"
        selectedProvider = original.provider; outputLimit.stringValue = String(original.maxOutputTokens)
        timeout.stringValue = String(original.timeout); limit.stringValue = String(original.contextLimit)
        images.state = original.supportsImages ? .on : .off; history.state = original.saveHistory ? .on : .off; detailed.state = original.detailed ? .on : .off
        language.addItems(withTitles: ["中文", "English"]); language.selectItem(withTitle: original.language)
        apiType.addItems(withTitles: AIAPIType.allCases.map(\.title)); apiType.selectItem(at: AIAPIType.allCases.firstIndex(of: original.protocolType) ?? 0)
        apiType.target = self; apiType.action = #selector(protocolChanged)
        provider.addItems(withTitles: AIProviderPreset.allCases.map(\.title)); provider.selectItem(at: AIProviderPreset.allCases.firstIndex(of: selectedProvider) ?? 0)
        provider.target = self; provider.action = #selector(providerChanged)
        let labels = ["渠道预设", "接口类型", "接口地址", "模型", "API 密钥", "接收方/路由声明", "超时（秒）", "上下文字符上限", "输出 Token 上限", "回答语言"]
        let controls: [NSView] = [provider, apiType, endpoint, model, key, recipient, timeout, limit, outputLimit, language]
        for (control, id) in zip(controls, ["provider", "protocol", "endpoint", "model", "key", "recipient", "timeout", "limit", "outputLimit", "language"]) { control.identifier = .init("ai.settings." + id) }
        let grid = NSGridView(views: zip(labels, controls).map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 10; grid.columnSpacing = 14; grid.column(at: 0).width = 112; grid.column(at: 1).width = 610
        let title = NSTextField(labelWithString: "AI 助手"); title.font = .systemFont(ofSize: 18, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "可先选择渠道预设，也可自定义四种接口格式。切换渠道会清空旧密钥；只有审阅接收方与内容并授权后才发起请求；每次单独授权。")
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
        let stack = NSStackView(views: [title, intro, grid, protocolHint, images, history, detailed, shortcutRow, buttons, status, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.frame = bounds; scroll.documentView = document; addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); contentStack = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20)] + [intro, hint, status, protocolHint].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        protocolChanged()
        if let loadError {
            status.stringValue = "AI 设置读取失败，此页只读：" + loadError.localizedDescription
            controls.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = false }
            for control in [images, history, detailed, recorder, clear, test] { control.isEnabled = false }
        }
    }
    override func layout() {
        super.layout(); document.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.frame.height)); document.layoutSubtreeIfNeeded()
        let height = max(scroll.contentSize.height, (contentStack?.fittingSize.height ?? 0) + 40)
        if abs(document.frame.height - height) > 0.5 { document.setFrameSize(NSSize(width: scroll.contentSize.width, height: height)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { client?.cancel() }
    func dispose() { recorder.stopRecording(); cancelTest() }
    @objc private func providerChanged() {
        let next = AIProviderPreset.allCases[max(0, provider.indexOfSelectedItem)]
        guard next != selectedProvider else { return }
        var value = original; value.providerPreset = selectedProvider == .custom ? nil : selectedProvider
        value.selectProvider(next); selectedProvider = next
        if next != .custom {
            endpoint.stringValue = value.endpoint; model.stringValue = value.model; key.stringValue = ""
            recipient.stringValue = value.recipientNote ?? ""; images.state = .off
            outputLimit.stringValue = String(value.maxOutputTokens)
            apiType.selectItem(at: AIAPIType.allCases.firstIndex(of: value.protocolType) ?? 0)
            status.stringValue = "已填入“" + next.title + "”预设并清空旧密钥。请填写对应密钥；尚未保存或联网。"
        } else { status.stringValue = "已切换为自定义，保留当前地址、模型和密钥；请检查接口参数。" }
        protocolChanged()
    }
    @objc private func protocolChanged() {
        let selected = AIAPIType.allCases[max(0, apiType.indexOfSelectedItem)]
        let example = selectedProvider != .custom && selected == selectedProvider.protocolType ? selectedProvider.endpoint : selected.exampleEndpoint
        endpoint.placeholderString = example
        protocolHint.stringValue = selectedProvider.note + "\n地址示例：" + example + "\n鉴权：" + selected.authentication + (selected == .gemini ? "。{model} 在授权前替换为所选模型；不支持 URL 查询参数。" : "。请填写完整接口地址。") + " 切换接口类型不会修改地址或密钥；预设不验证服务身份。"
        needsLayout = true
    }
    private func refreshShortcut() { shortcutLabel.stringValue = shortcut?.display ?? "未设置" }
    @objc private func clearShortcut() { shortcut = nil; recorder.stopRecording(); refreshShortcut() }
    func values() throws -> AISettings {
        if let loadError { throw loadError }
        var value = original
        value.version = 3; value.providerPreset = selectedProvider == .custom ? nil : selectedProvider; value.outputTokenLimit = Int(outputLimit.stringValue) ?? 0
        value.apiType = AIAPIType.allCases[max(0, apiType.indexOfSelectedItem)]
        value.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); value.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.recipientNote = recipient.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.apiKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.timeout = Int(timeout.stringValue) ?? 0; value.contextLimit = Int(limit.stringValue) ?? 0
        value.supportsImages = images.state == .on; value.saveHistory = history.state == .on; value.detailed = detailed.state == .on
        value.language = language.titleOfSelectedItem ?? "中文"; value.shortcut = shortcut
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
        do {
            let settings = try values()
            let scope = UUID()
            let request = try AIRequest.connectionTest(settings: settings, scope: scope)
            guard AISendReview.reviewTest(request) else { return }
            let authorization = try AISendAuthorization.approve(request) { [weak self] in
                guard let self, let current = try? self.values() else { return false }
                return request.isCurrent(settings: current, scope: scope, revision: scope)
            }
            let token = UUID(); testToken = token
            let client = AIClient()
            try client.start(authorization) { [weak self] result in
                guard let self, self.testToken == token else { return }
                self.client = nil; self.test.isEnabled = true; self.cancel.isEnabled = false
                switch result { case .success: self.status.stringValue = "连接成功，模型已返回有效内容。"; case .failure(let error): self.status.stringValue = error.localizedDescription }
            }
            self.client = client; test.isEnabled = false; cancel.isEnabled = true; status.stringValue = "正在测试…仅发送已授权的固定测试文字。"
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelTest() { testToken = UUID(); client?.cancel(); client = nil; test.isEnabled = true; cancel.isEnabled = false }
    @objc private func clearHistory() {
        guard Dialogs.confirm("清空已保存的 AI 历史？", text: "删除本机历史列表；当前打开的对话仍保留。", action: "清空历史") else { return }
        AIHistory.shared.clear(); status.stringValue = "已清空历史列表。"
    }
}
