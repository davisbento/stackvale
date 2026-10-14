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

    var runningServiceCount: Int {
        runtimes.values.filter { $0.status == .running }.count
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
        let environment = UserShellEnvironment.resolved()
        do {
            let command = try NodeCommandEnvironment.launchCommand(
                executable: executable,
                arguments: service.commandArguments,
                workingDirectory: service.workingDirectoryURL,
                environment: environment
            )
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } catch {
            setRuntime(service.id, status: .failed, lastError: error.localizedDescription)
            return
        }
        process.currentDirectoryURL = service.workingDirectoryURL
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: .starting,
            pidOrContainerId: nil,
            activePort: nil,
            lastExitCode: nil,
            lastError: nil,
            log: "$ \(service.commandDisplay)\n"
        )

        attachLogPipe(outputPipe.fileHandleForReading, service: service)
        attachLogPipe(errorPipe.fileHandleForReading, service: service)
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
                if status == .stopped {
                    runtime.activePort = nil
                }
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
            runtime.pidOrContainerId = String(process.processIdentifier)
            runtimes[service.id] = runtime

            // Keep startup visible as transitional and poll until the process reports
            // that it is ready. A process can be alive while its framework has already
            // reported a fatal boot error (for example, a missing Node module).
            waitForLocalCommandReadiness(service, process: process)
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

    private func attachLogPipe(_ handle: FileHandle, service: ServiceDefinition) {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                var runtime = self.runtime(for: service.id)
                let updatedLog = self.limitedLog(runtime.log + chunk)
                runtime.log = updatedLog
                if service.kind == .localCommand, let activePort = self.detectActivePort(in: updatedLog) {
                    runtime.activePort = activePort
                }
                if service.kind == .localCommand,
                   (runtime.status == .starting || runtime.status == .running),
                   let errorMessage = self.detectRuntimeError(in: updatedLog) {
                    runtime.status = .failed
                    runtime.lastError = errorMessage
                }
                self.runtimes[service.id] = runtime
            }
        }
    }

    private enum DockerAction {
        case start
        case stop
    }

    private func runDockerCommand(for service: ServiceDefinition, action: DockerAction) async {
        guard let composeFile = service.composeFile, !composeFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setRuntime(service.id, status: .failed, lastError: "Missing Compose file.")
            return
        }
        let composeService = service.composeService?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let serviceArguments = composeService.map { [$0] } ?? []
        let serviceDisplay = composeService.map { " \($0)" } ?? ""

        let status: RuntimeStatus = action == .start ? .starting : .stopping
        let commandArguments: [String]
        let commandDisplay: String

        switch action {
        case .start:
            commandArguments = ["docker", "compose", "-f", composeFile, "up", "-d"] + serviceArguments
            commandDisplay = "docker compose -f \"\(composeFile)\" up -d\(serviceDisplay)"
        case .stop:
            commandArguments = ["docker", "compose", "-f", composeFile, "stop"]
            commandDisplay = "docker compose -f \"\(composeFile)\" stop"
        }

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: status,
            pidOrContainerId: runtime(for: service.id).pidOrContainerId,
            activePort: runtime(for: service.id).activePort,
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
        guard let composeFile = service.composeFile else { return }
        let composeService = service.composeService?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let services = composeService.map { [$0] } ?? []
        await refreshDockerStatus(service, probe: DockerComposeProbe(composeFile: composeFile, services: services))
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
        let commandArguments = ["docker", "compose", "-f", probe.composeFile, "down"]
        let commandDisplay = "docker compose -f \"\(probe.composeFile)\" down"

        runtimes[service.id] = ServiceRuntime(
            serviceId: service.id,
            status: .stopping,
            pidOrContainerId: runtime(for: service.id).pidOrContainerId,
            activePort: runtime(for: service.id).activePort,
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

    private func detectActivePort(in log: String) -> Int? {
        let recentLog = log
            .split(whereSeparator: \.isNewline)
            .suffix(40)
            .joined(separator: "\n")

        let patterns = [
            #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])[:/](\d{2,5})"#,
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})"#,
            #"\b(?:listening|started|running)\b[^\n\r]{0,80}\b(?:on|at)\b[^\n\r]{0,30}:(\d{2,5})\b"#,
            #"\b(?:listening|started|running)\b[^\n\r]{0,80}\bport\s+(\d{2,5})\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(recentLog.startIndex..<recentLog.endIndex, in: recentLog)
            let matches = regex.matches(in: recentLog, range: range).reversed()

            for match in matches where match.numberOfRanges > 1 {
                guard let matchRange = Range(match.range(at: 1), in: recentLog),
                      let port = Int(recentLog[matchRange]),
                      (1...65535).contains(port) else { continue }
                return port
            }
        }

        return nil
    }

    private func detectRuntimeError(in output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let errorPatterns = [
            #"(?i)\[error\]"#,
            #"(?i)\berror:\s"#,
            #"(?i)\b(exception|fatal|panic):\s"#,
            #"(?i)cannot find module"#,
            #"(?i)module_not_found"#,
            #"(?i)command not found"#,
            #"(?i)\b(err!|errno|eaddrinuse|enotfound)\b"#
        ]

        guard let line = lines.last(where: { line in
            errorPatterns.contains { line.range(of: $0, options: .regularExpression) != nil }
        }) else { return nil }

        return line
    }

    private func waitForLocalCommandReadiness(_ service: ServiceDefinition, process: Process) {
        Task { @MainActor [weak self, weak process] in
            guard let self, let process else { return }

            while process.isRunning {
                try? await Task.sleep(for: .seconds(2))
                guard process.isRunning else { return }

                let runtime = self.runtime(for: service.id)
                guard runtime.status == .starting else { return }
                guard runtime.lastError == nil else { return }

                if self.hasStartupReadinessSignal(in: runtime.log, activePort: runtime.activePort) {
                    var readyRuntime = runtime
                    readyRuntime.status = .running
                    self.runtimes[service.id] = readyRuntime
                    return
                }
            }
        }
    }

    private func hasStartupReadinessSignal(in log: String, activePort: Int?) -> Bool {
        if activePort != nil { return true }

        let readinessPatterns = [
            #"(?i)\b(listening|started|ready|running)\b[^\n\r]{0,120}(?:on|at|port|http://|https://)"#,
            #"(?i)\b(local|network):\s+https?://"#,
            #"(?i)\bcompiled successfully\b"#,
            #"(?i)\bserver is ready\b"#
        ]

        return readinessPatterns.contains {
            log.range(of: $0, options: .regularExpression) != nil
        }
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
