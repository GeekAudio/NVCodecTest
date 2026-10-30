import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count >= 3 else { exit(64) }
let bundleID = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]

if mode == "--read-last-update-check" {
    let defaults = UserDefaults(suiteName: bundleID)!
    guard let value = defaults.object(forKey: "GPU-Z.lastUpdateCheck") else { print("absent"); exit(0) }
    guard let date = value as? Date else { fputs("unexpected update-check preference type\n", stderr); exit(65) }
    print("date:\(date.timeIntervalSince1970)")
    exit(0)
}

if mode == "--set-last-update-check-now" {
    let defaults = UserDefaults(suiteName: bundleID)!
    defaults.set(Date(), forKey: "GPU-Z.lastUpdateCheck")
    guard defaults.synchronize() else { exit(1) }
    exit(0)
}

if mode == "--restore-last-update-check" {
    guard CommandLine.arguments.count == 4 else { exit(64) }
    let defaults = UserDefaults(suiteName: bundleID)!
    let value = CommandLine.arguments[3]
    if value == "absent" {
        defaults.removeObject(forKey: "GPU-Z.lastUpdateCheck")
    } else if value.hasPrefix("date:"), let seconds = TimeInterval(String(value.dropFirst(5))) {
        defaults.set(Date(timeIntervalSince1970: seconds), forKey: "GPU-Z.lastUpdateCheck")
    } else { exit(65) }
    guard defaults.synchronize() else { exit(1) }
    exit(0)
}

guard mode == "--any" || mode.hasPrefix("/") else { exit(64) }
let targetURL = mode == "--any" ? nil : URL(fileURLWithPath: mode).standardizedFileURL

for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
    guard let bundleURL = application.bundleURL?.standardizedFileURL,
          targetURL == nil || bundleURL == targetURL else { continue }
    print("\(application.processIdentifier)\t\(bundleURL.path)")
}
