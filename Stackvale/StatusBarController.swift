import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let projectStore: ProjectStore
    private let serviceManager: ServiceManager
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(projectStore: ProjectStore, serviceManager: ServiceManager) {
        self.projectStore = projectStore
        self.serviceManager = serviceManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        let image = NSImage(named: "StackvaleMenuBar") ?? NSImage(systemSymbolName: "mountain.2", accessibilityDescription: "Stackvale")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true

        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Stackvale"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let content = StackvaleRootView()
            .environmentObject(projectStore)
            .environmentObject(serviceManager)
            .frame(width: 430)
            .frame(minHeight: 360)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 520)
        popover.contentViewController = NSHostingController(rootView: content)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)

        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Stackvale", action: #selector(quitStackvale), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)

        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func quitStackvale() {
        serviceManager.confirmQuit()
    }
}
