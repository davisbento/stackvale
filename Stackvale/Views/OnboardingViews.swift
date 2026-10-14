import SwiftUI
import AppKit

// MARK: - Onboarding / Rescan

struct ProjectSetupView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectName: String
    @State private var candidates: [ServiceDraft] = []
    @State private var composeFiles: [URL] = []
    @State private var selectedComposeFile: URL?
    @State private var warnings: [String] = []
    @State private var isScanning = true

    var rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        _projectName = State(initialValue: rootURL.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Project")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $projectName)
                Text(rootURL.path.abbreviatingHomeDirectory())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isScanning {
                HStack {
                    ProgressView()
                    Text("Scanning metadata…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                DiscoveryWarningsView(warnings: warnings)

                if composeFiles.count > 1 {
                    HStack {
                        Picker("Compose", selection: $selectedComposeFile) {
                            ForEach(composeFiles, id: \.path) { file in
                                Text(file.lastPathComponent).tag(Optional(file))
                            }
                        }
                        Button("Load services") {
                            Task { await loadSelectedComposeFile() }
                        }
                    }
                }

                CandidateListView(candidates: $candidates)

                Button {
                    candidates.append(.manualDefault(workingDirectory: rootURL.path))
                } label: {
                    Label("Add manual service", systemImage: "plus")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Project") { saveProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isScanning)
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
        .task { await scan() }
    }

    private func scan() async {
        isScanning = true
        let result = await ProjectScanner.scanRoot(rootURL)
        candidates = result.candidates
        composeFiles = result.composeFiles
        selectedComposeFile = result.composeFiles.first
        warnings = result.warnings
        isScanning = false
    }

    private func loadSelectedComposeFile() async {
        guard let selectedComposeFile else { return }
        let result = await ProjectScanner.scanComposeFile(selectedComposeFile, rootURL: rootURL)
        let existingKeys = Set(candidates.compactMap { draft -> String? in
            guard let composeFile = draft.composeFile, let composeService = draft.composeService else { return nil }
            return "\(composeFile)::\(composeService)"
        })
        let newCandidates = result.candidates.filter { draft in
            guard let composeFile = draft.composeFile, let service = draft.composeService else { return true }
            return !existingKeys.contains("\(composeFile)::\(service)")
        }
        candidates.append(contentsOf: newCandidates)
        warnings.append(contentsOf: result.warnings)
    }

    private func saveProject() {
        let projectID = UUID()
        let services = candidates
            .filter(\.selected)
            .map { $0.makeService(projectID: projectID) }

        let project = Project(
            id: projectID,
            name: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            rootPath: rootURL.path,
            createdAt: Date(),
            services: services
        )
        store.addProject(project)
        dismiss()
    }
}

struct RescanProjectView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ServiceDraft] = []
    @State private var warnings: [String] = []
    @State private var isScanning = true

    var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rescan \(project.name)")
                .font(.title2.weight(.semibold))
            Text("Scanning reads project metadata only. It does not start scripts or Compose services.")
                .foregroundStyle(.secondary)

            if isScanning {
                HStack { ProgressView(); Text("Scanning…") }
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                DiscoveryWarningsView(warnings: warnings)
                CandidateListView(candidates: $candidates)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import Selected") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidates.filter(\.selected).isEmpty || isScanning)
            }
        }
        .padding(20)
        .frame(width: 680, height: 580)
        .task { await scan() }
    }

    private func scan() async {
        isScanning = true
        let result = await ProjectScanner.scanRoot(project.rootURL)
        let existingNames = Set(project.services.map { $0.name.lowercased() })
        candidates = result.candidates.map { draft in
            var draft = draft
            if existingNames.contains(draft.name.lowercased()) {
                draft.name += " Copy"
            }
            return draft
        }
        warnings = result.warnings
        isScanning = false
    }

    private func importSelected() {
        let services = candidates.filter(\.selected).map { $0.makeService(projectID: project.id) }
        store.addServices(services, to: project.id)
        dismiss()
    }
}

struct DiscoveryWarningsView: View {
    var warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

struct CandidateListView: View {
    @Binding var candidates: [ServiceDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service candidates")
                .font(.headline)

            if candidates.isEmpty {
                ContentUnavailableView("No candidates found", systemImage: "magnifyingglass", description: Text("Add services manually before saving, or save an empty project."))
                    .frame(height: 160)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($candidates) { $candidate in
                            CandidateRowView(candidate: $candidate)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct CandidateRowView: View {
    @Binding var candidate: ServiceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $candidate.selected)
                    .labelsHidden()
                TextField("Name", text: $candidate.name)
                    .font(.headline)
                Picker("Icon", selection: $candidate.iconCategory) {
                    ForEach(IconCategory.allCases) { category in
                        Label(category.label, systemImage: category.symbolName).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 135)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(candidate.origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("Command", text: $candidate.commandDisplay)
                    .font(.caption.monospaced())
                    .disabled(!candidate.selected)
            }

            HStack {
                Text("Working directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Working directory", text: $candidate.workingDirectory)
                    .font(.caption)
                Button("Choose…") {
                    if let url = chooseDirectory(title: "Choose working directory") {
                        candidate.workingDirectory = url.path
                    }
                }
                .disabled(!candidate.selected)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
