import AppKit
import SwiftUI

@main
struct RoasterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mastbound") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 680)
                .task { await model.start() }
        }
        .defaultSize(width: 860, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Hide Mastbound Interface") {
                    NSApp.hide(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
