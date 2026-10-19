import SwiftUI
import AppKit

// MARK: - Service editor / details

struct ServiceEditorView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var project: Project?
    var service: ServiceDefinition?
    var compact = false
    var onClose: (() -> Void)?

    @State private var name: String
    @State private var kind: ServiceKind
    @State private var workingDirectory: String
    @State private var command: String
    @State private var composeFile: String
    @State private var displayPort: String
    @State private var iconCategory: IconCategory
    @State private var validationMessage: String?

    init(project: Project?, service: ServiceDefinition?, compact: Bool = false, onClose: (() -> Void)? = nil) {
        self.project = project
        self.service = service
        self.compact = compact
        self.onClose = onClose
        _name = State(initialValue: service?.name ?? "")
        _kind = State(initialValue: service?.kind ?? .localCommand)
        _workingDirectory = State(initialValue: service?.workingDirectory ?? project?.rootPath ?? NSHomeDirectory())
        _command = State(initialValue: service?.commandDisplay ?? "")
        _composeFile = State(initialValue: service?.composeFile ?? "")
        _displayPort = State(initialValue: service?.displayPort.map(String.init) ?? "")
        _iconCategory = State(initialValue: service?.iconCategory ?? .generic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(service == nil ? "Add Service" : "Edit Service")
                .font(.title2.weight(.semibold))

            if project == nil {
                Text("Project not found.")
                    .foregroundStyle(.red)
            } else {
                Form {
                    TextField("Name", text: $name)

                    Picker("Type", selection: $kind) {
                        ForEach(ServiceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .onChange(of: kind) { _, newValue in
                        if newValue == .dockerCompose && iconCategory == .generic {
                            iconCategory = .docker
                        }
                    }

                    HStack {
                        TextField("Working directory", text: $workingDirectory)
                        Button("Choose…") {
                            if let url = chooseDirectory(title: "Choose working directory") {
                                workingDirectory = url.path
                            }
                        }
                    }

                    if kind == .localCommand {
                        TextField("Command", text: $command)
                    } else {
                        HStack {
                            TextField("Compose file", text: $composeFile)
                            Button("Choose…") {
                                if let url = chooseFile(title: "Choose Docker Compose file") {
                                    composeFile = url.path
                                }
                            }
                        }
                        Text("Runs all services defined in the selected Compose file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Display port (optional)", text: $displayPort)

                    Picker("Icon", selection: $iconCategory) {
                        ForEach(IconCategory.allCases) { category in
                            Label(category.label, systemImage: category.symbolName).tag(category)
                        }
                    }
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                Text("Manual shell commands are trusted user input and run with your account privileges. Stackvale never uses sudo automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if service != nil {
                    Button("Delete", role: .destructive) { deleteService() }
                }
                Spacer()
                Button("Cancel") { close() }
                Button("Save") { saveService() }
                    .buttonStyle(.borderedProminent)
                    .disabled(project == nil)
            }
        }
        .padding(compact ? 16 : 20)
        .frame(width: compact ? 430 : 560)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func saveService() {
        guard let project else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Service name is required."
            return
        }

        guard !store.serviceNameExists(trimmedName, in: project.id, excluding: service?.id) else {
            validationMessage = "A service with this name already exists in this project."
            return
        }

        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            validationMessage = "Working directory does not exist."
            return
        }

        let port: Int?
        if displayPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            port = nil
        } else if let parsed = Int(displayPort), (1...65535).contains(parsed) {
            port = parsed
        } else {
            validationMessage = "Display port must be between 1 and 65535."
            return
        }

        var draft: ServiceDraft
        switch kind {
        case .localCommand:
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationMessage = "Command is required."
                return
            }
            draft = ServiceDraft(
                name: trimmedName,
                kind: kind,
                workingDirectory: workingDirectory,
                source: service?.source ?? .manual,
                commandExecutable: "/bin/zsh",
                commandArguments: ["-lc", command],
                commandDisplay: command,
                composeFile: nil,
                composeService: nil,
                displayPort: port,
                iconCategory: iconCategory,
                origin: "Manual"
            )
        case .dockerCompose:
            let trimmedComposeFile = composeFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedComposeFile.isEmpty else {
                validationMessage = "Compose file is required."
                return
            }
            draft = ServiceDraft(
                name: trimmedName,
                kind: kind,
                workingDirectory: workingDirectory,
                source: service?.source ?? .manual,
                commandExecutable: nil,
                commandArguments: [],
                commandDisplay: "docker compose -f \(URL(fileURLWithPath: trimmedComposeFile).lastPathComponent) up -d",
                composeFile: trimmedComposeFile,
                composeService: nil,
                displayPort: port,
                iconCategory: iconCategory,
                origin: "Manual"
            )
        }

        let definition = draft.makeService(projectID: project.id, existingID: service?.id)
        if service == nil {
            store.addService(definition, to: project.id)
        } else {
            store.updateService(definition)
        }
        close()
    }

    private func deleteService() {
        guard let project, let service else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(service.name)?"
        alert.informativeText = "Deleting a service definition does not stop any running process. Stop it first if needed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeService(service.id, from: project.id)
            close()
        }
    }
}

struct ServiceDetailsView: View {
    @EnvironmentObject private var serviceManager: ServiceManager
    @Environment(\.dismiss) private var dismiss
    var service: ServiceDefinition
    var projectName: String?
    var compact = false
    var onClose: (() -> Void)?

    @State private var selectedPanel: DetailsPanel = .logs
    @StateObject private var terminal: TerminalSession

    private enum DetailsPanel: String, CaseIterable, Identifiable {
        case logs
        case terminal

        var id: String { rawValue }
        var label: String { self == .logs ? "Logs" : "Terminal" }
    }

    init(service: ServiceDefinition, projectName: String? = nil, compact: Bool = false, onClose: (() -> Void)? = nil) {
        self.service = service
        self.projectName = projectName
        self.compact = compact
        self.onClose = onClose
        _terminal = StateObject(wrappedValue: TerminalSession(workingDirectory: service.workingDirectoryURL))
    }

    var body: some View {
        let runtime = serviceManager.runtime(for: service.id)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                if compact {
                    Button(action: close) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Back")
                }
                Image(systemName: service.displayIconCategory.symbolName)
                    .font(.system(size: 24))
                    .frame(width: 46, height: 46)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(service.displayIconCategory.label) · \(projectName ?? service.workingDirectoryURL.lastPathComponent)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(service.name)
                        .font(.system(size: 25, weight: .semibold))
                }
                Spacer()
                Button("Open directory", systemImage: "folder") {
                    NSWorkspace.shared.open(service.workingDirectoryURL)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open working directory")
                Button {
                    if runtime.status == .running {
                        Task { await serviceManager.stop(service) }
                    } else {
                        Task { await serviceManager.start(service) }
                    }
                } label: {
                    Label(runtime.status == .running ? "Parar" : "Iniciar", systemImage: runtime.status == .running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runtime.status.isTransitioning || runtime.status == .external)
            }

            HStack(spacing: 12) {
                metadataCard("COMANDO", service.kind == .localCommand ? service.commandDisplay : service.resolvedCommand)
                metadataCard("DIRETÓRIO", service.workingDirectory.abbreviatingHomeDirectory())
            }

            Picker("Painel de detalhes", selection: $selectedPanel) {
                ForEach(DetailsPanel.allCases) { panel in
                    Text(panel.label).tag(panel)
                }
            }
            .pickerStyle(.segmented)

            if selectedPanel == .logs {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Atividade").font(.headline)
                        Spacer()
                        Label(runtime.status == .running ? "Em execução" : "Pronto para iniciar", systemImage: "circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(runtime.status == .running ? .green : .secondary)
                    }
                    .padding(16)
                    Divider()
                    ScrollView {
                        Text(runtime.log.isEmpty ? "Nenhum processo em execução.\n\nInicie o serviço para acompanhar os logs aqui." : runtime.log)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            }

            if selectedPanel == .terminal {
                TerminalPanelView(session: terminal, workingDirectory: service.workingDirectory, compact: compact)
            }
        }
        .onAppear {
            if selectedPanel == .terminal {
                terminal.start()
            }
        }
        .onChange(of: selectedPanel) { _, panel in
            if panel == .terminal {
                terminal.start()
            }
        }
        .onDisappear {
            terminal.terminate()
        }
        .padding(compact ? 16 : 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func metadataCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }
}

private struct TerminalPanelView: View {
    @ObservedObject var session: TerminalSession
    var workingDirectory: String
    var compact: Bool
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs in \(workingDirectory.abbreviatingHomeDirectory())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "Terminal ready. Type a command below." : session.output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("terminal-output")
                }
                .onChange(of: session.output) { _, _ in
                    proxy.scrollTo("terminal-output", anchor: .bottom)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: compact ? 150 : 220, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text("$")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                TextField("Enter command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit(runCommand)
                Button("Run", action: runCommand)
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.isRunning)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Text("Commands run with your account privileges. Only run commands you trust.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { session.start() }
    }

    private func runCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.send(trimmed)
        command = ""
    }
}
