import Foundation

/// 预览、导出和网页草稿共用的已脱敏诊断。构造时再次脱敏，避免调用方绕过预览层。
struct FeedbackDiagnostic: Identifiable {
    let id: String
    let title: String
    let createdAt: Date
    let redactedText: String
    let redactedJSON: String?
    let summary: String
    let hasStructuredSummary: Bool
    let sourceDescription: String
    let isLocalRecord: Bool

    init(id: String, title: String, createdAt: Date, redactedText: String,
         redactedJSON: String?, summary: String, sourceDescription: String = "", isLocalRecord: Bool = false) {
        self.id = id
        self.title = DiagnosticRedactor.redact(title)
        self.createdAt = createdAt
        let safeText = DiagnosticRedactor.redact(redactedText)
        self.redactedText = safeText
        let safeJSON = redactedJSON.flatMap { try? DiagnosticRedactor.redactJSON($0) }
        self.redactedJSON = safeJSON
        // 只从当前文档自己的 JSON 提取摘要；用户删减副本没有 JSON，绝不回读原报告。
        let safeSummary = DiagnosticRedactor.redact(summary)
        let compact = safeJSON.flatMap { CompactDiagnosticSummary.make(reportJSON: $0, recentLog: safeText) }
        self.hasStructuredSummary = compact != nil
        self.summary = compact.map { (safeSummary.isEmpty ? "" : "SESSION=" + safeSummary + "\n") + $0 } ?? safeSummary
        self.sourceDescription = DiagnosticRedactor.redact(sourceDescription)
        self.isLocalRecord = isLocalRecord
    }
}

/// 已脱敏报告的纯 Foundation 投影；不依赖 CodecReport 或硬件框架，不把“未确认”写成“非 NVIDIA”。
enum CompactDiagnosticSummary {
    static func make(reportJSON: String, recentLog: String = "") -> String? {
        guard let report = (try? JSONSerialization.jsonObject(with: Data(reportJSON.utf8))) as? [String: Any],
              report["environment"] is [[String: Any]] || report["results"] is [[String: Any]] ||
                report["appVersion"] != nil || report["driverReport"] is [String: Any] else { return nil }
        let environment = report["environment"] as? [[String: Any]] ?? []
        func environmentRow(_ aliases: [String]) -> [String: Any]? {
            environment.first { row in
                guard let key = row["key"] as? String else { return false }
                return aliases.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
            }
        }
        func environmentValue(_ aliases: [String]) -> String {
            string(environmentRow(aliases)?["value"]) ?? "unreported"
        }
        let model = environmentValue(["机型", "系统机型", "hw.model", "model", "system model"])
        let cpu = environmentRow(["CPU", "processor", "处理器"])
        let logical = environmentRow(["逻辑处理器", "logical processors", "logicalCPU"])?["value"]
        let logicalText = string(logical) ?? firstMatch(string(cpu?["note"]) ?? "", pattern: #"\d+(?=\s*(?:个逻辑|logical))"#) ?? "unreported"
        let runState = bool(report["wasCancelled"]) == true ? "cancelled" : state(string(report["runState"]) ?? "unreported")
        var lines = [
            "APP=\(string(report["appVersion"]) ?? "unreported") STATE=\(runState)",
            "MODEL=\(model) (SMBIOS/system-reported)",
            "CPU=\(string(cpu?["value"]) ?? "unreported") logical=\(logicalText)",
            "RAM=\(environmentValue(["内存", "RAM", "memory"]))",
            "GPU=\(environmentValue(["GPU", "显卡"]))",
            "OS=\(environmentValue(["系统", "系统版本", "macOS", "OS", "system"])) ARCH=\(environmentValue(["架构", "architecture", "arch"]))",
        ]
        if let driver = report["driverReport"] as? [String: Any] {
            var line = "DRIVER=\(string(driver["state"]) ?? "unreported") v=\(string(driver["version"]) ?? "unreported")"
            if let installed = string(driver["installedVersion"]) { line += " disk=" + installed }
            lines.append(line)
        } else { lines.append("DRIVER=" + environmentValue(["NullMoth 驱动", "NullMoth driver", "driver"])) }
        let results = report["results"] as? [[String: Any]] ?? []
        if results.isEmpty { lines.append("RESULTS=not-tested") }
        else {
            lines.append("RESULTS: f=output/requested; sub=submitted/requested; HW=1/0/?; NV=confirmed/unconfirmed")
            lines += results.map(resultLine)
        }
        let base = DiagnosticRedactor.redact(lines.joined(separator: "\n"))
        // 事件可选；留出 URL 空间给环境、全部结果和用户问题，不以截断日志前缀代替真实摘要。
        let events = recentEvents(recentLog)
        let withEvents = base + (events.isEmpty ? "" : "\n" + events.joined(separator: "\n"))
        return encodedBytes(withEvents) <= 4_800 ? withEvents : base
    }

    private static func resultLine(_ row: [String: Any]) -> String {
        let group = string(row["group"]) ?? "?"
        let direction = group == "编码" || group.lowercased().contains("enc") ? "E" : (group == "解码" || group.lowercased().contains("dec") ? "D" : group)
        let item = (string(row["item"]) ?? "?").replacingOccurrences(of: "H.264", with: "H264")
        let mode = string(row["mode"]) ?? "?"
        let path = mode == "强制硬件" || mode.lowercased().contains("forced") ? "HW"
            : (mode.contains("软件") || mode.lowercased().contains("soft") ? "SW" : (mode.contains("自动") ? "AUTO" : mode))
        let status = state(string(row["status"]) ?? (bool(row["ok"]) == true ? "passed" : "unreported"))
        let stats = row["statistics"] as? [String: Any] ?? [:]
        let requested = integer(stats["requestedFrames"] ?? row["requestedFrames"])
        let frames = integer(stats["frames"] ?? row["frames"])
        let submitted = integer(stats["submittedFrames"] ?? row["submittedFrames"])
        let hardware = bool(row["hardwareAccelerated"]).map { $0 ? "1" : "0" } ?? "?"
        let nvidia = bool(row["isNVIDIAConfirmed"]) == true ? "confirmed" : "unconfirmed"
        let fps = (row["fps"] as? NSNumber).map { String(format: "%.1f", $0.doubleValue) } ?? "?"
        var line = "\(direction) \(item) \(path) \(status) fps=\(fps) f=\(frames)/\(requested) sub=\(submitted)/\(requested) HW=\(hardware) NV=\(nvidia)"
        if row["gpuRegistryID"] == nil || row["gpuRegistryID"] is NSNull { line += " GPU=unreported" }
        else if let vendor = row["gpuVendorID"] as? NSNumber { line += String(format: " GPUvendor=0x%04x", vendor.uint32Value) }
        else { line += " GPU=reported/vendor-unknown" }
        if let dropped = stats["droppedFrames"] as? NSNumber, dropped.intValue > 0 { line += " dropped=\(dropped.intValue)" }
        if ["failed", "unverified", "cancelled", "not-tested"].contains(status), let detail = string(row["detail"]) {
            let codes = matches(detail, pattern: #"(?<!\d)-\d{3,7}(?!\d)"#)
            if !codes.isEmpty { line += " OSStatus=" + Array(NSOrderedSet(array: codes)) .compactMap { $0 as? String }.joined(separator: ",") }
            let firstClause = detail.components(separatedBy: "；").first ?? ""
            if !firstClause.isEmpty && firstClause.utf8.count <= 120 { line += " err=" + firstClause }
            else {
                let tags = [("创建", "session-create"), ("提交", "submit"), ("回调", "callback"), ("排空", "drain"),
                            ("属性", "property"), ("素材", "input"), ("预热", "warmup"), ("取消", "cancelled")]
                line += " err=" + (tags.first { detail.contains($0.0) }?.1 ?? "see-full-log")
            }
        }
        return line
    }

    private static func state(_ value: String) -> String {
        switch value {
        case "成功", "通过": return "passed"
        case "失败": return "failed"
        case "未验证", "待验证": return "unverified"
        case "未测试", "尚未测试", "环境诊断，尚未测试": return "not-tested"
        case "取消", "已取消", "已取消，保留部分结果": return "cancelled"
        case "测试完成", "完整测试已完成": return "completed"
        case "部分结果": return "partial"
        default: return value
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    private static func integer(_ value: Any?) -> String { (value as? NSNumber).map { String($0.intValue) } ?? "?" }
    private static func bool(_ value: Any?) -> Bool? { value as? Bool }
    private static func firstMatch(_ text: String, pattern: String) -> String? { matches(text, pattern: pattern).first }
    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    private static func encodedBytes(_ value: String) -> Int {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "body", value: value)]
        return query.percentEncodedQuery?.utf8.count ?? Int.max
    }
    private static func recentEvents(_ log: String) -> [String] {
        var output: [String] = []
        let eventText = log.components(separatedBy: "【完整诊断快照 JSON】").first ?? log
        for line in eventText.split(separator: "\n").reversed() {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let phase = string(event["phase"]), let message = string(event["message"]) else { continue }
            let time = string(event["timestamp"]) ?? ""
            let text = "LOG \(time) \(phase): \(message)"
            if text.utf8.count <= 180 { output.append(DiagnosticRedactor.redact(text)) }
            else { output.append("LOG \(phase) (full message in process log)") }
            if output.count == 2 { break }
        }
        return output.reversed()
    }
}

struct GitHubIssueDraft {
    enum Delivery: Equatable {
        /// The URL carries the complete content that was prepared for this report.
        case complete
        /// The URL carries the problem and compact diagnostic summary; full logs need manual attachment.
        case summaryOnly
        /// The URL carries a placeholder; the user must add or paste the full content manually.
        case manual
    }

    /// title/body 是确切写入 URL 的字段；fullBody 保留完整问题和日志，供手动复制或附件导出。
    let delivery: Delivery
    let title: String
    let body: String
    let fullBody: String
    let url: URL?
    let requiresManualAttachment: Bool
    let notice: String
    let urlByteCount: Int

    var text: String { title + "\n\n" + body }
    var fullText: String { title + "\n\n" + fullBody }
}

enum GitHubFeedback {
    static let repository = "GeekAudio/NVCodecTest"
    static let repositoryURL = URL(string: "https://github.com/GeekAudio/NVCodecTest")!
    static let newIssueURL = URL(string: "https://github.com/GeekAudio/NVCodecTest/issues/new")!
    /// 本工具采用的保守兼容阈值；GitHub 官方仅说明过长 URL 会返回 414，未公布统一字节上限。
    static let defaultMaximumURLBytes = 7_000
    static let maximumAttachmentBytes = 25 * 1_000_000

    /// 纯构造函数：不联网、不打开浏览器、不创建 issue、不上传附件，也不需要 Token。
    static func makeDraft(title: String, problem: String, diagnostic: FeedbackDiagnostic?,
                          maxURLBytes: Int = defaultMaximumURLBytes) -> GitHubIssueDraft {
        let cleanTitle = DiagnosticRedactor.redact(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = cleanTitle.isEmpty ? "GPU-Z 问题反馈" : cleanTitle
        let cleanProblem = DiagnosticRedactor.redact(problem).trimmingCharacters(in: .whitespacesAndNewlines)
        let problemText = cleanProblem.isEmpty ? "请补充问题现象、复现步骤，以及期望结果。" : cleanProblem
        // FeedbackDiagnostic 的唯一初始化器已脱敏，且字段不可变。
        // 键入问题时不重复扫描整份日志；问题与标题仍在本次构造中脱敏。
        var intro = "## 问题现象\n\(problemText)\n\n## 诊断摘要\n"
        if let diagnostic = diagnostic {
            intro += diagnostic.summary.isEmpty ? "已选择一份脱敏诊断；以下日志保留完整记录。" : diagnostic.summary
            if !diagnostic.sourceDescription.isEmpty { intro += "\n记录来源：" + diagnostic.sourceDescription }
        } else {
            intro += "尚未选择诊断日志；此反馈只含填写的问题说明。"
        }
        let log = diagnostic?.redactedText ?? ""
        let fullBody = intro + (log.isEmpty ? "" : "\n\n## 完整脱敏日志\n" + fenced(log))
        if let url = issueURL(title: requestedTitle, body: fullBody, maxBytes: maxURLBytes) {
            return GitHubIssueDraft(delivery: .complete, title: requestedTitle, body: fullBody, fullBody: fullBody, url: url,
                requiresManualAttachment: false,
                notice: "将打开预填好的 GitHub 草稿；你仍需在网页检查并点击提交。文件不会自动附加。",
                urlByteCount: url.absoluteString.utf8.count)
        }

        // 以完整语义块降级，绝不截取日志或问题的任意前缀，避免改变错误含义。
        let summaryDescription = diagnostic?.hasStructuredSummary == true ? "环境/结果摘要" : "所填问题与当前日志摘要"
        let attachmentNote = "## 完整过程日志待手动附加\n已含\(summaryDescription)；完整过程日志未包含，尚未上传或自动附加。请导出完整脱敏 TXT/JSON，在 GitHub 网页手动添加；也可复制完整反馈正文粘贴。"
        let summaryBody = intro + "\n\n" + attachmentNote
        if let url = issueURL(title: requestedTitle, body: summaryBody, maxBytes: maxURLBytes) {
            return GitHubIssueDraft(delivery: .summaryOnly, title: requestedTitle, body: summaryBody, fullBody: fullBody, url: url,
                requiresManualAttachment: true,
                notice: "已默认加入当前可见的\(summaryDescription)。完整过程日志超过 URL 兼容阈值，需导出后手动附加。",
                urlByteCount: url.absoluteString.utf8.count)
        }

        // 问题或标题本身也可能过长：明确改用待补充说明，原文全部保留在完整反馈中。
        let minimalTitle = "GPU-Z 问题反馈（待补充完整内容）"
        let minimalBody = "## 待补充完整反馈\n问题说明、标题或诊断摘要过长，未通过 URL 传递。请从 GPU-Z 复制完整反馈正文并粘贴到这里；完整脱敏日志也可导出为 TXT/JSON 后手动添加。\n\n此处尚无完整日志或附件，打开网页不表示提交成功。"
        let preservedBody = "原拟标题：\(requestedTitle)\n\n" + fullBody
        let minimalURL = issueURL(title: minimalTitle, body: minimalBody, maxBytes: maxURLBytes)
        return GitHubIssueDraft(delivery: .manual, title: minimalTitle, body: minimalBody, fullBody: preservedBody, url: minimalURL,
            requiresManualAttachment: true,
            notice: minimalURL == nil
                ? "兼容阈值不足以容纳最短草稿，无法自动预填。可复制完整反馈后手动前往目标仓库新建 issue。"
                : "问题或摘要也超过 URL 兼容阈值；网页仅含待补充说明。原文未截断，请复制完整反馈或手动添加脱敏附件。",
            urlByteCount: minimalURL?.absoluteString.utf8.count ?? 0)
    }

    static func draftJSON(_ draft: GitHubIssueDraft, includeFullBody: Bool = false) throws -> String {
        let object = ["repository": repository, "title": draft.title,
                      "body": includeFullBody ? draft.fullBody : draft.body]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func issueURL(title: String, body: String, maxBytes: Int) -> URL? {
        // URL 编码不会缩短这两个字段；过长日志无需先生成数 MB 的编码字符串。
        guard title.utf8.count + body.utf8.count <= max(0, maxBytes) else { return nil }
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        // '+' 在 RFC URL query 中可以原样存在，但网页表单解析可能把它当空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.absoluteString.utf8.count <= max(0, maxBytes) else { return nil }
        return url
    }

    private static func fenced(_ text: String) -> String {
        let longestRun = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Int in
            var longest = 0, current = 0
            for character in line {
                if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
            }
            return longest
        }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return fence + "text\n" + text + "\n" + fence
    }
}
