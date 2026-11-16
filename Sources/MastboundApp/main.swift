import AppKit
import MastboundCore
import SwiftUI

// Modes:
//   (none)              real app: reads status.json, asks for the admin password
//   --demo              fake status, no password, no system changes
//   --snapshot <folder> writes a PNG of each screen and quits
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    MainActor.assumeIsolated { Snapshots.write(to: URL(fileURLWithPath: arguments[index + 1])) }
    exit(0)
}

MastboundApp.main()

struct MastboundApp: App {
    @State private var model: AppModel = {
        let demo = CommandLine.arguments.contains("--demo")
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
        let model = AppModel(runner: DemoRunner(), isDemo: false)
        let day = 86_400.0
        let shots: [(String, Screen)] = [
            ("1-start", .idle(lastEnd: nil)),
            ("2-active", .active(remaining: 29 * day + 13 * 3_600 + 42 * 60 + 9, end: Date().addingTimeInterval(29 * day + 13 * 3_600))),
            ("3-active-last-day", .active(remaining: 5 * 3_600 + 17 * 60 + 33, end: Date().addingTimeInterval(5 * 3_600))),
            ("4-recovering", .recovering(remaining: 12 * day + 2 * 3_600, recoveryRemaining: 61 * 3_600 + 14 * 60, end: Date().addingTimeInterval(12 * day))),
            ("5-problem", .problem("Mastbound could not read its status. The block, if any, stays on.")),
        ]
        for (name, screen) in shots {
            let renderer = ImageRenderer(content: RootView(model: model, fixedScreen: screen))
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
