import AppKit
import MastboundCore
import SwiftUI

// Modes:
//   (none)              real app: reads status.json, asks for the admin password
//   --demo              fake status, no password, no system changes
//   --snapshot <folder> writes a PNG of each screen (and each early-end step) and quits
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    MainActor.assumeIsolated { Snapshots.write(to: URL(fileURLWithPath: arguments[index + 1])) }
    exit(0)
}

MastboundApp.main()

struct MastboundApp: App {
    @State private var model: AppModel = {
        // The demo bundle sets MastboundDemo in its Info.plist.
        let demo = CommandLine.arguments.contains("--demo")
            || (Bundle.main.object(forInfoDictionaryKey: "MastboundDemo") as? Bool) == true
        if !demo, let runner = AdminRunner.fromBundle() {
            return AppModel(runner: runner, isDemo: false)
        }
        return AppModel(runner: DemoRunner(), isDemo: true)
    }()

    var body: some Scene {
        Window("Mastbound", id: "main") {
            RootView(model: model)
                .onAppear { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
enum Snapshots {
    static func write(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(runner: DemoRunner(timing: .real), isDemo: false)
        let day = 86_400.0
        let shots: [(String, Screen)] = [
            ("1-start", .idle(lastEnd: nil)),
            ("2-active", .active(remaining: 29 * day + 13 * 3_600 + 42 * 60 + 9, end: Date().addingTimeInterval(29 * day + 13 * 3_600), quitElapsed: nil)),
            ("3-active-last-day", .active(remaining: 5 * 3_600 + 17 * 60 + 33, end: Date().addingTimeInterval(5 * 3_600), quitElapsed: nil)),
            ("4-recovering", .recovering(remaining: 12 * day + 2 * 3_600, recoveryRemaining: 61 * 3_600 + 14 * 60, end: Date().addingTimeInterval(12 * day))),
            ("5-problem", .problem("Mastbound could not read its status. The block, if any, stays on.")),
            ("5b-service-off", .serviceOff),
        ]
        var all: [(String, Screen, QuitStep?, Bool)] = shots.map { ($0.0, $0.1, nil, false) }
        let open = Screen.active(remaining: 29 * day + 13 * 3_600, end: nil, quitElapsed: 41 * 60)
        for step in QuitStep.allCases {
            all.append(("6-quit-\(step.rawValue + 1)-\(step)", open, step, false))
        }
        all.append(("6-quit-slow-down", open, .codes, true))
        all.append(("2b-active-timed-out", shots[1].1, nil, false))
        let timedOut = AppModel(runner: DemoRunner(timing: .real), isDemo: false)
        timedOut.notice = "The early end timed out. The block stays on."
        for (name, screen, step, slowDown) in all {
            let shown = name == "2b-active-timed-out" ? timedOut : model
            let renderer = ImageRenderer(content: RootView(model: shown, fixedScreen: screen, fixedQuitStep: step, fixedSlowDown: slowDown))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("could not render \(name)"); continue
            }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }
    }
}
