import SwiftUI
import AppKit

/// 只负责本机预览与显式操作；不会自动联网或后台发送反馈。
struct FeedbackView: View {
    let currentDiagnostic: FeedbackDiagnostic?
    let refreshHistory: (() throws -> [FeedbackDiagnostic])?
    let deleteDiagnostic: ((String) throws -> Void)?
    let clearHistory: (() throws -> Void)?
    let storageNotice: String?

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.displayScale) private var displayScale
    @Environment(\.controlActiveState) private var windowState
    private var hairline: CGFloat { 1 / max(displayScale, 1) }
    @State private var historyItems: [FeedbackDiagnostic]
    @State private var selectedID: String
    @State private var issueTitle = "NVCodecTest 问题反馈"
    @State private var problem = ""
    @State private var previewTab = PreviewTab.draft
    @State private var loading = false
    @State private var hasLoadedHistory = false
    @State private var operationNotice = ""
    @State private var activeAlert: FeedbackAlert?
    @State private var editedLogs: [String: FeedbackDiagnostic] = [:]
    @State private var logEditorPresented = false
    @State private var logEditorText = ""
    @State private var logEditorID = ""

    init(currentDiagnostic: FeedbackDiagnostic? = nil, history: [FeedbackDiagnostic] = [],
         refreshHistory: (() throws -> [FeedbackDiagnostic])? = nil,
         deleteDiagnostic: ((String) throws -> Void)? = nil,
         clearHistory: (() throws -> Void)? = nil, storageNotice: String? = nil) {
        self.currentDiagnostic = currentDiagnostic
        self.refreshHistory = refreshHistory
        self.deleteDiagnostic = deleteDiagnostic
        self.clearHistory = clearHistory
        self.storageNotice = storageNotice
        let sorted = history.sorted { $0.createdAt > $1.createdAt }
        _historyItems = State(initialValue: sorted)
        _selectedID = State(initialValue: sorted.first?.id ?? currentDiagnostic?.id ?? "")
    }

    private enum PreviewTab: String, CaseIterable, Identifiable {
        case draft = "网页草稿"
        case full = "完整脱敏日志"
        case json = "诊断 JSON"
        var id: String { rawValue }
    }

    private enum FeedbackAlert: Identifiable {
        case error(String), delete(String), clear
        var id: String {
            switch self {
            case .error(let message): return "error:" + message
            case .delete(let id): return "delete:" + id
            case .clear: return "clear"
            }
        }
    }

    private var diagnostics: [FeedbackDiagnostic] {
        var items = historyItems
        // 有已持久化日志时优先真实记录；存储失败或没有历史时才使用临时诊断补救。
        if let current = currentDiagnostic, (items.isEmpty || storageNotice != nil),
           !items.contains(where: { $0.id == current.id }) { items.append(current) }
        return items
    }
    private var originalSelection: FeedbackDiagnostic? {
        diagnostics.first { $0.id == selectedID } ?? diagnostics.first
    }
    private var selected: FeedbackDiagnostic? {
        guard let original = originalSelection else { return nil }
        return editedLogs[original.id] ?? original
    }
    private var usingEditedCopy: Bool {
        originalSelection.map { editedLogs[$0.id] != nil } ?? false
    }
    private var draft: GitHubIssueDraft {
        GitHubFeedback.makeDraft(title: issueTitle, problem: problem, diagnostic: selected)
    }
    private var previewText: String {
        switch previewTab {
        case .draft: return draft.text
        case .full: return selected?.redactedText ?? "尚无脱敏诊断日志。你仍可填写问题现象并预览网页草稿。"
        case .json:
            if usingEditedCopy { return "当前使用删减副本，仅以 TXT 提交。本次禁用原诊断 JSON，避免重新带出已删除内容。" }
            return selected?.redactedJSON ?? "此记录没有可用的结构化 JSON；完整脱敏 TXT 仍可预览和导出。"
        }
    }
    private var canDeleteSelected: Bool {
        selected.map { doc in doc.isLocalRecord && historyItems.contains { $0.id == doc.id } } == true && deleteDiagnostic != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                historySidebar.frame(width: 200)
                    .background(SidebarSurface(blendingMode: .withinWindow))
                Hairline(axis: .vertical)
                feedbackBody.padding(20)
            }
            Hairline()
            footer
        }
        .frame(minWidth: 850, idealWidth: 980, maxWidth: .infinity,
               minHeight: 650, idealHeight: 760, maxHeight: .infinity)
        .font(DesignTokens.Font.body).lineSpacing(2)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle(prominent: false))
        .onAppear { reloadHistory(firstLoad: true) }
        .alert(item: $activeAlert, content: makeAlert)
        .sheet(isPresented: $logEditorPresented) {
            FeedbackLogEditor(text: logEditorText, original: diagnostics.first { $0.id == logEditorID }) { document in
                editedLogs[document.id] = document
                previewTab = .full
                operationNotice = "已应用删减副本；原日志未修改，本次仅以 TXT 提交"
                logEditorPresented = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(DesignTokens.Font.title1).foregroundColor(DesignTokens.Text.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("日志与 GitHub 反馈").font(DesignTokens.Font.title1.weight(.semibold))
                Text("默认带上机型、驱动和测试日志摘要，检查后到 GeekAudio/NVCodecTest 网页确认提交。")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机脱敏记录").font(DesignTokens.Font.body.weight(.semibold))
                Spacer()
                if loading { ProgressView().scaleEffect(0.55).frame(width: 18, height: 18) }
                Button(action: { reloadHistory() }) { Image(systemName: "arrow.clockwise") }
                    .disabled(loading || refreshHistory == nil)
                    .accessibilityLabel("刷新本机日志")
                    .help("重新读取本机日志，不会运行新的编解码测试")
            }
            if diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loading ? "正在读取…" : "尚无记录").font(DesignTokens.Font.body)
                    Text("完成环境扫描或测试后会自动记录。也可先填写问题现象。")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }.padding(.top, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(diagnostics) { diagnostic in
                            Button(action: { selectedID = diagnostic.id; operationNotice = "" }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(diagnostic.title).font(DesignTokens.Font.body.weight(.medium))
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(Self.dateString(diagnostic.createdAt)).font(DesignTokens.Font.small)
                                        .foregroundColor(DesignTokens.Text.secondary)
                                    if !diagnostic.sourceDescription.isEmpty {
                                        Text(diagnostic.sourceDescription).font(DesignTokens.Font.small)
                                            .foregroundColor(DesignTokens.Text.secondary).lineLimit(2)
                                    }
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ZStack {
                                    RoundedRectangle(cornerRadius: 7).fill(DesignTokens.Surface.control)
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(DesignTokens.Interaction.selection(active: windowState != .inactive)
                                            .opacity(selected?.id == diagnostic.id ? 0.10 : 0))
                                })
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                                    DesignTokens.Stroke.separator, lineWidth: hairline))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                                    DesignTokens.Text.primary.opacity(selected?.id == diagnostic.id ? 0.08 : 0),
                                    lineWidth: hairline))
                            }.accessibilityValue(selected?.id == diagnostic.id ? "已选择" : "未选择")
                                .accessibilityAddTraits(selected?.id == diagnostic.id ? .isSelected : [])
                        }
                    }
                }
            }
            if let notice = storageNotice, !notice.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(DesignTokens.Text.primary).padding(4)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                            .fill(DesignTokens.Status.warning.opacity(DesignTokens.Status.backgroundOpacity)))
                        .accessibilityHidden(true)
                    Text("日志留存提示：" + DiagnosticRedactor.redact(notice))
                        .foregroundColor(DesignTokens.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(DesignTokens.Font.small)
            }
            Text("最近 20 次 · 最长 30 天 · 仅存本机。运行中的记录可能尚无完整报告；此处读取已落盘内容。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu("管理本机记录") {
                Button("删除所选记录…") {
                    if let id = selected?.id { activeAlert = .delete(id) }
                }.disabled(!canDeleteSelected)
                Button("清空可删除的历史记录…") { activeAlert = .clear }
                    .disabled(clearHistory == nil || !historyItems.contains { $0.isLocalRecord })
            }.disabled(loading)
        }.padding(16)
    }

    private var feedbackBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("反馈标题").font(DesignTokens.Font.small.weight(.medium))
                TextField("概括发生的问题", text: $issueTitle).textFieldStyle(RoundedBorderTextFieldStyle())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("问题现象与复现步骤").font(DesignTokens.Font.small.weight(.medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $problem).font(DesignTokens.Font.body).frame(height: 70)
                    if problem.isEmpty {
                        Text("例如：已安装驱动，但 H.264 硬编失败；点击开始后出现……")
                            .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.placeholder)
                            .padding(.horizontal, 5).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.sep, lineWidth: hairline))
            }
            HStack(spacing: 8) {
                Picker("预览内容", selection: $previewTab) {
                    ForEach(PreviewTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(SegmentedPickerStyle()).labelsHidden()
                Text(ByteCountFormatter.string(fromByteCount: Int64(previewText.utf8.count), countStyle: .file))
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
            HStack(spacing: 8) {
                if usingEditedCopy {
                    Text("删减副本 · 仅 TXT").font(DesignTokens.Font.small.weight(.medium))
                        .foregroundColor(DesignTokens.Text.primary)
                    Button("还原原日志") {
                        if let id = originalSelection?.id { editedLogs.removeValue(forKey: id) }
                        operationNotice = "已还原本机原日志；提交前请重新检查"
                    }.font(DesignTokens.Font.small)
                } else {
                    Text("可先删减日志副本；原本机记录保持不变").font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
                Spacer()
                Button("删减日志副本…") {
                    guard let document = selected else { return }
                    logEditorID = document.id
                    logEditorText = document.redactedText
                    logEditorPresented = true
                }.font(DesignTokens.Font.small).disabled(selected == nil)
            }
            FeedbackTextPreview(text: previewText)
                .frame(minHeight: 220, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.sep, lineWidth: hairline))
            Text(draft.notice)
                .font(DesignTokens.Font.small)
                .foregroundColor(draft.requiresManualAttachment ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("前往时会把网页草稿交给 GitHub，确认提交后公开。附件拖入网页时即会上传。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(operationNotice.isEmpty ? "无后台传输 · 无需维护者 Token" : operationNotice)
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.primary).lineLimit(2)
            Spacer()
            Menu("导出…") {
                Button("网页草稿 TXT（与网页预览一致）") { exportDraft(asJSON: false) }
                Button("网页草稿 JSON（与网页预览一致）") { exportDraft(asJSON: true) }
                    .disabled(usingEditedCopy)
                Divider()
                Button("完整反馈 TXT（包含问题和完整日志）") {
                    export(draft.fullText, extension: "txt", name: "NVCodecTest-feedback-full")
                }
                Button("完整脱敏日志 TXT（手动附件）") {
                    if let selected = selected { export(selected.redactedText, extension: "txt", name: "NVCodecTest-log-redacted") }
                }.disabled(selected == nil)
                Button("完整脱敏诊断 JSON（手动附件）") {
                    if let json = selected?.redactedJSON { export(json, extension: "json", name: "NVCodecTest-diagnostic-redacted") }
                }.disabled(selected?.redactedJSON == nil)
            }
            Menu("复制反馈") {
                Button("复制网页草稿正文") { copy(draft.body, notice: "已复制网页草稿正文，与网页预览一致") }
                Button("复制完整反馈正文") { copy(draft.fullBody, notice: "已复制完整反馈；可在 GitHub 网页手动粘贴") }
            }
            Button(previewTab == .draft ? "前往 GitHub 确认…" : "查看网页草稿", action: openGitHub)
                .buttonStyle(NativeButtonStyle(prominent: true))
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func reloadHistory(firstLoad: Bool = false) {
        guard let refresh = refreshHistory, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try refresh().sorted { $0.createdAt > $1.createdAt } }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let items):
                    historyItems = items
                    if (!hasLoadedHistory || firstLoad), let latest = items.first { selectedID = latest.id }
                    else if !diagnostics.contains(where: { $0.id == selectedID }) { selectedID = diagnostics.first?.id ?? "" }
                    hasLoadedHistory = true
                case .failure(let error):
                    activeAlert = .error("无法读取日志：" + DiagnosticRedactor.redact(error.localizedDescription))
                }
            }
        }
    }

    private func makeAlert(_ alert: FeedbackAlert) -> Alert {
        switch alert {
        case .error(let message):
            return Alert(title: Text("操作未完成"), message: Text(message), dismissButton: .default(Text("知道了")))
        case .delete(let id):
            return Alert(title: Text("删除所选本机日志？"), message: Text("已导出的文件和 GitHub 内容不受影响；运行中的记录会由存储层保护。"),
                primaryButton: .destructive(Text("删除"), action: {
                    performHistoryChange { try deleteDiagnostic?(id) }
                }), secondaryButton: .cancel(Text("保留")))
        case .clear:
            return Alert(title: Text("清空可删除的历史日志？"), message: Text("只清理本机记录；运行中的记录由存储层决定是否保留。"),
                primaryButton: .destructive(Text("清空"), action: {
                    performHistoryChange { try clearHistory?() }
                }), secondaryButton: .cancel(Text("保留")))
        }
    }

    private func performHistoryChange(_ change: @escaping () throws -> Void) {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try change() }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success: operationNotice = "本机日志已更新"; reloadHistory()
                case .failure(let error): activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription))
                }
            }
        }
    }

    private func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { operationNotice = notice }
        else { activeAlert = .error("无法写入剪贴板，请重试。") }
    }

    private func exportDraft(asJSON: Bool) {
        do {
            let text = try asJSON ? GitHubFeedback.draftJSON(draft) : draft.text
            export(text, extension: asJSON ? "json" : "txt", name: "NVCodecTest-GitHub-draft")
        } catch { activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    private func export(_ text: String, extension fileExtension: String, name: String) {
        let exceedsAttachmentLimit = text.utf8.count > GitHubFeedback.maximumAttachmentBytes
        let panel = NSSavePanel()
        panel.allowedFileTypes = [fileExtension]
        panel.nameFieldStringValue = name + "." + fileExtension
        panel.title = "导出已预览的脱敏内容"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            operationNotice = exceedsAttachmentLimit
                ? "已完整导出，文件超过 GitHub 普通附件的 25 MB 限制；尚未上传，请在网页另行说明"
                : "已导出脱敏文件；尚未向 GitHub 上传"
        } catch { activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    private func openGitHub() {
        // 即将传给浏览器的内容始终先显示在“网页草稿”标签中；不会调用 GitHub API。
        guard previewTab == .draft else {
            previewTab = .draft
            operationNotice = "已切换到将打开的网页草稿；检查后再点击“前往 GitHub 确认”"
            return
        }
        let target = draft.url ?? GitHubFeedback.newIssueURL
        if NSWorkspace.shared.open(target) {
            operationNotice = draft.url == nil
                ? "已打开空白 issue 页面；请手动复制完整反馈"
                : "已打开 GitHub 草稿，尚未提交或上传附件"
        } else { activeAlert = .error("无法打开默认浏览器。可复制反馈后手动前往 github.com/GeekAudio/NVCodecTest/issues/new。") }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// macOS 11 也支持选择和复制的只读预览，不依赖后续系统的 Text.textSelection。
private struct FeedbackTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        view.defaultParagraphStyle = paragraph
        view.textColor = NSColor.labelColor
        view.backgroundColor = NSColor.textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
    }
}

/// 编辑仅生成当前反馈副本，应用后重新脱敏；不回写历史日志或原诊断 JSON。
private struct FeedbackLogEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.displayScale) private var displayScale
    private var hairline: CGFloat { 1 / max(displayScale, 1) }
    @State private var text: String
    @State private var applying = false
    @State private var errorMessage: String?
    let original: FeedbackDiagnostic?
    let apply: (FeedbackDiagnostic) -> Void

    init(text: String, original: FeedbackDiagnostic?, apply: @escaping (FeedbackDiagnostic) -> Void) {
        _text = State(initialValue: text)
        self.original = original
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("删减本次反馈的日志副本").font(DesignTokens.Font.title2.weight(.semibold))
            Text("可删除你不愿公开的内容。应用时会再次脱敏，并以此副本生成预览、复制内容和 TXT 导出；原本机日志不变，原诊断 JSON 将禁用。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            TextEditor(text: $text).font(DesignTokens.Font.small).disabled(applying)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.sep, lineWidth: hairline))
            if let message = errorMessage {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(DesignTokens.Text.primary).padding(4)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                            .fill(DesignTokens.Status.error.opacity(DesignTokens.Status.backgroundOpacity)))
                        .accessibilityHidden(true)
                    Text(message).foregroundColor(DesignTokens.Text.primary)
                }.font(DesignTokens.Font.small)
            }
            HStack {
                if applying { ProgressView("正在脱敏副本，请稍候…").font(DesignTokens.Font.small) }
                else { Text("请保留关键错误码与复现信息，避免删去诊断上下文。")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary) }
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("应用删减副本", action: applyCopy).disabled(applying)
                    .buttonStyle(NativeButtonStyle(prominent: true))
            }
        }.padding(20).frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 590)
            .font(DesignTokens.Font.body).lineSpacing(2)
            .foregroundColor(DesignTokens.Text.primary)
            .background(DesignTokens.Surface.window)
            .buttonStyle(NativeButtonStyle(prominent: false))
    }

    private func applyCopy() {
        guard let original = original else { errorMessage = "原记录已不可用，请取消后重新选择日志。"; return }
        applying = true
        errorMessage = nil
        let editedText = text
        DispatchQueue.global(qos: .utility).async {
            let document = FeedbackDiagnostic(id: original.id, title: original.title, createdAt: original.createdAt,
                redactedText: editedText, redactedJSON: nil,
                summary: "已使用用户删减后的脱敏 TXT 副本；本次反馈不包含原诊断 JSON。",
                sourceDescription: "本次反馈副本（原本机记录未修改）", isLocalRecord: original.isLocalRecord)
            DispatchQueue.main.async { applying = false; apply(document) }
        }
    }
}
