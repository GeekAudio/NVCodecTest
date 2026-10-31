import Foundation
import Darwin

/// Fixed fixtures only: URL construction never opens a browser or sends a request.
@main
struct FeedbackTests {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }
        check(MeasurementValidity.isValid(statusPassed: true, ok: true, fps: 0.1),
              "a positive finite FPS with passed status and ok is a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: false, ok: true, fps: 60),
              "a non-passed row cannot become a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: false, fps: 60),
              "a row with ok=false cannot become a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: 0),
              "zero FPS is not a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: -1),
              "negative FPS is not a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: .nan),
              "NaN FPS is not a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: .infinity),
              "infinite FPS is not a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: -.infinity),
              "negative infinite FPS is not a valid measurement")
        check(!MeasurementValidity.isValid(statusPassed: true, ok: true, fps: nil),
              "a missing FPS is not a valid measurement")
        func query(_ draft: GitHubIssueDraft) -> [String: String] {
            guard let url = draft.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
            return Dictionary(parts.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        }
        func validateDestination(_ draft: GitHubIssueDraft, maximum: Int) {
            guard let url = draft.url else { return }
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            check(parts?.scheme == "https" && parts?.host == "github.com", "issue URL uses the fixed HTTPS GitHub destination")
            check(parts?.path == "/GeekAudio/NVCodecTest/issues/new", "issue URL cannot change repository or endpoint")
            check(parts?.user == nil && parts?.password == nil && parts?.fragment == nil, "user content cannot become credentials or URL fragments")
            check(Set(parts?.queryItems?.map(\.name) ?? []) == Set(["title", "body"]), "user content cannot inject query parameters")
            check(url.absoluteString.utf8.count <= maximum, "encoded issue URL obeys the byte limit")
            check(draft.urlByteCount == url.absoluteString.utf8.count, "reported URL size matches the actual encoded URL")
            check(query(draft)["title"] == draft.title && query(draft)["body"] == draft.body, "URL contains exactly the visible title and body")
        }

        let title = "硬解归属待确认：中文 & #? + 100%"
        let problem = "H.264 已完成 120/120 帧。\n复现：先点开始，再看 UsingHardware=true。\n&labels=secret&assignees=someone # fragment ? a+b=100%"
        let diagnostic = FeedbackDiagnostic(id: "fixture-session", title: "固定测试日志", createdAt: Date(timeIntervalSince1970: 1_793_000_000),
            redactedText: "UsingHardware=true\ngpuRegistryID=18446744073709551610\ngpuVendorID=0x10de\n120/120 frames",
            redactedJSON: "{\"gpuRegistryID\":18446744073709551610,\"hardwareAccelerated\":true}",
            summary: "系统硬件成功，GPU 归属未确认", sourceDescription: "固定 fixture")
        let normal = GitHubFeedback.makeDraft(title: title, problem: problem, diagnostic: diagnostic)
        check(normal.delivery == .complete, "a complete URL draft reports complete payload delivery")
        check(normal.url != nil, "a small report produces a browser issue draft")
        check(!normal.requiresManualAttachment, "a small report does not request a missing attachment")
        check(normal.body == normal.fullBody, "small reports do not silently lose content")
        check(normal.body.contains("120/120") && normal.body.contains("UsingHardware=true"), "diagnostic evidence reaches the preview")
        check(normal.body.contains(problem), "newlines, punctuation and Chinese survive draft construction")
        check(normal.title.contains("中文") && normal.title.contains("100%"), "title text survives URL escaping")
        validateDestination(normal, maximum: 7000)

        let defaultTitle = GitHubFeedback.makeDraft(title: " \n\t", problem: "未填写标题", diagnostic: nil)
        check(defaultTitle.title == "GPU-Z 问题反馈", "an empty title uses the GPU-Z brand")
        check(GitHubFeedback.repository == "GeekAudio/NVCodecTest"
              && GitHubFeedback.newIssueURL.host == "github.com"
              && GitHubFeedback.newIssueURL.path == "/GeekAudio/NVCodecTest/issues/new",
              "GPU-Z branding leaves the GitHub repository and issue endpoint unchanged")

        let withoutLog = GitHubFeedback.makeDraft(title: "仅描述问题", problem: "没有可用日志", diagnostic: nil)
        check(withoutLog.url != nil && withoutLog.body.contains("没有可用日志"), "feedback works when logging is unavailable")
        check(!withoutLog.requiresManualAttachment, "missing diagnostics are not presented as an omitted attachment")
        validateDestination(withoutLog, maximum: 7000)

        let largeLog = FeedbackDiagnostic(id: "large-fixture", title: "长日志", createdAt: Date(timeIntervalSince1970: 1_793_000_000),
            redactedText: String(repeating: "硬件证据 UsingHardware=true，120/120 帧；\n", count: 600) + "LOG_END_SENTINEL",
            redactedJSON: nil, summary: "系统硬解成功，GPU 未确认")
        let large = GitHubFeedback.makeDraft(title: "长日志需要手动附加", problem: "保留这段问题描述", diagnostic: largeLog)
        check(large.delivery == .summaryOnly, "an oversized log reports summary-only payload delivery")
        check(large.requiresManualAttachment, "oversize diagnostics explicitly require manual attachment")
        check(large.fullBody.contains("LOG_END_SENTINEL"), "full-copy content keeps the end of an oversized log")
        check(!large.body.contains("LOG_END_SENTINEL"), "oversize logs are omitted from the URL rather than partially attached")
        check(large.body.contains("保留这段问题描述"), "the short draft retains a reasonably sized problem description")
        check(!large.notice.isEmpty && large.body != large.fullBody, "fallback is disclosed and has distinct full-copy content")
        validateDestination(large, maximum: 7000)

        let longProblem = String(repeating: "中文问题 &?+%\n", count: 1500) + "PROBLEM_END_SENTINEL"
        let long = GitHubFeedback.makeDraft(title: "超长问题", problem: longProblem, diagnostic: diagnostic)
        check(long.requiresManualAttachment, "an oversized problem also requires manual copying")
        check(long.fullBody.contains("PROBLEM_END_SENTINEL"), "full-copy content preserves an oversized problem without truncation")
        check(!long.notice.isEmpty, "oversized problem fallback is explained")
        validateDestination(long, maximum: 7000)

        let tiny = GitHubFeedback.makeDraft(title: "极小 URL 预算", problem: problem, diagnostic: diagnostic, maxURLBytes: 40)
        check(tiny.delivery == .manual, "a URL that cannot carry the summary reports manual delivery")
        check(tiny.url == nil, "an impossible URL budget disables opening instead of exceeding its limit")
        check(!tiny.notice.isEmpty && tiny.requiresManualAttachment, "no-URL fallback still exposes a useful manual path")
        check(tiny.fullBody.contains("120/120") && tiny.fullBody.contains(problem), "no-URL fallback retains full reviewable content")

        do {
            let previewJSON = try GitHubFeedback.draftJSON(large)
            let previewObject = try JSONSerialization.jsonObject(with: Data(previewJSON.utf8)) as? [String: String]
            check(previewObject?["title"] == large.title && previewObject?["body"] == large.body,
                  "preview JSON export contains exactly the webpage draft rather than omitted full logs")
            let fullJSON = try GitHubFeedback.draftJSON(large, includeFullBody: true)
            let fullObject = try JSONSerialization.jsonObject(with: Data(fullJSON.utf8)) as? [String: String]
            check(fullObject?["body"] == large.fullBody, "full-copy JSON export preserves the full reviewable log")
        } catch { check(false, "draft JSON export must be valid JSON") }

        let markdownLog = FeedbackDiagnostic(id: "markdown-fixture", title: "Markdown", createdAt: Date(),
            redactedText: "before\n```\n# fixture log text, not a heading\n```\nafter", redactedJSON: nil, summary: "固定日志")
        let markdown = GitHubFeedback.makeDraft(title: "保留日志原文", problem: "代码围栏边界", diagnostic: markdownLog)
        check(markdown.fullBody.contains("````text\n") && markdown.fullBody.contains(markdownLog.redactedText),
              "log backticks cannot break out of the diagnostic Markdown fence")

        let malicious = GitHubFeedback.makeDraft(title: "问题 token=FIXTURE_TITLE_SECRET", problem: "Authorization: Bearer FIXTURE_BEARER_SECRET\n/Users/fixture-private-user/Documents/private.txt", diagnostic: nil)
        let maliciousOutputs = malicious.title + malicious.body + malicious.fullBody + (malicious.url?.absoluteString ?? "")
        check(!maliciousOutputs.contains("FIXTURE_TITLE_SECRET"), "title secrets cannot bypass redaction through URL construction")
        check(!maliciousOutputs.contains("FIXTURE_BEARER_SECRET"), "problem credentials cannot bypass redaction through URL construction")
        check(!maliciousOutputs.contains("fixture-private-user"), "problem user paths are redacted before preview and URL construction")

        do {
            // Match the saved CodecReport schema instead of passing a prewritten summary.
            let environment: [[String: Any]] = [
                ["key": "机型", "value": "MacPro7,1", "ok": true, "note": "系统报告的 SMBIOS 机型，可能由引导配置指定"],
                ["key": "CPU", "value": "Intel Core i9-10900K", "ok": true, "note": "固定 fixture"],
                ["key": "内存", "value": "64 GiB", "ok": true, "note": ""],
                ["key": "GPU", "value": "NVIDIA GeForce RTX 3080 Ti", "ok": true, "note": ""],
                ["key": "系统", "value": "macOS 26.1.0 (25B85)", "ok": true, "note": ""],
                ["key": "架构", "value": "x86_64", "ok": true, "note": ""],
                ["key": "NullMoth 驱动", "value": "已加载 · 3.4.0", "ok": true, "note": "已加载版本"],
                ["key": "boot-args", "value": "-v serial=FIXTURE_SUMMARY_SERIAL token=FIXTURE_SUMMARY_TOKEN", "ok": true, "note": ""]
            ]
            func result(group: String, item: String, mode: String, successful: Bool, fps: Double,
                        hardware: Bool, attribution: String, nvidia: Bool, error: String = "") -> [String: Any] {
                let requested = item.contains("4K") ? 48 : 120
                return ["group": group, "item": item, "mode": mode, "ok": successful, "fps": fps,
                        "engine": "fixture engine", "detail": error.isEmpty ? "\(requested)/\(requested) frames" : error,
                        "status": successful ? "成功" : "失败", "hardwareAccelerated": hardware,
                        "encoderID": group == "编码" && hardware ? "com.nvmtl.videoencoder.\(item.contains("H.264") ? "avc" : "hevc").nvenc" : "",
                        "gpuName": nvidia ? "NVIDIA GeForce RTX 3080 Ti" : "", "attribution": attribution,
                        "isNVIDIAConfirmed": nvidia, "hardwareEvidence": "UsingHardware=\(hardware)",
                        "gpuEvidence": attribution == "systemHardwareUnknownGPU" ? "UsingGPURegistryID 未提供；GPU 未确认" : "fixture attribution",
                        "nvidiaEvidence": nvidia ? "NVMTL encoder identity" : "NVIDIA 归属未确认",
                        "warningText": "固定 fixture", "statistics": ["frames": successful ? requested : 0,
                            "requestedFrames": requested, "submittedFrames": successful ? requested : 0,
                            "droppedFrames": 0, "elapsed": successful ? 0.5 : 0, "measurementCount": 3,
                            "fpsMin": fps, "fpsMax": fps, "bytesPerFrame": 32768]]
            }
            let results = [
                result(group: "编码", item: "H.264 1080p", mode: "强制硬件", successful: true, fps: 240, hardware: true, attribution: "nvidiaConfirmed", nvidia: true),
                result(group: "编码", item: "H.264 1080p", mode: "软件编码", successful: true, fps: 80, hardware: false, attribution: "software", nvidia: false),
                result(group: "编码", item: "H.264 4K", mode: "强制硬件", successful: true, fps: 96, hardware: true, attribution: "nvidiaConfirmed", nvidia: true),
                result(group: "编码", item: "HEVC 1080p", mode: "强制硬件", successful: true, fps: 180, hardware: true, attribution: "nvidiaConfirmed", nvidia: true),
                result(group: "编码", item: "HEVC 1080p", mode: "软件编码", successful: true, fps: 20, hardware: false, attribution: "software", nvidia: false),
                result(group: "编码", item: "HEVC 4K", mode: "强制硬件", successful: false, fps: 0, hardware: true, attribution: "unknown", nvidia: false,
                       error: String(repeating: "固定准备证据 ", count: 40) + "VTCompressionSessionCreate OSStatus -12913"),
                result(group: "解码", item: "H.264 1080p", mode: "强制硬件", successful: false, fps: 0, hardware: true, attribution: "systemHardwareUnknownGPU", nvidia: false, error: "decode warm-up OSStatus -12909"),
                result(group: "解码", item: "H.264 1080p", mode: "软件解码", successful: true, fps: 600, hardware: false, attribution: "software", nvidia: false),
                result(group: "解码", item: "HEVC 1080p", mode: "强制硬件", successful: true, fps: 360, hardware: true, attribution: "systemHardwareUnknownGPU", nvidia: false)
            ]
            let schemaReport: [String: Any] = ["schemaVersion": 1, "appVersion": "1.3.0", "createdAt": "2026-10-25T03:00:00Z",
                "environmentCapturedAt": "2026-10-25T02:59:00Z", "target": "Hackintosh NVIDIA / NullMoth VideoToolbox",
                "runState": "测试完成", "wasCancelled": false, "environment": environment,
                "driverReport": ["state": "loaded", "version": "3.4.0", "versionSource": "已加载 NVRM",
                    "installedVersion": "3.5.0", "installedVersionSource": "NVRM.kext", "warnings": [],
                    "evidence": ["markerPresent": true, "markerVersion": "3.5.0", "installedComponents": [],
                        "loadedKexts": [["identifier": "com.nullmoth.NVRM", "version": "3.4.0"]],
                        "registeredEncoderIDs": ["com.nvmtl.videoencoder.hevc.nvenc"], "loadedProbeSucceeded": true,
                        "encoderProbeSucceeded": true, "architecture": "x86_64", "nvidiaPCIPresent": true, "probeErrors": []]],
                "encoders": [], "results": results, "methodology": "固定测试方法 fixture"]
            let schemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: schemaReport, options: [.sortedKeys]), as: UTF8.self)
            let fullProcessLog = String(repeating: "阶段事件：固定驱动调用与帧输出证据\n", count: 900)
                + "{\"timestamp\":\"2026-10-25T03:00:01Z\",\"phase\":\"benchmark\",\"message\":\"FIXTURE_RECENT_DECODE_PHASE\"}\n"
                + "{\"timestamp\":\"2026-10-25T03:00:02Z\",\"phase\":\"result\",\"message\":\"FIXTURE_RECENT_RESULT_PHASE\"}\nFULL_PROCESS_LOG_END"
            let rich = FeedbackDiagnostic(id: "schema-fixture", title: "完整九项测试", createdAt: Date(timeIntervalSince1970: 1_793_000_000),
                redactedText: fullProcessLog, redactedJSON: schemaJSON, summary: "测试完成", sourceDescription: "固定本机日志")
            let richDraft = GitHubFeedback.makeDraft(title: "硬解异常", problem: "预热失败，求排查", diagnostic: rich)
            check(richDraft.url != nil && richDraft.requiresManualAttachment, "a real-schema report supplies useful URL diagnostics while the long process log remains an attachment")
            for value in ["MacPro7,1", "i9-10900K", "64 GiB", "RTX 3080 Ti", "macOS 26.1.0", "x86_64", "3.4.0", "1.3.0"] {
                check(richDraft.body.contains(value), "default webpage draft includes hardware or version evidence: " + value)
                check(query(richDraft)["body"]?.contains(value) == true, "encoded webpage URL includes hardware or version evidence: " + value)
            }
            check(richDraft.body.contains("-12909") && richDraft.body.contains("-12913"), "default URL summary keeps distinct original OSStatus failures")
            check(richDraft.body.contains("120/120") && richDraft.body.contains("48/48"), "default URL summary includes measured frame completion rather than an empty completed label")
            check(richDraft.body.contains("240") && richDraft.body.contains("360") && richDraft.body.lowercased().contains("fps"), "default URL summary includes actual throughput")
            check((richDraft.body.contains("失败") || richDraft.body.contains("failed"))
                  && (richDraft.body.contains("GPU 未确认") || richDraft.body.contains("GPU未确认") || richDraft.body.contains("GPU=unreported")),
                  "failed tests and successful hardware with unknown GPU stay distinct in the compact summary")
            check((richDraft.body.contains("软件编码") || richDraft.body.contains("E H264 1080p SW"))
                  && (richDraft.body.contains("软件解码") || richDraft.body.contains("D H264 1080p SW"))
                  && richDraft.body.contains("HEVC 4K"), "all nine planned test modes remain represented in the summary")
            check(richDraft.body.contains("SMBIOS"), "the model is identified as a system-reported SMBIOS value")
            check(richDraft.body.contains("3.4.0") && richDraft.body.contains("3.5.0"), "loaded and installed driver versions remain separate evidence")
            check(richDraft.body.contains("FIXTURE_RECENT_DECODE_PHASE") && richDraft.body.contains("FIXTURE_RECENT_RESULT_PHASE"),
                  "the default URL includes recent persisted process events alongside measured results")
            check(richDraft.fullBody.contains("FULL_PROCESS_LOG_END") && rich.redactedText.contains("FULL_PROCESS_LOG_END"), "complete original process logs remain available for review and export after URL fallback")
            check(!richDraft.body.contains("FULL_PROCESS_LOG_END"), "the compact default URL does not pretend it includes the omitted full process log")
            check(!richDraft.fullBody.contains("FIXTURE_SUMMARY_SERIAL") && !richDraft.fullBody.contains("FIXTURE_SUMMARY_TOKEN"), "building a richer default summary does not reintroduce private boot arguments")
            validateDestination(richDraft, maximum: 7000)
            let edited = FeedbackDiagnostic(id: rich.id, title: "删减后的日志", createdAt: rich.createdAt,
                redactedText: "仅保留 UsingHardware=true 和 OSStatus -12909", redactedJSON: nil,
                summary: "用户已删减的副本", sourceDescription: "本机编辑的脱敏副本")
            let editedDraft = GitHubFeedback.makeDraft(title: "删减日志反馈", problem: "保留这些信息即可", diagnostic: edited)
            let editedOutput = editedDraft.body + editedDraft.fullBody + (editedDraft.url?.absoluteString ?? "")
            for removed in ["MacPro7,1", "i9-10900K", "64 GiB", "RTX 3080 Ti", "25B85", "3.4.0", "1.3.0", "FULL_PROCESS_LOG_END"] {
                check(!editedOutput.contains(removed), "an edited nil-JSON copy cannot recover removed source information: " + removed)
            }
            check(editedDraft.body.contains("UsingHardware=true") && editedDraft.body.contains("-12909"), "editing the diagnostic still retains the user-chosen evidence")
            let richLongProblem = GitHubFeedback.makeDraft(title: "完整问题不要截断", problem: longProblem, diagnostic: rich)
            check(richLongProblem.fullBody.contains("PROBLEM_END_SENTINEL") && richLongProblem.fullBody.contains("FULL_PROCESS_LOG_END"), "oversized problem fallback preserves both the complete original problem and process log")
            validateDestination(richLongProblem, maximum: 7000)
            let earlyCancellation = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.3.0\",\"wasCancelled\":true,\"results\":[{\"group\":\"解码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"未测试\",\"ok\":false}]}") ?? ""
            check(earlyCancellation.contains("STATE=cancelled") && earlyCancellation.contains("not-tested"), "early-cancelled summaries retain both run cancellation and untested row status")
            check(earlyCancellation.contains("f=?/?") && earlyCancellation.contains("HW=?"), "missing measurements remain unknown instead of invented zero-frame or hardware results")
            let invalidPassed = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"HEVC 1080p\",\"mode\":\"强制硬件\",\"status\":\"成功\",\"ok\":true,\"fps\":0,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let invalidPassedLine = invalidPassed.components(separatedBy: "\n").first { $0.hasPrefix("E HEVC 1080p") } ?? ""
            check(invalidPassedLine.contains("unverified fps=?"), "a passed row with zero FPS is projected as unverified without a reported result FPS")
            check(invalidPassedLine.contains("raw_status=成功 raw_ok=true raw_fps=0.0"), "an invalid passed row keeps short raw status, ok, and FPS clues")
            check(invalidPassedLine.contains("NV=unconfirmed") && !invalidPassedLine.contains("NV=confirmed"), "invalid measurements cannot confirm NVIDIA attribution")
            let booleanFPS = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":true,\"fps\":true,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let booleanFPSLine = booleanFPS.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(booleanFPSLine.contains("unverified fps=?") && booleanFPSLine.contains("raw_fps=true"), "a JSON boolean is not accepted as numeric FPS")
            check(booleanFPSLine.contains("NV=unconfirmed"), "boolean FPS cannot confirm NVIDIA attribution")
            let numericOK = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":1,\"fps\":10,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let numericOKLine = numericOK.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(numericOKLine.contains("unverified fps=?") && numericOKLine.contains("raw_ok=1.0"), "a JSON number is not accepted as the result ok flag")
            let missingOK = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"fps\":10}]}") ?? ""
            let missingOKLine = missingOK.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(missingOKLine.contains("unverified fps=?") && missingOKLine.contains("raw_ok=unreported"), "a missing ok flag leaves the passed row unverified")
            let missingFPS = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":true}]}") ?? ""
            let missingFPSLine = missingFPS.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(missingFPSLine.contains("unverified fps=?") && missingFPSLine.contains("raw_fps=unreported"), "a missing FPS leaves the passed row unverified")
            let missingStatus = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"ok\":true,\"fps\":10,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let missingStatusLine = missingStatus.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(missingStatusLine.contains("unreported fps=?") && missingStatusLine.contains("raw_status=unreported raw_ok=true raw_fps=10.0"), "a missing status is not inferred as passed and retains raw ok/FPS clues")
            check(missingStatusLine.contains("NV=unconfirmed"), "a missing status cannot confirm NVIDIA attribution")
            let numericHardware = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":true,\"fps\":10,\"hardwareAccelerated\":1,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let numericHardwareLine = numericHardware.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(numericHardwareLine.contains("fps=10.0") && numericHardwareLine.contains("HW=? NV=unconfirmed"), "numeric hardware flags are not accepted as JSON booleans")
            let numericNVIDIA = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"编码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":true,\"fps\":10,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":1}]}") ?? ""
            let numericNVIDIALine = numericNVIDIA.components(separatedBy: "\n").first { $0.hasPrefix("E H264 1080p") } ?? ""
            check(numericNVIDIALine.contains("HW=1 NV=unconfirmed"), "a numeric NVIDIA flag is not accepted as a JSON boolean")
            let negativePassed = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"解码\",\"item\":\"H.264 1080p\",\"mode\":\"强制硬件\",\"status\":\"passed\",\"ok\":true,\"fps\":-2,\"hardwareAccelerated\":true,\"isNVIDIAConfirmed\":true}]}") ?? ""
            let negativePassedLine = negativePassed.components(separatedBy: "\n").first { $0.hasPrefix("D H264 1080p") } ?? ""
            check(negativePassedLine.contains("unverified fps=?") && negativePassedLine.contains("raw_fps=-2.0"), "negative FPS remains diagnostic raw evidence but not an effective measurement")
            check(negativePassedLine.contains("NV=unconfirmed"), "negative FPS cannot produce confirmed NVIDIA attribution")
            let failedRow = CompactDiagnosticSummary.make(reportJSON: "{\"appVersion\":\"1.6.1\",\"results\":[{\"group\":\"解码\",\"item\":\"HEVC 1080p\",\"mode\":\"强制硬件\",\"status\":\"失败\",\"ok\":false,\"fps\":-1}]}") ?? ""
            check(failedRow.contains("D HEVC 1080p HW failed fps=?"), "failed status stays failed and does not expose invalid FPS")
        } catch { check(false, "schema-based default feedback fixture must remain valid") }

        if failures.isEmpty {
            print("Feedback fixtures: \(checks) checks passed (offline, no uploads)")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("Feedback fixtures: \(failures.count)/\(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
