import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first {
    if command == "preview" {
        Preview.run(Array(arguments.dropFirst()))
    } else {
        exit(CLI.run(arguments))
    }
}

// launchd 와 손 실행이 겹쳐도 하나만 돈다. 이미 떠 있으면 그쪽에 창을 열라고 알리고 끝낸다.
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(WindowOpener.notification, object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}

MenuBarPlacement.apply()
OrcaCronApp.main()
