import Foundation
import CoreFoundation
import Darwin

/// Stable three component version ordering for bundle versions and GitHub tags.
struct AppUpdateVersion: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }
    var tag: String { "v\(description)" }

    static func parse(_ raw: String?) -> AppUpdateVersion? {
        guard let raw, raw.utf8.count <= 60 else { return nil }
        let value = raw.hasPrefix("v") ? raw.dropFirst() : raw[...]
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let numbers = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  field.count == 1 || field.first != "0" else { return nil }
            return Int(field)
        }
        guard numbers.count == 3 else { return nil }
        return AppUpdateVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct AppUpdateRelease: Equatable {
    let version: AppUpdateVersion
    let downloadURL: URL
    let releasePage: URL
    let assetSize: Int64
    let sha256: String?
    let checksumURL: URL?
}

enum AppUpdateBundleInfo {
    /// Read the current file each time. Bundle caches Info.plist by URL and can return
    /// stale version data after the installer atomically replaces that bundle path.
    static func read(from app: URL) -> [String: Any]? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return value as? [String: Any]
    }

    static func supportsCurrentSystem(_ info: [String: Any], current: [Int] = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [version.majorVersion, version.minorVersion, version.patchVersion]
    }()) -> Bool {
        guard let minimum = info["LSMinimumSystemVersion"] as? String else { return false }
        return supportsMinimumSystemVersion(minimum, current: current)
    }

    static func supportsMinimumSystemVersion(_ minimum: String, current: [Int]) -> Bool {
        let fields = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), current.count == 3,
              current.allSatisfy({ $0 >= 0 }) else { return false }
        let required = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  field.count == 1 || field.first != "0" else { return nil }
            return Int(field)
        }
        guard required.count == fields.count else { return false }
        for index in 0..<3 {
            let needed = index < required.count ? required[index] : 0
            if current[index] != needed { return current[index] > needed }
        }
        return true
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && (information.st_mode & S_IFMT) == S_IFDIR
    }

    static func hostArchitecture() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var machine = [CChar](repeating: 0, count: size)
        let result = machine.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.machine", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let architecture = String(cString: machine)
        return ["arm64", "x86_64"].contains(architecture) ? architecture : nil
    }
}

enum AppUpdateTaskGate {
    static func isCurrent(_ task: URLSessionTask, current: URLSessionTask?) -> Bool {
        current.map { task === $0 } ?? false
    }
}

enum AppUpdateFeed {
    static let maximumFeedBytes = 1_048_576
    static let maximumDMGBytes: Int64 = 250 * 1024 * 1024
    private static let repository = "GeekAudio/NVCodecTest"

    static var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static func shouldSkip(version: AppUpdateVersion, skippedVersion: String?, manual: Bool) -> Bool {
        !manual && skippedVersion == version.description
    }

    static func parse(_ data: Data, current: AppUpdateVersion) throws -> AppUpdateRelease? {
        guard data.count <= maximumFeedBytes else { throw AppUpdateError.invalidFeed("更新信息超出大小限制。") }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw AppUpdateError.invalidFeed("GitHub 返回的更新信息无法读取。") }
        guard let release = json as? [String: Any],
              let tag = release["tag_name"] as? String,
              let version = AppUpdateVersion.parse(tag), tag == version.tag,
              let draft = bool(release["draft"]), let prerelease = bool(release["prerelease"]),
              let pageString = release["html_url"] as? String,
              let page = URL(string: pageString), isReleasePage(page, tag: tag),
              let assets = release["assets"] as? [[String: Any]] else {
            throw AppUpdateError.invalidFeed("GitHub 更新信息缺少有效的版本或资产。")
        }
        guard !draft, !prerelease, version > current else { return nil }

        let name = "GPU-Z-\(tag).dmg"
        let matches = assets.filter { $0["name"] as? String == name }
        guard matches.count == 1, let asset = matches.first,
              let size = integer(asset["size"]), size > 0, size <= maximumDMGBytes,
              let urlText = asset["browser_download_url"] as? String,
              let download = URL(string: urlText), isAsset(download, tag: tag, filename: name) else {
            throw AppUpdateError.invalidFeed("新版安装包缺失、重复或来源不符合预期。")
        }
        var digest: String?
        if let supplied = asset["digest"] as? String {
            guard supplied.hasPrefix("sha256:") else { throw AppUpdateError.invalidFeed("GitHub 提供了不支持的文件校验类型。") }
            let value = String(supplied.dropFirst(7)).lowercased()
            guard isSHA256(value) else { throw AppUpdateError.invalidFeed("GitHub 的文件校验值格式错误。") }
            digest = value
        }

        let checksumAssets = assets.filter { $0["name"] as? String == "SHA256SUMS.txt" }
        guard checksumAssets.count <= 1 else { throw AppUpdateError.invalidFeed("GitHub 校验清单重复。") }
        var checksumURL: URL?
        if let checksum = checksumAssets.first,
           let text = checksum["browser_download_url"] as? String,
           let url = URL(string: text), isAsset(url, tag: tag, filename: "SHA256SUMS.txt") {
            checksumURL = url
        }
        guard digest != nil || checksumURL != nil else {
            throw AppUpdateError.invalidFeed("该版本没有可验证的 SHA-256 校验值。")
        }
        return AppUpdateRelease(version: version, downloadURL: download, releasePage: page,
                                assetSize: size, sha256: digest, checksumURL: checksumURL)
    }

    static func checksum(in manifest: Data, filename: String) throws -> String {
        guard manifest.count <= 65_536, let text = String(data: manifest, encoding: .utf8),
              !text.contains("\r") else { throw AppUpdateError.invalidFeed("SHA256SUMS.txt 无效或超过 64 KiB。") }
        let matches = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename else { return nil }
            return String(parts[0]).lowercased()
        }
        guard matches.count == 1, let value = matches.first, isSHA256(value) else {
            throw AppUpdateError.invalidFeed("SHA256SUMS.txt 中找不到唯一的安装包校验值。")
        }
        return value
    }

    static func isSafeInstallTarget(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let candidate = url.standardizedFileURL
        let allowedParents = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        return ["GPU-Z.app", "NVCodecTest.app"].contains(candidate.lastPathComponent) && allowedParents.contains(candidate.deletingLastPathComponent())
    }

    private static func isReleasePage(_ url: URL, tag: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil &&
        url.query == nil && url.fragment == nil && url.path == "/\(repository)/releases/tag/\(tag)"
    }
    private static func isAsset(_ url: URL, tag: String, filename: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil &&
        url.query == nil && url.fragment == nil && url.path == "/\(repository)/releases/download/\(tag)/\(filename)"
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

enum AppUpdateError: LocalizedError {
    case invalidFeed(String)
    case download(String)
    case install(String)
    var errorDescription: String? {
        switch self {
        case .invalidFeed(let value), .download(let value), .install(let value): return value
        }
    }
}
