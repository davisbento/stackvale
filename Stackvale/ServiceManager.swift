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
            stopLocalCommand(service)
        case .dockerCompose:
            await runDockerCommand(for: service, action: .stop)
        }
    }

    func refreshDockerStatuses(projects: [Project]) async {
        for service in projects.flatMap(\.services) where service.kind == .dockerCompose {
            await refreshDockerStatus(service)
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

        let result = await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["docker", "compose", "-f", composeFile, "ps", "--status", "running", "--services"],
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
            runtime.status = runningServices.contains(composeService) ? .running : .stopped
            runtime.lastError = nil
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
}
