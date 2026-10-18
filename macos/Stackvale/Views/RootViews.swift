import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var serviceManager: ServiceManager
    @State private var selectedServiceID: UUID?
    @State private var presentation: DashboardPresentation = .detail

    private var services: [ServiceDefinition] {
        store.projects.flatMap(\.services).sorted {
            rank(serviceManager.runtime(for: $0.id).status) < rank(serviceManager.runtime(for: $1.id).status)
        }
    }

    private var selectedService: ServiceDefinition? {
        guard let selectedServiceID else { return nil }
        return services.first { $0.id == selectedServiceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("StackvaleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("Stackvale")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button {
                    Task { await serviceManager.refreshDockerStatuses(projects: store.projects) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh service statuses")
                Button {
                    presentation = presentation == .detail ? .overview : .detail
                } label: {
                    Image(systemName: presentation == .detail ? "square.grid.2x2" : "rectangle.leadinghalf.inset.filled")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(presentation.toggleLabel)
            }
            .padding(.leading, 120)
            .padding(.trailing, 26)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(310)
            } detail: {
                if let selectedService {
                    switch presentation {
                    case .detail:
                        ServiceDetailsView(
                            service: selectedService,
                            projectName: store.projects.first { $0.id == selectedService.projectId }?.name
                        )
                            .environmentObject(serviceManager)
                    case .overview:
                        overview
                    }
                } else {
                    ContentUnavailableView("Select a service", systemImage: "square.stack.3d.up")
                }
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar(.hidden, for: .windowToolbar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await serviceManager.refreshDockerStatuses(projects: store.projects) }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Serviços").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(services.count) configurados")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                ForEach(IconCategory.allCases.filter { category in services.contains { $0.displayIconCategory == category } }) { category in
                    Text(category.label.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                    ForEach(services.filter { $0.displayIconCategory == category }) { service in
                        Button {
                            selectedServiceID = service.id
                            presentation = .detail
                        } label: {
                            serviceRow(service)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    selectedServiceID == service.id ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func serviceRow(_ service: ServiceDefinition) -> some View {
        let runtime = serviceManager.runtime(for: service.id)
        return HStack(spacing: 12) {
            Image(systemName: service.displayIconCategory.symbolName).frame(width: 18)
            VStack(alignment: .leading) {
                Text(service.name).font(.system(size: 14, weight: .semibold))
                Text(store.projects.first { $0.id == service.projectId }?.name ?? "Unknown project")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(runtime.status.tint)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 1))
        }
        .contentShape(Rectangle())
    }

    private var overview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(services) { service in
                    Button {
                        selectedServiceID = service.id
                        presentation = .detail
                    } label: {
                        ServiceOverviewCard(
                            service: service,
                            projectName: store.projects.first { $0.id == service.projectId }?.name ?? "Unknown project",
                            runtime: serviceManager.runtime(for: service.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }

    private func rank(_ status: RuntimeStatus) -> Int { switch status { case .running: 0; case .starting, .stopping: 1; case .failed: 2; case .stopped, .external, .unknown: 3 } }
}

private enum DashboardPresentation: Equatable {
    case detail
    case overview

    var toggleLabel: String { self == .detail ? "Show overview" : "Show detail" }
    var toggleSymbol: String { self == .detail ? "square.grid.2x2" : "list.bullet" }
}

private struct ServiceOverviewCard: View {
    let service: ServiceDefinition
    let projectName: String
    let runtime: ServiceRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: service.displayIconCategory.symbolName)
                    .font(.title3)
                Spacer()
                Label(runtime.status.label, systemImage: runtime.status.statusSymbol)
                    .font(.caption)
                    .foregroundStyle(runtime.status.tint)
            }
            Text(service.name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(projectName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            Text(service.resolvedCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }
}

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
                Button("Open") {
                    NotificationCenter.default.post(name: .stackvaleOpenDashboard, object: nil)
                }
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
