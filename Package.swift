// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OrcaCron",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SchedulerCore"),
        .executableTarget(name: "OrcaCron", dependencies: ["SchedulerCore"]),
        // Command Line Tools 에는 XCTest·Testing 모듈이 없어 점검은 실행 파일로 돈다(swift run SchedulerCheck).
        .executableTarget(name: "SchedulerCheck", dependencies: ["SchedulerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
