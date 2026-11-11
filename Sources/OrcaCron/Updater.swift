import AppKit
import Foundation

enum UpdateCheck: Sendable {
    case upToDate
    case available(UpdateInfo)
    case failed(String, quiet: Bool) // quiet = 자동 확인 때는 드러내지 않는 일시 실패(네트워크 등)
}

struct UpdateInfo: Sendable, Equatable {
    let behind: Int // 설치된 커밋 뒤로 새로 들어온 커밋 수
    let subjects: [String] // 최근 것부터 최대 3개
}

/// 업데이트 확인 — 빌드할 때 Info.plist 에 적어 둔 소스 폴더에서 git fetch 하고, 설치된 커밋 뒤로 새 커밋이 있는지 본다.
/// 받기는 그 폴더에서 `git pull --ff-only && ./build.sh install` — 스크립트가 지금 앱을 끄고 새 빌드를 launchd 로 다시 띄운다.
enum Updater {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "?"
    static let commit = info["OrcaCronCommit"] as? String
    static let sourceDir = info["OrcaCronSourceDir"] as? String
    static let logPath = NSHomeDirectory() + "/Library/Logs/OrcaCron-update.log"
    static let changelogURL = URL(string: "https://github.com/gook-lab/orca-cron/blob/main/CHANGELOG.md")!
    static let reinstallHint = "INSTALL.md 링크로 다시 설치하세요"
    // 앱에 들어가는 파일이 바뀐 커밋만 센다 — 문서만 고친 커밋으로는 업데이트를 알리지 않는다
    private static let appPaths = ["--", "Sources", "Package.swift", "Info.plist", "build.sh"]
    private static let git = "/usr/bin/git"

    static var shortCommit: String { commit.map { String($0.prefix(7)) } ?? "개발 빌드" }

    static func check() -> UpdateCheck {
        guard let dir = sourceDir, let commit else { return .failed("개발 빌드 — 소스 폴더를 모릅니다", quiet: true) }
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            return .failed("소스 폴더(\(dir))가 없어 업데이트할 수 없습니다 — \(reinstallHint)", quiet: false)
        }
        guard run(dir, ["fetch", "--quiet", "origin"], timeout: 30) != nil else {
            return .failed("git fetch 실패 — 네트워크를 확인하세요", quiet: true)
        }
        let upstream = run(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) ?? "origin/main"
        guard let behind = run(dir, ["rev-list", "--count", "\(commit)..\(upstream)"] + appPaths).flatMap({ Int($0) }) else {
            return .failed("설치된 커밋을 소스 폴더에서 찾지 못했습니다 — \(reinstallHint)", quiet: false)
        }
        guard behind > 0 else { return .upToDate }
        let subjects = run(dir, ["log", "--format=%s", "-3", "\(commit)..\(upstream)"] + appPaths)?
            .split(separator: "\n").map(String.init) ?? []
        return .available(UpdateInfo(behind: behind, subjects: subjects))
    }

    /// 성공하면 build.sh 가 이 앱을 끄고 새 앱을 띄운다. completion 은 실패했을 때만 불린다(로그 마지막 줄을 넘긴다).
    /// launchd 작업에 AbandonProcessGroup 을 켜 두어, 앱이 꺼져도 이 셸은 끝까지 돈다(build.sh).
    static func install(completion: @escaping @Sendable (String) -> Void) {
        guard let dir = sourceDir else { return completion("업데이트 실패 — 개발 빌드라 소스 폴더를 모릅니다") }
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            return completion("업데이트 실패 — 소스 폴더(\(dir))가 없습니다. \(reinstallHint)")
        }
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
            { echo "== $(date) 업데이트"; cd \(quoted) && git pull --ff-only && ./build.sh install; } >> '\(logPath)' 2>&1
            """]
        process.terminationHandler = { finished in
            if finished.terminationStatus == 0 {
                // 보통은 build.sh 가 먼저 이 앱을 끈다. 그래도 살아 있으면 launchd 가 띄운 새 앱에 자리를 넘긴다.
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                return
            }
            let tail = (try? String(contentsOfFile: logPath, encoding: .utf8))?
                .split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            completion("업데이트 실패 (종료 코드 \(finished.terminationStatus)) — \(tail) · 로그 ~/Library/Logs/OrcaCron-update.log")
        }
        do { try process.run() } catch { completion("업데이트 실패 — 시작하지 못했습니다: \(error.localizedDescription)") }
    }

    private static func run(_ dir: String, _ arguments: [String], timeout: TimeInterval = 15) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir] + arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
