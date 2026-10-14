import SwiftUI
import AppKit

// MARK: - Service editor / details

struct ServiceEditorView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var project: Project?
    var service: ServiceDefinition?

    @State private var name: String
    @State private var kind: ServiceKind
    @State private var workingDirectory: String
    @State private var command: String
    @State private var composeFile: String
    @State private var composeService: String
    @State private var displayPort: String
    @State private var iconCategory: IconCategory
    @State private var validationMessage: String?

    init(project: Project?, service: ServiceDefinition?) {
        self.project = project
        self.service = service
        _name = State(initialValue: service?.name ?? "")
        _kind = State(initialValue: service?.kind ?? .localCommand)
        _workingDirectory = State(initialValue: service?.workingDirectory ?? project?.rootPath ?? NSHomeDirectory())
        _command = State(initialValue: service?.commandDisplay ?? "")
        _composeFile = State(initialValue: service?.composeFile ?? "")
        _composeService = State(initialValue: service?.composeService ?? "")
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
                        TextField("Compose service", text: $composeService)
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
                Button("Cancel") { dismiss() }
                Button("Save") { saveService() }
                    .buttonStyle(.borderedProminent)
                    .disabled(project == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
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
            guard !composeFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !composeService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationMessage = "Compose file and service are required."
                return
            }
            draft = ServiceDraft(
                name: trimmedName,
                kind: kind,
                workingDirectory: workingDirectory,
                source: service?.source ?? .manual,
                commandExecutable: nil,
                commandArguments: [],
                commandDisplay: "docker compose -f \(URL(fileURLWithPath: composeFile).lastPathComponent) up -d \(composeService)",
                composeFile: composeFile,
                composeService: composeService,
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
        dismiss()
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
            dismiss()
        }
    }
}

struct ServiceDetailsView: View {
    @EnvironmentObject private var serviceManager: ServiceManager
    @Environment(\.dismiss) private var dismiss
    var service: ServiceDefinition

    var body: some View {
        let runtime = serviceManager.runtime(for: service.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: service.displayIconCategory.symbolName)
                Text(service.name)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                detailRow("Status", runtime.status.label)
                detailRow("Type", service.kind.label)
                detailRow("Source", service.source.label)
                detailRow("Command", service.resolvedCommand)
                detailRow("Directory", service.workingDirectory.abbreviatingHomeDirectory())
                if let pid = runtime.pidOrContainerId {
                    detailRow(service.kind == .dockerCompose ? "Container" : "PID", pid)
                }
                if let lastExitCode = runtime.lastExitCode {
                    detailRow("Last exit", String(lastExitCode))
                }
                if let lastError = runtime.lastError, !lastError.isEmpty {
                    detailRow("Last error", lastError)
                }
            }

            Text("Logs")
                .font(.headline)
            ScrollView {
                Text(runtime.log.isEmpty ? "No logs captured yet." : runtime.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 220)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 620, height: 520)
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
}
