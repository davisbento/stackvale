import Foundation
import SwiftUI
import AppKit

// MARK: - Service Management

@MainActor
final class ServiceManager: ObservableObject {
    @Published private var runtimes: [UUID: ServiceRuntime] = [:]

    private var processes: [UUID: Process] = [:]
    private var readabilityHandlers: [UUID: [FileHandle]] = [:]
    private let maxLogCharacters = 12_000

    func runtime(for serviceID: UUID) -> ServiceRuntime {
        runtimes[serviceID] ?? .stopped(serviceId: serviceID)
    }

    func start(_ service: ServiceDefinition) async {
        let current = runtime(for: service.id)
        guard current.status != .running && current.status != .starting else { return }

        switch service.kind {
        case .localCommand:
            startLocalCommand(service)
        case .dockerCompose:
            await runDockerCommand(for: service, action: .start)
        }
    }

    func stop(_ service: ServiceDefinition) async {
        let current = runtime(for: service.id)
        guard current.status != .stopped && current.status != .stopping else { return }

        switch service.kind {
        case .localCommand:
            if let process = processes[service.id], process.isRunning {
                stopLocalCommand(service)
            } else if let probe = dockerComposeProbe(for: service) {
                await runInferredDockerStop(for: service, probe: probe)
            } else {
                stopLocalCommand(service)
            }
        case .dockerCompose:
            await runDockerCommand(for: service, action: .stop)
        }
    }

    func refreshDockerStatuses(projects: [Project]) async {
        for service in projects.flatMap(\.services) {
            await refreshDockerStatusIfAvailable(service)
        }
    }

    func removeRuntime(for serviceID: UUID) {
        runtimes.removeValue(forKey: serviceID)
        processes.removeValue(forKey: serviceID)
    }

    func confirmQuit() {
        let runningLocalCount = processes.values.filter(\.isRunning).count
        guard runningLocalCount > 0 else {
            NSApplication.shared.terminate(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Quit Stackvale?"
        alert.informativeText = "\(runningLocalCount) local service process(es) were started by Stackvale. The MVP does not include a detached supervisor, so quitting may stop or orphan them. Docker Compose services running detached are not stopped by quit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private func startLocalCommand(_ service: ServiceDefinition) {
        guard let executable = service.commandExecutable, !executable.isEmpty else {
            setRuntime(service.id, status: .failed, lastError: "No executable configured for this command.")
            return
        }

        guard FileManager.default.fileExists(atPath: service.workingDirectory) else {
            setRuntime(service.id, status: .failed, lastError: "Working directory does not exist: \(service.workingDirectory)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = service.commandArguments
        process.currentDirectoryURL = service.workingDirectoryURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: .starting,
            pidOrContainerId: nil,
            lastExitCode: nil,
            lastError: nil,
            log: "$ \(service.commandDisplay)\n"
        )

        attachLogPipe(outputPipe.fileHandleForReading, serviceID: service.id)
        attachLogPipe(errorPipe.fileHandleForReading, serviceID: service.id)
        readabilityHandlers[service.id] = [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self else { return }
                self.readabilityHandlers[service.id]?.forEach { $0.readabilityHandler = nil }
                self.readabilityHandlers.removeValue(forKey: service.id)
                self.processes.removeValue(forKey: service.id)

                let exitCode = Int(terminatedProcess.terminationStatus)
                let previous = self.runtime(for: service.id)
                let status: RuntimeStatus = exitCode == 0 || previous.status == .stopping ? .stopped : .failed
                var runtime = previous
                runtime.status = status
                runtime.pidOrContainerId = nil
                runtime.lastExitCode = exitCode
                if status == .failed {
                    runtime.lastError = "Process exited with code \(exitCode)."
                }
                runtime.log = self.limitedLog(runtime.log + "\n[process exited with code \(exitCode)]\n")
                self.runtimes[service.id] = runtime

                if exitCode == 0 {
                    await self.refreshDockerStatusIfAvailable(service)
                }
            }
        }

        do {
            try process.run()
            processes[service.id] = process
            var runtime = runtime(for: service.id)
            runtime.status = .running
            runtime.pidOrContainerId = String(process.processIdentifier)
            runtimes[service.id] = runtime
        } catch {
            setRuntime(service.id, status: .failed, lastError: error.localizedDescription)
        }
    }

    private func stopLocalCommand(_ service: ServiceDefinition) {
        guard let process = processes[service.id], process.isRunning else {
            setRuntime(service.id, status: .stopped)
            return
        }

        var runtime = runtime(for: service.id)
        runtime.status = .stopping
        runtime.log = limitedLog(runtime.log + "\n[stopping process \(process.processIdentifier)]\n")
        runtimes[service.id] = runtime

        process.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            process.interrupt()
            var runtime = self.runtime(for: service.id)
            runtime.log = self.limitedLog(runtime.log + "[process did not exit after SIGTERM; sent interrupt]\n")
            self.runtimes[service.id] = runtime
        }
    }

    private func attachLogPipe(_ handle: FileHandle, serviceID: UUID) {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                var runtime = self.runtime(for: serviceID)
                runtime.log = self.limitedLog(runtime.log + chunk)
                self.runtimes[serviceID] = runtime
            }
        }
    }

    private enum DockerAction {
        case start
        case stop
    }

    private func runDockerCommand(for service: ServiceDefinition, action: DockerAction) async {
        guard let composeFile = service.composeFile, let composeService = service.composeService else {
            setRuntime(service.id, status: .failed, lastError: "Missing Compose file or service name.")
            return
        }

        let status: RuntimeStatus = action == .start ? .starting : .stopping
        let commandArguments: [String]
        let commandDisplay: String

        switch action {
        case .start:
            commandArguments = ["docker", "compose", "-f", composeFile, "up", "-d", composeService]
            commandDisplay = "docker compose -f \"\(composeFile)\" up -d \(composeService)"
        case .stop:
            commandArguments = ["docker", "compose", "-f", composeFile, "stop", composeService]
            commandDisplay = "docker compose -f \"\(composeFile)\" stop \(composeService)"
        }

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: status,
            pidOrContainerId: runtime(for: service.id).pidOrContainerId,
            lastExitCode: nil,
            lastError: nil,
            log: runtime(for: service.id).log + "$ \(commandDisplay)\n"
        )

        let result = await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: commandArguments,
            workingDirectory: service.workingDirectoryURL
        )

        var runtime = runtime(for: service.id)
        runtime.lastExitCode = Int(result.exitCode)
        runtime.log = limitedLog(runtime.log + result.output + result.error)

        if result.exitCode == 0 {
            runtime.status = action == .start ? .running : .stopped
            runtime.lastError = nil
        } else {
            runtime.status = .failed
            runtime.lastError = userFriendlyDockerError(result.error.isEmpty ? result.output : result.error)
        }

        runtimes[service.id] = runtime
    }

    private func refreshDockerStatus(_ service: ServiceDefinition) async {
        guard let composeFile = service.composeFile, let composeService = service.composeService else { return }
        await refreshDockerStatus(service, probe: DockerComposeProbe(composeFile: composeFile, services: [composeService]))
    }

    private func refreshDockerStatusIfAvailable(_ service: ServiceDefinition) async {
        switch service.kind {
        case .dockerCompose:
            await refreshDockerStatus(service)
        case .localCommand:
            guard let probe = dockerComposeProbe(for: service) else { return }
            await refreshDockerStatus(service, probe: probe)
        }
    }

    private func refreshDockerStatus(_ service: ServiceDefinition, probe: DockerComposeProbe) async {

        let result = await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["docker", "compose", "-f", probe.composeFile, "ps", "--status", "running", "--services"],
            workingDirectory: service.workingDirectoryURL
        )

        guard result.exitCode == 0 else {
            var runtime = runtime(for: service.id)
            if runtime.status != .running && runtime.status != .starting && runtime.status != .stopping {
                runtime.status = .unknown
            }
            runtime.lastError = userFriendlyDockerError(result.error.isEmpty ? result.output : result.error)
            runtimes[service.id] = runtime
            return
        }

        let runningServices = Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
        var runtime = runtime(for: service.id)
        if runtime.status != .starting && runtime.status != .stopping {
            runtime.status = probe.isSatisfied(by: runningServices) ? .running : .stopped
            runtime.lastError = nil
        }
        runtimes[service.id] = runtime
    }

    private func runInferredDockerStop(for service: ServiceDefinition, probe: DockerComposeProbe) async {
        let commandArguments = ["docker", "compose", "-f", probe.composeFile, "stop"] + probe.services
        let commandDisplay = (["docker", "compose", "-f", "\"\(probe.composeFile)\"", "stop"] + probe.services).joined(separator: " ")

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: .stopping,
            pidOrContainerId: runtime(for: service.id).pidOrContainerId,
            lastExitCode: nil,
            lastError: nil,
            log: runtime(for: service.id).log + "$ \(commandDisplay)\n"
        )

        let result = await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: commandArguments,
            workingDirectory: service.workingDirectoryURL
        )

        var runtime = runtime(for: service.id)
        runtime.lastExitCode = Int(result.exitCode)
        runtime.log = limitedLog(runtime.log + result.output + result.error)

        if result.exitCode == 0 {
            runtime.status = .stopped
            runtime.lastError = nil
        } else {
            runtime.status = .failed
            runtime.lastError = userFriendlyDockerError(result.error.isEmpty ? result.output : result.error)
        }

        runtimes[service.id] = runtime
    }

    private func setRuntime(_ serviceID: UUID, status: RuntimeStatus, lastError: String? = nil) {
        var runtime = runtime(for: serviceID)
        runtime.status = status
        runtime.lastError = lastError
        if let lastError {
            runtime.log = limitedLog(runtime.log + "\n[error] \(lastError)\n")
        }
        runtimes[serviceID] = runtime
    }

    private func limitedLog(_ log: String) -> String {
        guard log.count > maxLogCharacters else { return log }
        return "…" + String(log.suffix(maxLogCharacters))
    }

    private func userFriendlyDockerError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("cannot connect") || trimmed.localizedCaseInsensitiveContains("daemon") {
            return "Docker is not available or the daemon is not running. \(trimmed)"
        }
        if trimmed.localizedCaseInsensitiveContains("command not found") || trimmed.localizedCaseInsensitiveContains("No such file") {
            return "Docker CLI was not found. Install Docker Desktop or make `docker` available on PATH."
        }
        return trimmed.isEmpty ? "Docker command failed." : trimmed
    }

    private struct DockerComposeProbe {
        var composeFile: String
        var services: [String]

        func isSatisfied(by runningServices: Set<String>) -> Bool {
            if services.isEmpty {
                return !runningServices.isEmpty
            }
            return services.allSatisfy { runningServices.contains($0) }
        }
    }

    private func dockerComposeProbe(for service: ServiceDefinition) -> DockerComposeProbe? {
        guard service.kind == .localCommand else { return nil }
        guard let command = dockerBackedCommand(for: service) else { return nil }
        return parseDockerComposeStartCommand(command, workingDirectory: service.workingDirectoryURL)
    }

    private func dockerBackedCommand(for service: ServiceDefinition) -> String? {
        let command = service.commandDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        if let scriptName = packageScriptName(from: service.commandArguments) ?? packageScriptName(from: shellTokens(command)),
           let scriptCommand = packageScriptCommand(named: scriptName, workingDirectory: service.workingDirectoryURL) {
            return scriptCommand
        }

        return command
    }

    private func packageScriptName(from tokens: [String]) -> String? {
        guard let first = tokens.first?.split(separator: "/").last.map(String.init) else { return nil }

        switch first {
        case "npm", "pnpm":
            guard tokens.count >= 3, tokens[1] == "run" else { return nil }
            return tokens[2]
        case "yarn":
            guard tokens.count >= 2 else { return nil }
            return tokens[1] == "run" && tokens.count >= 3 ? tokens[2] : tokens[1]
        case "bun":
            guard tokens.count >= 3, tokens[1] == "run" else { return nil }
            return tokens[2]
        default:
            return nil
        }
    }

    private func packageScriptCommand(named scriptName: String, workingDirectory: URL) -> String? {
        let packageURL = workingDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any],
              let scripts = package["scripts"] as? [String: String] else { return nil }

        return scripts[scriptName]
    }

    private func parseDockerComposeStartCommand(_ command: String, workingDirectory: URL) -> DockerComposeProbe? {
        let tokens = shellTokens(command)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            if tokens[index] == "docker-compose" {
                return dockerComposeProbe(fromComposeTokens: Array(tokens[(index + 1)...]), workingDirectory: workingDirectory)
            }

            if tokens[index] == "docker", index + 1 < tokens.count, tokens[index + 1] == "compose" {
                return dockerComposeProbe(fromComposeTokens: Array(tokens[(index + 2)...]), workingDirectory: workingDirectory)
            }

            index += 1
        }

        return nil
    }

    private func dockerComposeProbe(fromComposeTokens tokens: [String], workingDirectory: URL) -> DockerComposeProbe? {
        var composeFile: String?
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if token == "-f" || token == "--file" {
                guard index + 1 < tokens.count else { return nil }
                composeFile = tokens[index + 1]
                index += 2
                continue
            }

            if token.hasPrefix("--file=") {
                composeFile = String(token.dropFirst("--file=".count))
                index += 1
                continue
            }

            if token == "-p" || token == "--project-name" || token == "--profile" || token == "--env-file" {
                index += 2
                continue
            }

            if token.hasPrefix("-") {
                index += 1
                continue
            }

            break
        }

        guard index < tokens.count else { return nil }
        let action = tokens[index]
        guard action == "up" || action == "start" || action == "restart" else { return nil }

        let actionTokens = Array(tokens[(index + 1)...])
        guard action != "up" || actionTokens.contains("-d") || actionTokens.contains("--detach") else { return nil }

        let services = dockerComposeServiceArguments(from: actionTokens)
        let resolvedComposeFile = resolveComposeFile(composeFile, workingDirectory: workingDirectory)
        guard let resolvedComposeFile else { return nil }

        return DockerComposeProbe(composeFile: resolvedComposeFile, services: services)
    }

    private func dockerComposeServiceArguments(from tokens: [String]) -> [String] {
        var services: [String] = []
        var index = 0
        let optionsWithValues: Set<String> = ["--scale", "--pull", "--wait-timeout", "--timeout", "--attach", "--no-attach", "--exit-code-from"]

        while index < tokens.count {
            let token = tokens[index]

            if token == "--" {
                services.append(contentsOf: tokens.dropFirst(index + 1))
                break
            }

            if token.hasPrefix("--") {
                if optionsWithValues.contains(token), index + 1 < tokens.count {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if token.hasPrefix("-") {
                index += 1
                continue
            }

            services.append(token)
            index += 1
        }

        return services
    }

    private func resolveComposeFile(_ composeFile: String?, workingDirectory: URL) -> String? {
        if let composeFile, !composeFile.isEmpty {
            let url = URL(fileURLWithPath: composeFile, relativeTo: workingDirectory).standardizedFileURL
            return url.path
        }

        let defaultFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
        return defaultFiles
            .map { workingDirectory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .path
    }

    private func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
