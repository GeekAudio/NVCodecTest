import Foundation
import Darwin

// MARK: - 脱敏（无 AppKit / VideoToolbox 依赖）

/// 同一脱敏器供落盘、预览、复制和反馈复用。先处理结构化敏感键，再处理文本中的值。
enum DiagnosticRedactor {
    static let replacement = "[REDACTED]"
    private static let expressionLock = NSLock()
    private static var expressions: [String: NSRegularExpression] = [:]

    /// 固定规则只编译一次；不可变表达式可跨线程复用，缓存访问由锁保护。
    private static func expression(_ pattern: String) -> NSRegularExpression? {
        expressionLock.lock(); defer { expressionLock.unlock() }
        if let cached = expressions[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        expressions[pattern] = compiled
        return compiled
    }

    private static func containsMatch(_ text: String, _ pattern: String) -> Bool {
        expression(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = expression(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func redact(_ text: String) -> String {
        // 调用方误将 JSON 当文本传入时，仍按敏感键递归处理。
        if let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           object is [String: Any] || object is [Any],
           let data = try? JSONSerialization.data(withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys]),
           let output = String(data: data, encoding: .utf8) { return output }
        var output = text
        output = redactBootArgumentLines(output)
        // 引号包裹的路径可能包含空格，先整体处理；系统 /Library 路径仍保留。
        output = replace(output, #"(?i)(["'])(?:file://)?/(?:Users|home|Volumes|private/var/folders|var/folders)/[^"'\r\n]*\1"#, "\"[USER_PATH]\"")
        output = replace(output, #"(?i)(?:file://)?/(?:Users|home|Volumes|private/var/folders|var/folders)/[^\r\n,;"'<>]*?(?=\s+[A-Za-z_][A-Za-z0-9_.\-]*\s*=|[\r\n,;"'<>]|$)"#, "[USER_PATH]")
        output = replace(output, #"(?i)(["'])~[/\\][^"'\r\n]*\1"#, "\"[USER_PATH]\"")
        output = replace(output, #"~[/\\][^\s,;"'<>]+"#, "[USER_PATH]")
        output = replace(output, #"(?i)[A-Z]:\\Users\\[^\r\n,;"'<>]+"#, "[USER_PATH]")

        output = replace(output, #"(?i)(authorization\s*[=:]\s*)(?:bearer|basic)\s+[^\s,;"']+"#, "$1[REDACTED]")
        output = replace(output, #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9_+/.=\-]{6,}"#, "[REDACTED]")
        let sensitiveAssignment = #"(?i)(["']?(?:[A-Za-z0-9_.\-]*(?:serial(?:number)?|uuid|token|password|passwd|secret|credential|authorization|cookie|account|username|email|mac[-_]?address|ip[-_]?address)[A-Za-z0-9_.\-]*|serial\s+number|api[-_ ]?key|private[-_ ]?key|auth|MLB|ROM|user|user\s+name|hostname|host\s+name|computername|computer\s+name|host|ip|mac|序列号|用户名|账户|密码|令牌|邮箱|MAC地址|IP地址)["']?\s*(?:=|:)\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|(?:\\.|[^\s,;\r\n])+)"#
        output = replace(output, sensitiveAssignment, "$1[REDACTED]")
        output = replace(output, #"(?i)(\b(?:serial\s*(?:number)?|IOPlatformSerialNumber|SystemSerialNumber|MLB|ROM)\b\s+)[A-Za-z0-9_:\-]{5,}"#, "$1[REDACTED]")
        output = replace(output, #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{10,}|github_pat_[A-Za-z0-9_]{10,}|sk-(?:proj-)?[A-Za-z0-9_\-]{10,}|AKIA[A-Z0-9]{16})\b"#, replacement)
        output = replace(output, #"\b[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, replacement)
        output = replace(output, #"(?i)\b[A-Z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, replacement)
        output = replace(output, #"(?i)\b[A-Za-z0-9][A-Za-z0-9\-]*\.local\b"#, replacement)
        output = replace(output, #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, replacement)
        output = replace(output, #"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#, replacement)
        output = redactIPAddresses(output)
        return output
    }

    /// 仅公开明确不含身份信息的诊断参数；自定义引导参数不能依赖关键词猜测是否敏感。
    static func redactBootArguments(_ text: String) -> String {
        let flags: Set<String> = ["-v", "-nvrmnoflip", "-nv_disable", "-wegnoegpu", "-wegnoigpu",
                                  "-nvdbg", "-nvkmsnosmooth", "-no_compat_check"]
        let numericKeys: Set<String> = ["keepsyms", "debug", "nvda_drv", "nv_disable", "nvfb", "nvaccel",
                                        "nvfbheads", "nvrmsettle", "gfxrst", "npci", "nvda_drv_vrl"]
        guard let regex = expression(#"(?:[^\s"']+|"[^"\r\n]*"|'[^'\r\n]*')+"#) else { return replacement }
        let ns = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var safe: [String] = []
        var omitted = false
        for token in tokens {
            if flags.contains(token) { safe.append(token); continue }
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, numericKeys.contains(String(pair[0])),
               containsMatch(String(pair[1]), #"^-?(?:0x[0-9a-fA-F]+|[0-9]+)$"#) {
                safe.append(token)
            } else { omitted = true }
        }
        if omitted { safe.append("[OTHER_BOOT_ARGS_REDACTED]") }
        return safe.joined(separator: " ")
    }

    private static func isBootArgumentsKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "bootargs" || normalized == "kernbootargs"
    }

    private static func redactBootArgumentLines(_ text: String) -> String {
        guard let regex = expression(#"(?i)\b(?:kern[.])?boot[-_. ]?args["']?(?:\s*[:=：]\s*|\s+)"#) else { return text }
        return text.components(separatedBy: "\n").map { line in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            let end = match.range.location + match.range.length
            return ns.substring(to: end) + redactBootArguments(ns.substring(from: end))
        }.joined(separator: "\n")
    }

    private static func redactIPAddresses(_ text: String) -> String {
        guard let regex = expression(#"(?i)(?<![A-Za-z0-9_.:])[0-9a-f:.]+(?:%[A-Za-z0-9_.\-]+)?(?![A-Za-z0-9_.:])"#) else { return text }
        let ns = text as NSString
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let candidate = ns.substring(with: match.range)
            let address = candidate.components(separatedBy: "%").first ?? candidate
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            let isIPv4 = address.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
            let isIPv6 = address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
            guard isIPv4 || isIPv6 else { continue }
            // 纯版本字段可有四段数字；IP=... 等敏感赋值已在前一步移除。
            if isIPv4 {
                let prefix = ns.substring(with: NSRange(location: max(0, match.range.location - 24), length: min(24, match.range.location))).lowercased()
                if containsMatch(prefix, #"(?:version|版本)\s*[:=]?\s*$"#) { continue }
            }
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: replacement) }
        }
        return output
    }

    private static func sensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["user", "host", "ip", "mac", "rom", "mlb", "auth", "apikey", "privatekey"].contains(normalized) { return true }
        return ["serial", "uuid", "token", "password", "passwd", "secret", "credential", "authorization", "cookie",
                "account", "username", "hostname", "computername", "email", "macaddress", "ipaddress",
                "序列号", "用户名", "账户", "密码", "令牌", "邮箱"].contains { normalized.contains($0) }
    }

    private static func sanitize(_ value: Any, key: String? = nil) -> Any {
        if let key = key, sensitiveKey(key) { return replacement }
        if let key = key, isBootArgumentsKey(key) { return (value as? String).map(redactBootArguments) ?? replacement }
        if let dictionary = value as? [String: Any] {
            let labels = ["key", "name"].compactMap { dictionary[$0] as? String }
            let environmentBootArgs = labels.contains(where: isBootArgumentsKey)
            let environmentSensitive = labels.contains(where: sensitiveKey)
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                if environmentSensitive && pair.key == "value" { result[pair.key] = replacement }
                else if environmentBootArgs && pair.key == "value" {
                    result[pair.key] = (pair.value as? String).map(redactBootArguments) ?? replacement
                } else { result[pair.key] = sanitize(pair.value, key: pair.key) }
            }
        }
        if let array = value as? [Any] { return array.map { sanitize($0) } }
        if let string = value as? String {
            // 保留合法版本，不将 1.2.3.4 当 IP；值只允许版本字符，不能夹带账号或路径。
            if let key = key, key.lowercased().contains("version"),
               containsMatch(string, #"^\d+(?:\.\d+){1,4}(?:[+\-][A-Za-z0-9._\-]+)?$"#) { return string }
            return redact(string)
        }
        return value
    }

    static func redactJSON(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        let sanitized = sanitize(object)
        let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        guard let output = String(data: data, encoding: .utf8) else { throw DiagnosticLogError.invalidReport }
        return output
    }
}

// MARK: - 日志模型与限额

enum DiagnosticSessionState: String, Codable {
    case running, completed, cancelled, failed, interrupted
    var title: String {
        switch self {
        case .running: return "记录中"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "记录失败"
        case .interrupted: return "上次中断"
        }
    }
}

struct DiagnosticLogLimits {
    let maxSessions: Int
    let maxAgeDays: Int
    let maxTotalBytes: Int
    let maxEventBytes: Int
    let maxEventsBytes: Int
    let maxReportBytes: Int

    init(maxSessions: Int = 20, maxAgeDays: Int = 30, maxTotalBytes: Int = 20 * 1024 * 1024,
         maxEventBytes: Int = 8192, maxEventsBytes: Int = 512 * 1024, maxReportBytes: Int = 1024 * 1024) {
        self.maxSessions = max(1, maxSessions)
        self.maxAgeDays = max(1, maxAgeDays)
        self.maxTotalBytes = max(1024, maxTotalBytes)
        self.maxEventBytes = max(256, maxEventBytes)
        self.maxEventsBytes = max(512, maxEventsBytes)
        self.maxReportBytes = max(512, maxReportBytes)
    }
}

struct DiagnosticLogEntry: Identifiable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let state: DiagnosticSessionState
    let kind: String
    let url: URL
    let sizeBytes: Int
    let reportAvailable: Bool
}

enum DiagnosticLogError: LocalizedError {
    case invalidReport
    case invalidSession
    case sessionClosed
    case activeSession
    case eventTooLarge(limit: Int)
    case eventsLimitReached(limit: Int)
    case reportTooLarge(limit: Int)
    case storageLimitReached
    case unsafePath
    case lockFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidReport: return "诊断报告必须是有效的 UTF-8 JSON。"
        case .invalidSession: return "未找到有效的诊断会话。"
        case .sessionClosed: return "诊断会话已结束，不能继续写入。"
        case .activeSession: return "正在记录的诊断会话不能删除。"
        case .eventTooLarge(let limit): return "单条诊断事件超过 \(limit) 字节，未写入。"
        case .eventsLimitReached(let limit): return "本会话事件日志达到 \(limit) 字节上限，原记录已保留。"
        case .reportTooLarge(let limit): return "诊断报告超过 \(limit) 字节上限，原快照已保留。"
        case .storageLimitReached: return "诊断留存空间已满，活跃会话受到保护，无法继续写入。"
        case .unsafePath: return "诊断目录包含不安全的路径或符号链接，已停止写入。"
        case .lockFailed(let code): return "无法锁定诊断日志（系统错误 \(code)）。"
        }
    }
}

private struct DiagnosticManifest: Codable {
    let id: String
    let createdAt: Date
    var updatedAt: Date
    var state: DiagnosticSessionState
    let kind: String
    let version: String
    let ownerPID: Int32
    var eventCount: Int
}

private struct DiagnosticEvent: Codable {
    let timestamp: Date
    let phase: String
    let message: String
    let details: [String: String]
}

// MARK: - 线程及进程间协调

/// 本进程中仍被持有的会话不会被另一个 Store 误标为中断。
private enum ActiveDiagnosticSessions {
    static let lock = NSLock()
    static var ids = Set<String>()
    static func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    static func add(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.insert(id) }
    static func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.remove(id) }
}

final class DiagnosticLogStore {
    let rootURL: URL
    let limits: DiagnosticLogLimits
    private let now: () -> Date
    private let lock = NSRecursiveLock()
    private var lockDepth = 0
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, limits: DiagnosticLogLimits = DiagnosticLogLimits(), now: @escaping () -> Date = Date.init) throws {
        let base = rootURL ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVCodecTest", isDirectory: true).appendingPathComponent("Diagnostics", isDirectory: true)
        self.rootURL = base.standardizedFileURL
        self.limits = limits
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let milliseconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: milliseconds / 1000) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid diagnostic date")
        }
        try ensureDirectory(self.rootURL)
        try withStoreLock {
            try recoverInterruptedLocked()
            try enforceRetention(additionalBytes: 0, additionalSessions: 0, strict: false)
        }
    }

    private func registryKey(_ id: String) -> String { rootURL.path + "/" + id }
    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/") else { throw DiagnosticLogError.invalidSession }
        return rootURL.appendingPathComponent(id, isDirectory: true)
    }
    private func ensureDirectory(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw DiagnosticLogError.unsafePath }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func rejectSymlink(_ url: URL) throws {
        if fm.fileExists(atPath: url.path), try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
            throw DiagnosticLogError.unsafePath
        }
    }
    private func withStoreLock<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if lockDepth > 0 { return try action() }
        let lockURL = rootURL.appendingPathComponent(".store.lock")
        try rejectSymlink(lockURL)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw DiagnosticLogError.lockFailed(code: errno) }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0, flock(descriptor, LOCK_EX) == 0 else {
            throw DiagnosticLogError.lockFailed(code: errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        lockDepth = 1
        defer { lockDepth = 0 }
        return try action()
    }
    private func write(_ data: Data, to url: URL) throws {
        try rejectSymlink(url)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func manifest(_ id: String) throws -> DiagnosticManifest {
        let url = try directory(id).appendingPathComponent("session.json")
        try rejectSymlink(url)
        return try decoder.decode(DiagnosticManifest.self, from: Data(contentsOf: url))
    }
    private func save(_ manifest: DiagnosticManifest) throws {
        try write(encoder.encode(manifest), to: directory(manifest.id).appendingPathComponent("session.json"))
    }
    private func manifests() throws -> [DiagnosticManifest] {
        try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw DiagnosticLogError.unsafePath }
            // 异常发生在创建目录与写入首份 manifest 之间时，仍将残留记录识别为中断。
            if !fm.fileExists(atPath: url.appendingPathComponent("session.json").path) {
                let timestamp = attributes[.creationDate] as? Date ?? now()
                let recovered = DiagnosticManifest(id: url.lastPathComponent, createdAt: timestamp, updatedAt: now(),
                    state: .interrupted, kind: "日志创建中断", version: "未知", ownerPID: 0, eventCount: 0)
                try save(recovered)
                let events = url.appendingPathComponent("events.jsonl")
                if !fm.fileExists(atPath: events.path) { try write(Data(), to: events) }
                return recovered
            }
            return try manifest(url.lastPathComponent)
        }
    }
    private func size(of url: URL) throws -> Int {
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return try contents.reduce(0) { count, file in
            try rejectSymlink(file)
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DiagnosticLogError.unsafePath }
            return count + ((attributes[.size] as? NSNumber)?.intValue ?? 0)
        }
    }
    private func processIsAlive(_ manifest: DiagnosticManifest) -> Bool {
        if manifest.ownerPID == ProcessInfo.processInfo.processIdentifier { return ActiveDiagnosticSessions.contains(registryKey(manifest.id)) }
        guard manifest.ownerPID > 0 else { return false }
        return Darwin.kill(manifest.ownerPID, 0) == 0 || errno == EPERM
    }
    private func recoverInterruptedLocked() throws {
        for var record in try manifests() where record.state == .running && !processIsAlive(record) {
            record.state = .interrupted
            record.updatedAt = now()
            try save(record)
            let marker = try directory(record.id).appendingPathComponent("unfinished")
            if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        }
    }
    private func enforceRetention(additionalBytes: Int, additionalSessions: Int, strict: Bool) throws {
        var records = try manifests()
        let expiry = now().addingTimeInterval(-Double(limits.maxAgeDays) * 86400)
        for record in records where record.state != .running && record.createdAt < expiry {
            try fm.removeItem(at: directory(record.id))
            records.removeAll { $0.id == record.id }
        }
        var total = try records.reduce(0) { try $0 + size(of: directory($1.id)) }
        var removable = records.filter { $0.state != .running }.sorted { $0.createdAt < $1.createdAt }
        while records.count + additionalSessions > limits.maxSessions || total + additionalBytes > limits.maxTotalBytes {
            guard !removable.isEmpty else {
                if strict { throw DiagnosticLogError.storageLimitReached }
                return
            }
            let oldest = removable.removeFirst()
            total -= try size(of: directory(oldest.id))
            try fm.removeItem(at: directory(oldest.id))
            records.removeAll { $0.id == oldest.id }
        }
    }

    func begin(kind: String, version: String = "") throws -> DiagnosticLogSession {
        try withStoreLock {
            try recoverInterruptedLocked()
            try enforceRetention(additionalBytes: 4096, additionalSessions: 1, strict: true)
            let id = UUID().uuidString
            let url = try directory(id)
            try ensureDirectory(url)
            let timestamp = now()
            let record = DiagnosticManifest(id: id, createdAt: timestamp, updatedAt: timestamp, state: .running,
                kind: String(DiagnosticRedactor.redact(kind).prefix(120)), version: String(DiagnosticRedactor.redact(version).prefix(80)),
                ownerPID: ProcessInfo.processInfo.processIdentifier, eventCount: 0)
            do {
                try save(record)
                try write(Data("running\n".utf8), to: url.appendingPathComponent("unfinished"))
                try write(Data(), to: url.appendingPathComponent("events.jsonl"))
            } catch {
                // 已完成的部分留在磁盘以便排查，不能声称创建成功。
                throw error
            }
            ActiveDiagnosticSessions.add(registryKey(id))
            return DiagnosticLogSession(id: id, store: self)
        }
    }

    fileprivate func event(id: String, message: String, phase: String, details: [String: String]) throws {
        try withStoreLock {
            var record = try manifest(id)
            guard record.state == .running else { throw DiagnosticLogError.sessionClosed }
            guard message.utf8.count + phase.utf8.count + details.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= limits.maxEventBytes * 8 else {
                throw DiagnosticLogError.eventTooLarge(limit: limits.maxEventBytes)
            }
            let event = DiagnosticEvent(timestamp: now(), phase: phase, message: message, details: details)
            let raw = try encoder.encode(event)
            let redacted = try DiagnosticRedactor.redactJSON(String(decoding: raw, as: UTF8.self))
            let compactObject = try JSONSerialization.jsonObject(with: Data(redacted.utf8))
            var data = try JSONSerialization.data(withJSONObject: compactObject, options: [.sortedKeys])
            data.append(0x0a)
            guard data.count <= limits.maxEventBytes else { throw DiagnosticLogError.eventTooLarge(limit: limits.maxEventBytes) }
            let url = try directory(id).appendingPathComponent("events.jsonl")
            try rejectSymlink(url)
            let existing = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard existing + data.count <= limits.maxEventsBytes else { throw DiagnosticLogError.eventsLimitReached(limit: limits.maxEventsBytes) }
            try enforceRetention(additionalBytes: data.count + 128, additionalSessions: 0, strict: true)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            record.eventCount += 1
            record.updatedAt = now()
            try save(record)
        }
    }

    fileprivate func capture(id: String, reportJSON: String) throws {
        try withStoreLock {
            var record = try manifest(id)
            guard record.state == .running else { throw DiagnosticLogError.sessionClosed }
            guard reportJSON.utf8.count <= limits.maxReportBytes * 4 else { throw DiagnosticLogError.reportTooLarge(limit: limits.maxReportBytes) }
            let redacted = try DiagnosticRedactor.redactJSON(reportJSON)
            let data = Data(redacted.utf8)
            guard data.count <= limits.maxReportBytes else { throw DiagnosticLogError.reportTooLarge(limit: limits.maxReportBytes) }
            let url = try directory(id).appendingPathComponent("report.json")
            try rejectSymlink(url)
            let existing = fm.fileExists(atPath: url.path) ? ((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) : 0
            try enforceRetention(additionalBytes: max(0, data.count - existing) + 128, additionalSessions: 0, strict: true)
            try write(data, to: url)
            record.updatedAt = now()
            try save(record)
        }
    }

    fileprivate func finish(id: String, reportJSON: String?, cancelled: Bool, failed: Bool) throws {
        try withStoreLock {
            var record = try manifest(id)
            let target: DiagnosticSessionState = cancelled ? .cancelled : (failed ? .failed : .completed)
            if record.state != .running {
                guard record.state == target else { throw DiagnosticLogError.sessionClosed }
                return
            }
            if let reportJSON = reportJSON { try capture(id: id, reportJSON: reportJSON) }
            record = try manifest(id)
            record.state = target
            record.updatedAt = now()
            try save(record)
            let marker = try directory(id).appendingPathComponent("unfinished")
            if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
            ActiveDiagnosticSessions.remove(registryKey(id))
            try enforceRetention(additionalBytes: 0, additionalSessions: 0, strict: false)
        }
    }

    fileprivate func abandon(id: String) { ActiveDiagnosticSessions.remove(registryKey(id)) }

    func entries() throws -> [DiagnosticLogEntry] {
        try withStoreLock {
            try recoverInterruptedLocked()
            try enforceRetention(additionalBytes: 0, additionalSessions: 0, strict: false)
            return try manifests().map { record in
                let url = try directory(record.id)
                return DiagnosticLogEntry(id: record.id, createdAt: record.createdAt, updatedAt: record.updatedAt,
                    state: record.state, kind: record.kind, url: url, sizeBytes: try size(of: url),
                    reportAvailable: fm.fileExists(atPath: url.appendingPathComponent("report.json").path))
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func readReport(_ entry: DiagnosticLogEntry) throws -> String? {
        try withStoreLock {
            _ = try manifest(entry.id)
            let url = try directory(entry.id).appendingPathComponent("report.json")
            guard fm.fileExists(atPath: url.path) else { return nil }
            try rejectSymlink(url)
            guard ((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) <= limits.maxReportBytes else {
                throw DiagnosticLogError.reportTooLarge(limit: limits.maxReportBytes)
            }
            return try DiagnosticRedactor.redactJSON(String(contentsOf: url, encoding: .utf8))
        }
    }

    func read(_ entry: DiagnosticLogEntry) throws -> String {
        try withStoreLock {
            let record = try manifest(entry.id)
            let url = try directory(entry.id).appendingPathComponent("events.jsonl")
            try rejectSymlink(url)
            let eventsSize = fm.fileExists(atPath: url.path) ? ((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) : 0
            guard eventsSize <= limits.maxEventsBytes else { throw DiagnosticLogError.eventsLimitReached(limit: limits.maxEventsBytes) }
            let events = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            let date = ISO8601DateFormatter().string(from: record.createdAt)
            var output = "NVCodecTest 诊断日志\n版本：\(record.version.isEmpty ? "未知" : record.version)\n类型：\(record.kind)\n开始：\(date)\n状态：\(record.state.title) (\(record.state.rawValue))\n事件：\(record.eventCount)\n\n【过程事件】\n" + events
            if let report = try readReport(entry) { output += "\n【完整诊断快照 JSON】\n" + report + "\n" }
            return DiagnosticRedactor.redact(output)
        }
    }

    func delete(_ entry: DiagnosticLogEntry) throws {
        try withStoreLock {
            try recoverInterruptedLocked()
            let record = try manifest(entry.id)
            guard record.state != .running else { throw DiagnosticLogError.activeSession }
            try fm.removeItem(at: directory(entry.id))
        }
    }

    /// 保护活跃会话；其余会话逐条删除，任何失败明确抛给调用方。
    func clear() throws {
        try withStoreLock {
            try recoverInterruptedLocked()
            for record in try manifests() where record.state != .running {
                try fm.removeItem(at: directory(record.id))
            }
        }
    }
}

final class DiagnosticLogSession {
    let id: String
    private let store: DiagnosticLogStore
    fileprivate init(id: String, store: DiagnosticLogStore) { self.id = id; self.store = store }
    deinit { store.abandon(id: id) }
    func event(message: String, phase: String = "", details: [String: String] = [:]) throws {
        try store.event(id: id, message: message, phase: phase, details: details)
    }
    func capture(reportJSON: String) throws { try store.capture(id: id, reportJSON: reportJSON) }
    func finish(reportJSON: String? = nil, cancelled: Bool = false, failed: Bool = false) throws {
        try store.finish(id: id, reportJSON: reportJSON, cancelled: cancelled, failed: failed)
    }
}
