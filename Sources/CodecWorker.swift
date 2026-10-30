import Foundation
import Darwin

struct CodecWorkerEvent: Codable {
    let kind: String
    var environment: EnvironmentSnapshot?
    var progress: Double?
    var message: String?
    var row: BenchRow?
    var cancelled: Bool?
}

/// The measuring process creates no window and writes no diagnostic files.
/// The parent records its events and driver stderr in a different address space.
enum CodecWorker {
    /// Parse selection before environment probing so bad CLI input cannot start any test work.
    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        let selectedCaseIDs: [String]
        do {
            selectedCaseIDs = try CodecTestPlan.selection(in: arguments)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 64
        }

        let token = BenchCancellation(), parent = getppid()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { token.cancel() }; source.resume(); return source
        }
        let watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watch.schedule(deadline: .now() + 1, repeating: 1)
        watch.setEventHandler { if getppid() != parent { token.cancel() } }; watch.resume()
        defer { signals.forEach { $0.cancel() }; watch.cancel() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var lastProgress = 0.0
        func emit(_ event: CodecWorkerEvent) {
            if event.kind == "progress" {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastProgress >= 0.15 else { return }
                lastProgress = now
            }
            autoreleasepool {
                guard var data = try? encoder.encode(event) else { return }
                data.append(10); FileHandle.standardOutput.write(data)
            }
        }
        // Match upstream's per-process registration: initialize Metal before creating VT sessions.
        let captured = EnvProbe.captureEnvironment()
        let snapshot = EnvironmentSnapshot(rows: captured.rows + [EnvRow("测量进程", "独立进程 PID=\(getpid())", note: "在主线程初始化 Metal 和 VideoToolbox；此进程不创建窗口、不写日志文件。")],
            encoders: captured.encoders, driver: captured.driver, decoderCaps: captured.decoderCaps, capturedAt: captured.capturedAt)
        emit(CodecWorkerEvent(kind: "environment", environment: snapshot))
        do {
            _ = try CodecBench.run(caseIDs: Set(selectedCaseIDs), progress: { value, message in
            emit(CodecWorkerEvent(kind: "progress", progress: value, message: message))
            }, onRow: { row in emit(CodecWorkerEvent(kind: "row", row: row)) }, cancellation: token)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 64
        }
        emit(CodecWorkerEvent(kind: "complete", cancelled: token.isCancelled))
        return 0
    }
}

struct CodecWorkerCompletion {
    let complete: Bool
    let cancelled: Bool
    let exitCode: Int32
    let message: String
}

final class CodecWorkerClient {
    private let lock = NSLock()
    private var process: Process?
    private var ready = false
    private var requestedCancellation = false
    private var sentCancellation = false
    private let executableURL: URL?
    private let arguments: [String]
    private let expectedCaseIDs: Set<String>

    init(executableURL: URL? = Bundle.main.executableURL, arguments: [String] = ["--codec-worker"],
         expectedCaseIDs: [String]? = nil) {
        self.executableURL = executableURL; self.arguments = arguments
        if let expectedCaseIDs {
            self.expectedCaseIDs = (try? Set(CodecTestPlan.validate(expectedCaseIDs))) ?? []
        } else {
            self.expectedCaseIDs = (try? Set(CodecTestPlan.selection(in: arguments))) ?? []
        }
    }
    func cancel() {
        lock.lock(); requestedCancellation = true
        let target = ready && !sentCancellation ? process : nil
        if target != nil { sentCancellation = true }
        lock.unlock()
        if let target, target.isRunning { target.interrupt() }
    }
    private func markReady() {
        lock.lock(); ready = true; let cancelled = requestedCancellation; lock.unlock()
        if cancelled { cancel() }
    }
    func run(onEvent: @escaping (CodecWorkerEvent) -> Void, onDiagnostic: @escaping (String) -> Void) -> CodecWorkerCompletion {
        guard let executableURL else {
            return CodecWorkerCompletion(complete: false, cancelled: false, exitCode: -1, message: "无法定位测试进程")
        }
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = executableURL; child.arguments = arguments
        child.standardOutput = output; child.standardError = errors; child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            return CodecWorkerCompletion(complete: false, cancelled: false, exitCode: -1, message: "测试进程启动失败：" + error.localizedDescription)
        }
        lock.lock(); process = child; lock.unlock()
        let stderrDone = DispatchGroup(); stderrDone.enter()
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    onDiagnostic(String(decoding: pending[..<end].prefix(8192), as: UTF8.self))
                    pending.removeSubrange(...end)
                }
                if pending.count > 8192 { onDiagnostic(String(decoding: pending.prefix(8192), as: UTF8.self)); pending.removeAll() }
            }
            if !pending.isEmpty { onDiagnostic(String(decoding: pending, as: UTF8.self)) }
            try? errors.fileHandleForReading.close(); stderrDone.leave()
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var pending = Data(), gotEnvironment = false, gotCompletion = false, cancelled = false
        var rowIDs = Set<String>(), protocolError = expectedCaseIDs.isEmpty
        func receive(_ line: Data) {
            guard let event = try? decoder.decode(CodecWorkerEvent.self, from: line) else {
                onDiagnostic(String(decoding: line.prefix(8192), as: UTF8.self)); return
            }
            guard !gotCompletion else { protocolError = true; return }
            switch event.kind {
            case "environment":
                guard event.environment != nil, !gotEnvironment else { protocolError = true; return }
                gotEnvironment = true; markReady()
            case "progress":
                guard gotEnvironment, event.progress != nil else { protocolError = true; return }
            case "row":
                guard gotEnvironment, let row = event.row,
                      expectedCaseIDs.contains(row.id), rowIDs.insert(row.id).inserted else { protocolError = true; return }
            case "complete":
                guard gotEnvironment, event.cancelled != nil, !gotCompletion else { protocolError = true; return }
                gotCompletion = true; cancelled = event.cancelled ?? false
            default: protocolError = true; return
            }
            onEvent(event)
        }
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                receive(Data(pending[..<end])); pending.removeSubrange(...end)
            }
            if pending.count > 1_048_576 { protocolError = true; pending.removeAll(); cancel() }
        }
        if !pending.isEmpty { receive(pending) }
        child.waitUntilExit(); stderrDone.wait(); try? output.fileHandleForReading.close()
        lock.lock(); process = nil; let cancellationRequested = requestedCancellation; lock.unlock()
        let complete = gotCompletion && !protocolError && child.terminationStatus == 0 && rowIDs == expectedCaseIDs
        let wasCancelled = cancelled || (!complete && cancellationRequested)
        let message = complete ? (wasCancelled ? "已取消，保留已完成的结果" : "本轮测试完成")
            : "测试进程未完整结束（退出码 \(child.terminationStatus)），保留已完成结果和驱动错误"
        return CodecWorkerCompletion(complete: complete, cancelled: wasCancelled, exitCode: child.terminationStatus, message: message)
    }
}
