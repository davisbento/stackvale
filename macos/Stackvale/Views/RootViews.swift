import SwiftUI
import AppKit

// MARK: - Root UI

private enum RootScreen {
    case addService(Project)
    case editService(ServiceDefinition)
    case serviceDetails(ServiceDefinition)
    case rescan(Project)
    case manageProjects
}

struct StackvaleRootView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var serviceManager: ServiceManager
    @State private var screen: RootScreen?
    @State private var projectSetupURL: URL?
    @State private var projectHotkeyMonitor: Any?

    var body: some View {
        Group {
            if let projectSetupURL {
                ProjectSetupView(
                    rootURL: projectSetupURL,
                    compact: true,
                    onClose: { self.projectSetupURL = nil }
                )
                .environmentObject(store)
            } else if let screen {
                screenContent(screen)
            } else {
                mainContent
            }
        }
        .frame(width: 430, height: 520, alignment: .topLeading)
        .onAppear {
            Task { await serviceManager.refreshDockerStatuses(projects: store.projects) }
            installProjectHotkeyMonitor()
        }
        .onDisappear {
            removeProjectHotkeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stackvaleShowManageProjects)) { _ in
            projectSetupURL = nil
            screen = .manageProjects
        }
    }

    @ViewBuilder
    private func screenContent(_ screen: RootScreen) -> some View {
        switch screen {
        case .addService(let project):
            ServiceEditorView(project: project, service: nil, compact: true, onClose: closeScreen)
                .environmentObject(store)
        case .editService(let service):
            ServiceEditorView(
                project: store.projects.first { $0.id == service.projectId },
                service: service,
                compact: true,
                onClose: closeScreen
            )
            .environmentObject(store)
        case .serviceDetails(let service):
            ServiceDetailsView(service: service, compact: true, onClose: closeScreen)
                .environmentObject(serviceManager)
        case .rescan(let project):
            RescanProjectView(project: project, compact: true, onClose: closeScreen)
                .environmentObject(store)
        case .manageProjects:
            ManageProjectsView(compact: true, onClose: closeScreen)
                .environmentObject(store)
        }
    }

    private func closeScreen() {
        screen = nil
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.projects.isEmpty {
                EmptyStateView(addProject: chooseProjectDirectory)
            } else if let project = store.selectedProject {
                ProjectOverviewView(
                    project: project,
                    addService: { screen = .addService(project) },
                    editService: { screen = .editService($0) },
                    showDetails: { screen = .serviceDetails($0) },
                    rescan: { screen = .rescan(project) }
                )
            }

            Divider()

            HStack {
                Button("Add Project", action: chooseProjectDirectory)
                Spacer()
                Button("Quit") {
                    serviceManager.confirmQuit()
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2.fill")
                    .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stackvale")
                        .font(.headline)
                    Text("Every project has its place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !store.projects.isEmpty {
                HStack(spacing: 8) {
                    Picker("Project", selection: selectedProjectBinding) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button {
                        screen = .manageProjects
                    } label: {
                        Label("Manage projects", systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .help("Manage projects")
                }

                Text("Tip: press 1–9 to switch projects.")
                    .font(.caption2.italic())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedProjectBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedProject?.id },
            set: { newValue in
                store.selectedProjectID = newValue
                store.save()
            }
        )
    }

    private func chooseProjectDirectory() {
        let presentingWindow = NSApp.keyWindow
        Task { @MainActor in
            if let url = await chooseDirectory(title: "Choose a project folder", presentingWindow: presentingWindow) {
                projectSetupURL = url
            }
        }
    }

    private func installProjectHotkeyMonitor() {
        guard projectHotkeyMonitor == nil else { return }

        projectHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldHandleProjectHotkey(event),
                  let projectNumber = projectNumber(from: event),
                  projectNumber <= store.projects.count else { return event }

            store.selectedProjectID = store.projects[projectNumber - 1].id
            store.save()
            return nil
        }
    }

    private func removeProjectHotkeyMonitor() {
        if let projectHotkeyMonitor {
            NSEvent.removeMonitor(projectHotkeyMonitor)
            self.projectHotkeyMonitor = nil
        }
    }

    private func shouldHandleProjectHotkey(_ event: NSEvent) -> Bool {
        guard screen == nil, projectSetupURL == nil else { return false }
        guard !store.projects.isEmpty else { return false }
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else { return false }
        return !isTextInputFocused
    }

    private func projectNumber(from event: NSEvent) -> Int? {
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let number = Int(characters), (1...9).contains(number) else { return nil }
        return number
    }

    private var isTextInputFocused: Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        if firstResponder is NSTextView { return true }
        if firstResponder is NSTextField { return true }
        return false
    }
}

struct EmptyStateView: View {
    var addProject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Add a local project folder. Stackvale will scan metadata only; no service starts during onboarding.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Project", action: addProject)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
    }
}

struct ProjectOverviewView: View {
    @EnvironmentObject private var serviceManager: ServiceManager
    var project: Project
    var addService: () -> Void
    var editService: (ServiceDefinition) -> Void
    var showDetails: (ServiceDefinition) -> Void
    var rescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.title3.weight(.semibold))
                Text(project.rootPath.abbreviatingHomeDirectory())
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("SERVICES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await serviceManager.refreshDockerStatuses(projects: [project]) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh Docker statuses")
            }

            if project.services.isEmpty {
                ContentUnavailableView("No services", systemImage: "terminal", description: Text("Add a manual service or rescan this project."))
                    .frame(height: 120)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(project.services) { service in
                            ServiceRowView(
                                service: service,
                                runtime: serviceManager.runtime(for: service.id),
                                start: { Task { await serviceManager.start(service) } },
                                stop: { Task { await serviceManager.stop(service) } },
                                details: { showDetails(service) },
                                edit: { editService(service) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 270)
            }

            HStack {
                Button("Add service", action: addService)
                Button("Rescan project", action: rescan)
                Spacer()
            }
        }
    }
}

struct ServiceRowView: View {
    var service: ServiceDefinition
    var runtime: ServiceRuntime
    var start: () -> Void
    var stop: () -> Void
    var details: () -> Void
    var edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: details) {
                HStack(spacing: 9) {
                    Image(systemName: service.displayIconCategory.symbolName)
                        .frame(width: 18)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(service.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("· \(service.identityText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 5) {
                            Image(systemName: runtime.status.statusSymbol)
                                .foregroundStyle(runtime.status.tint)
                                .font(.caption2)
                            Text(runtime.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let activePort = runtime.activePort {
                                Text(verbatim: "· :\(activePort)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let exitCode = runtime.lastExitCode, runtime.status == .failed {
                                Text("(\(exitCode))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Details", action: details)
                Button("Edit", action: edit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)

            Button {
                if runtime.status == .running {
                    stop()
                } else if confirmStart(service) {
                    start()
                }
            } label: {
                Image(systemName: runtime.status == .running ? "stop.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .accessibilityLabel(runtime.status == .running ? "Stop \(service.name)" : "Start \(service.name)")
            .help(runtime.status == .running ? "Stop" : "Start")
            .disabled(runtime.status.isTransitioning || runtime.status == .external)
            .frame(width: 44)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func confirmStart(_ service: ServiceDefinition) -> Bool {
        if ExecutionTrustStore.isProjectTrusted(service.projectId) {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Start \(service.name)?"
        alert.informativeText = "Stackvale will run this saved command in:\n\(service.workingDirectory.abbreviatingHomeDirectory())\n\n\(service.resolvedCommand)\n\nOnly trust projects whose commands you understand."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Trust & Start")
        alert.addButton(withTitle: "Start Once")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ExecutionTrustStore.trustProject(service.projectId)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

private enum ExecutionTrustStore {
    private static let trustedProjectIDsKey = "trustedProjectIDs"

    static func isProjectTrusted(_ projectID: UUID) -> Bool {
        trustedProjectIDs.contains(projectID.uuidString)
    }

    static func trustProject(_ projectID: UUID) {
        var ids = trustedProjectIDs
        ids.insert(projectID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: trustedProjectIDsKey)
    }

    private static var trustedProjectIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: trustedProjectIDsKey) ?? [])
    }
}
