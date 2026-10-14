import SwiftUI
import AppKit

@main
struct StackvaleApp: App {
    var body: some Scene {
        MenuBarExtra("Stackvale", systemImage: "tray") {
            Text("Stackvale")

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
