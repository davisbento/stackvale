import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let projectStore: ProjectStore
    private let serviceManager: ServiceManager
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

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

        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 430, height: 520)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.delegate = self
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
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        startOutsideClickMonitoring()
    }

    private func showContextMenu() {
        popover.performClose(nil)

        let menu = NSMenu()

        let runningCount = serviceManager.runningServiceCount
        let summaryTitle = runningCount == 1 ? "1 process running" : "\(runningCount) processes running"
        let summaryItem = NSMenuItem(title: summaryTitle, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Stackvale", action: #selector(openStackvale), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let manageProjectsItem = NSMenuItem(title: "Manage Projects", action: #selector(manageProjects), keyEquivalent: "")
        manageProjectsItem.target = self
        menu.addItem(manageProjectsItem)

        menu.addItem(.separator())

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

    @objc private func openStackvale() {
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
    }

    @objc private func manageProjects() {
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .stackvaleShowManageProjects, object: nil)
        }
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                if NSApp.modalWindow is NSOpenPanel { return }
                self?.closePopover()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.closePopoverIfNeeded(for: event)
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else { return }
        if event.window == popover.contentViewController?.view.window { return }
        if event.window == statusItem.button?.window { return }
        if event.window is NSOpenPanel { return }
        closePopover()
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }
}

extension Notification.Name {
    static let stackvaleShowManageProjects = Notification.Name("stackvaleShowManageProjects")
}
