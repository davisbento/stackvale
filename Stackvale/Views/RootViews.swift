import SwiftUI
import AppKit

// MARK: - Root UI

private enum RootSheet: Identifiable {
    case projectSetup(URL)
    case addService(Project)
    case editService(ServiceDefinition)
    case serviceDetails(ServiceDefinition)
    case rescan(Project)
    case manageProjects

    var id: String {
        switch self {
        case .projectSetup(let url): "projectSetup-\(url.path)"
        case .addService(let project): "addService-\(project.id)"
        case .editService(let service): "editService-\(service.id)"
        case .serviceDetails(let service): "serviceDetails-\(service.id)"
        case .rescan(let project): "rescan-\(project.id)"
        case .manageProjects: "manageProjects"
        }
    }
}

struct StackvaleRootView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var serviceManager: ServiceManager
    @State private var sheet: RootSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.projects.isEmpty {
                EmptyStateView(addProject: chooseProjectDirectory)
            } else if let project = store.selectedProject {
                ProjectOverviewView(
                    project: project,
                    addService: { sheet = .addService(project) },
                    editService: { sheet = .editService($0) },
                    showDetails: { sheet = .serviceDetails($0) },
                    rescan: { sheet = .rescan(project) },
                    manageProjects: { sheet = .manageProjects }
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
        .onAppear {
            Task { await serviceManager.refreshDockerStatuses(projects: store.projects) }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .projectSetup(let url):
                ProjectSetupView(rootURL: url)
                    .environmentObject(store)
            case .addService(let project):
                ServiceEditorView(project: project, service: nil)
                    .environmentObject(store)
            case .editService(let service):
                ServiceEditorView(project: store.projects.first { $0.id == service.projectId }, service: service)
                    .environmentObject(store)
            case .serviceDetails(let service):
                ServiceDetailsView(service: service)
                    .environmentObject(serviceManager)
            case .rescan(let project):
                RescanProjectView(project: project)
                    .environmentObject(store)
            case .manageProjects:
                ManageProjectsView()
                    .environmentObject(store)
            }
        }
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
                Picker("Project", selection: selectedProjectBinding) {
                    ForEach(store.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
        if let url = chooseDirectory(title: "Choose a project folder") {
            sheet = .projectSetup(url)
        }
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
    var manageProjects: () -> Void

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
                .help("Refresh Docker Compose statuses")
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

            Button("Manage projects", action: manageProjects)
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
                    Image(systemName: service.iconCategory.symbolName)
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
            .frame(width: 24)

            Button(runtime.status == .running ? "Stop" : "Start") {
                if runtime.status == .running {
                    stop()
                } else if confirmStart(service) {
                    start()
                }
            }
            .disabled(runtime.status.isTransitioning || runtime.status == .external)
            .frame(width: 64)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func confirmStart(_ service: ServiceDefinition) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start \(service.name)?"
        alert.informativeText = "Stackvale will run this saved command in:\n\(service.workingDirectory.abbreviatingHomeDirectory())\n\n\(service.resolvedCommand)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
