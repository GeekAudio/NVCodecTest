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
            Divider()
            HStack(alignment: .top, spacing: 0) {
                historySidebar.frame(width: 228)
                Divider()
                feedbackBody.padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 850, idealWidth: 980, maxWidth: .infinity,
               minHeight: 650, idealHeight: 760, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
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
                .font(.system(size: 23)).foregroundColor(Color(NSColor.systemGreen))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("日志与 GitHub 反馈").font(.system(size: 19, weight: .semibold))
                Text("默认带上机型、驱动和测试日志摘要，检查后到 GeekAudio/NVCodecTest 网页确认提交。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机脱敏记录").font(.system(size: 12, weight: .semibold))
                Spacer()
                if loading { ProgressView().scaleEffect(0.55).frame(width: 18, height: 18) }
                Button(action: { reloadHistory() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PlainButtonStyle()).disabled(loading || refreshHistory == nil)
                    .help("重新读取本机日志，不会运行新的编解码测试")
            }
            if diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loading ? "正在读取…" : "尚无记录").font(.system(size: 12))
                    Text("完成环境扫描或测试后会自动记录。也可先填写问题现象。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }.padding(.top, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(diagnostics) { diagnostic in
                            Button(action: { selectedID = diagnostic.id; operationNotice = "" }) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(diagnostic.title).font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(Self.dateString(diagnostic.createdAt)).font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    if !diagnostic.sourceDescription.isEmpty {
                                        Text(diagnostic.sourceDescription).font(.system(size: 10))
                                            .foregroundColor(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(
                                    selected?.id == diagnostic.id ? Color(NSColor.selectedContentBackgroundColor).opacity(0.14)
                                    : Color(NSColor.controlBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                                    selected?.id == diagnostic.id ? Color(NSColor.keyboardFocusIndicatorColor).opacity(0.5)
                                    : Color.clear, lineWidth: 1))
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            if let notice = storageNotice, !notice.isEmpty {
                Text("日志留存提示：" + DiagnosticRedactor.redact(notice))
                    .font(.system(size: 10.5)).foregroundColor(Color(NSColor.systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("最近 20 次 · 最长 30 天 · 仅存本机。运行中的记录可能尚无完整报告；此处读取已落盘内容。")
                .font(.system(size: 10)).foregroundColor(.secondary)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("反馈标题").font(.system(size: 11, weight: .medium))
                TextField("概括发生的问题", text: $issueTitle).textFieldStyle(RoundedBorderTextFieldStyle())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("问题现象与复现步骤").font(.system(size: 11, weight: .medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $problem).font(.system(size: 12)).frame(height: 70)
                    if problem.isEmpty {
                        Text("例如：已安装驱动，但 H.264 硬编失败；点击开始后出现……")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
            }
            HStack(spacing: 10) {
                Picker("预览内容", selection: $previewTab) {
                    ForEach(PreviewTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(SegmentedPickerStyle()).labelsHidden()
                Text(ByteCountFormatter.string(fromByteCount: Int64(previewText.utf8.count), countStyle: .file))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                if usingEditedCopy {
                    Text("删减副本 · 仅 TXT").font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(NSColor.systemOrange))
                    Button("还原原日志") {
                        if let id = originalSelection?.id { editedLogs.removeValue(forKey: id) }
                        operationNotice = "已还原本机原日志；提交前请重新检查"
                    }.font(.system(size: 10.5))
                } else {
                    Text("可先删减日志副本；原本机记录保持不变").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button("删减日志副本…") {
                    guard let document = selected else { return }
                    logEditorID = document.id
                    logEditorText = document.redactedText
                    logEditorPresented = true
                }.font(.system(size: 10.5)).disabled(selected == nil)
            }
            FeedbackTextPreview(text: previewText)
                .frame(minHeight: 220, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor)))
            Text(draft.notice)
                .font(.system(size: 10.5))
                .foregroundColor(draft.requiresManualAttachment ? Color(NSColor.systemOrange) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("前往时会把网页草稿交给 GitHub，确认提交后公开。附件拖入网页时即会上传。")
                .font(.system(size: 10.5)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(operationNotice.isEmpty ? "无后台传输 · 无需维护者 Token" : operationNotice)
                .font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(2)
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
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
            Text("删减本次反馈的日志副本").font(.system(size: 18, weight: .semibold))
            Text("可删除你不愿公开的内容。应用时会再次脱敏，并以此副本生成预览、复制内容和 TXT 导出；原本机日志不变，原诊断 JSON 将禁用。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            TextEditor(text: $text).font(.system(size: 11, design: .monospaced)).disabled(applying)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
            if let message = errorMessage { Text(message).font(.system(size: 11)).foregroundColor(Color(NSColor.systemOrange)) }
            HStack {
                if applying { ProgressView("正在脱敏副本，请稍候…").font(.system(size: 10.5)) }
                else { Text("请保留关键错误码与复现信息，避免删去诊断上下文。")
                    .font(.system(size: 10.5)).foregroundColor(.secondary) }
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("应用删减副本", action: applyCopy).disabled(applying)
            }
        }.padding(20).frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 590)
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
