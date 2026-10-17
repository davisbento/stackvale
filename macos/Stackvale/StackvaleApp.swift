import AppKit
import SwiftUI

// MARK: - App

@main
struct StackvaleApp: App {
    @NSApplicationDelegateAdaptor(StackvaleAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class StackvaleAppDelegate: NSObject, NSApplicationDelegate {
    private let projectStore = ProjectStore()
    private let serviceManager = ServiceManager()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(
            projectStore: projectStore,
            serviceManager: serviceManager
        )

        // Stackvale is a regular application with a menu-bar companion,
        // rather than a menu-bar-only utility.
        NSApp.setActivationPolicy(.regular)
        statusBarController?.openDashboard()
    }
}
