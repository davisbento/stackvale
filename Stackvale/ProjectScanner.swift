import Foundation

// MARK: - Discovery

struct ProjectScanResult {
    var candidates: [ServiceDraft]
    var composeFiles: [URL]
    var warnings: [String]
}

struct ServiceDraft: Identifiable, Equatable {
    var id = UUID()
    var selected = true
    var name: String
    var kind: ServiceKind
    var workingDirectory: String
    var source: ServiceSource
    var commandExecutable: String?
    var commandArguments: [String]
    var commandDisplay: String
    var composeFile: String?
    var composeService: String?
    var displayPort: Int?
    var iconCategory: IconCategory
    var origin: String

    func makeService(projectID: UUID, existingID: UUID? = nil) -> ServiceDefinition {
        let trimmedCommand = commandDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedExecutable: String?
        let resolvedArguments: [String]

        if kind == .localCommand {
            if commandExecutable == "/usr/bin/env" && commandArguments.joined(separator: " ") == trimmedCommand {
                resolvedExecutable = commandExecutable
                resolvedArguments = commandArguments
            } else if commandExecutable == "/bin/zsh" && commandArguments.count == 2 && commandArguments.last == trimmedCommand {
                resolvedExecutable = commandExecutable
                resolvedArguments = commandArguments
            } else {
                resolvedExecutable = "/bin/zsh"
                resolvedArguments = ["-lc", trimmedCommand]
            }
        } else {
            resolvedExecutable = commandExecutable
            resolvedArguments = commandArguments
        }

        return ServiceDefinition(
            id: existingID ?? UUID(),
            projectId: projectID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            workingDirectory: workingDirectory,
            source: source,
            commandExecutable: resolvedExecutable,
            commandArguments: resolvedArguments,
            commandDisplay: trimmedCommand,
            composeFile: composeFile,
            composeService: composeService,
            displayPort: displayPort,
            iconCategory: iconCategory
        )
    }
}

enum ProjectScanner {
    static func scanRoot(_ rootURL: URL) async -> ProjectScanResult {
        var candidates: [ServiceDraft] = []
        var warnings: [String] = []

        let packageURL = rootURL.appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: packageURL.path) {
            do {
                let packageCandidates = try scanPackageJSON(packageURL: packageURL, rootURL: rootURL, warnings: &warnings)
                candidates.append(contentsOf: packageCandidates)
            } catch {
                warnings.append("Could not read package.json: \(error.localizedDescription)")
            }
        }

        let composeFiles = findComposeFiles(rootURL: rootURL)
        if composeFiles.count == 1, let composeFile = composeFiles.first {
            let composeResult = await scanComposeFile(composeFile, rootURL: rootURL)
            candidates.append(contentsOf: composeResult.candidates)
            warnings.append(contentsOf: composeResult.warnings)
        } else if composeFiles.count > 1 {
            warnings.append("Multiple Docker Compose files were found. Choose one to enumerate services; Stackvale will not merge them automatically.")
        }

        return ProjectScanResult(candidates: candidates, composeFiles: composeFiles, warnings: warnings)
    }

    static func scanComposeFile(_ composeFile: URL, rootURL: URL) async -> (candidates: [ServiceDraft], warnings: [String]) {
        let result = await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["docker", "compose", "-f", composeFile.path, "config", "--services"],
            workingDirectory: rootURL
        )

        guard result.exitCode == 0 else {
            let raw = result.error.isEmpty ? result.output : result.error
            return ([], ["Could not enumerate Docker Compose services for \(composeFile.lastPathComponent): \(friendlyDockerDiscoveryError(raw))"])
        }

        let services = result.output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidates = services.map { service in
            ServiceDraft(
                name: service,
                kind: .dockerCompose,
                workingDirectory: rootURL.path,
                source: .discovered,
                commandExecutable: nil,
                commandArguments: [],
                commandDisplay: "docker compose -f \(composeFile.lastPathComponent) up -d \(service)",
                composeFile: composeFile.path,
                composeService: service,
                displayPort: nil,
                iconCategory: .docker,
                origin: composeFile.lastPathComponent
            )
        }

        return (candidates, [])
    }

    private static func scanPackageJSON(packageURL: URL, rootURL: URL, warnings: inout [String]) throws -> [ServiceDraft] {
        let data = try Data(contentsOf: packageURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let package = object as? [String: Any] else { return [] }
        guard let scripts = package["scripts"] as? [String: String], !scripts.isEmpty else { return [] }

        let packageManager = detectPackageManager(package: package, rootURL: rootURL, warnings: &warnings)
        let scriptNames = orderedScriptNames(scripts)

        return scriptNames.compactMap { scriptName in
            guard let scriptCommand = scripts[scriptName], isRunnableProjectScript(scriptName: scriptName, scriptCommand: scriptCommand) else { return nil }

            let runArguments = packageManager == "yarn" ? [scriptName] : ["run", scriptName]
            let commandArguments = [packageManager] + runArguments
            let commandDisplay = ([packageManager] + runArguments).joined(separator: " ")

            return ServiceDraft(
                name: displayName(forScriptName: scriptName),
                kind: .localCommand,
                workingDirectory: rootURL.path,
                source: .discovered,
                commandExecutable: "/usr/bin/env",
                commandArguments: commandArguments,
                commandDisplay: commandDisplay,
                composeFile: nil,
                composeService: nil,
                displayPort: detectPort(in: scriptCommand),
                iconCategory: suggestedIconCategory(scriptName: scriptName, scriptCommand: scriptCommand),
                origin: "package.json · \(scriptName)"
            )
        }
    }

    private static func detectPackageManager(package: [String: Any], rootURL: URL, warnings: inout [String]) -> String {
        if let packageManager = package["packageManager"] as? String,
           let name = packageManager.split(separator: "@").first,
           !name.isEmpty {
            return String(name)
        }

        let lockfiles: [(String, String)] = [
            ("pnpm-lock.yaml", "pnpm"),
            ("yarn.lock", "yarn"),
            ("package-lock.json", "npm"),
            ("bun.lock", "bun"),
            ("bun.lockb", "bun")
        ]

        let matches = lockfiles.filter { FileManager.default.fileExists(atPath: rootURL.appendingPathComponent($0.0).path) }
        let managers = Array(Set(matches.map(\.1)))

        if managers.count == 1, let manager = managers.first {
            return manager
        }

        if managers.count > 1 {
            warnings.append("Multiple package manager lockfiles were found. Stackvale used npm for command previews; edit services before saving if needed.")
        }

        return "npm"
    }

    private static func orderedScriptNames(_ scripts: [String: String]) -> [String] {
        scripts.keys
            .filter { scriptName in
                guard let scriptCommand = scripts[scriptName] else { return false }
                return isRunnableProjectScript(scriptName: scriptName, scriptCommand: scriptCommand)
            }
            .sorted { left, right in
                let leftRank = scriptPriorityRank(left)
                let rightRank = scriptPriorityRank(right)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    private static func isInstallLifecycleScript(_ name: String) -> Bool {
        ["preinstall", "install", "postinstall", "prepare"].contains(name)
    }

    private static func isRunnableProjectScript(scriptName: String, scriptCommand: String) -> Bool {
        let tokens = scriptNameTokens(scriptName)
        guard !isInstallLifecycleScript(scriptName), !tokens.contains(where: maintenanceScriptTokens.contains) else {
            return false
        }

        if tokens.contains(where: runnableScriptTokens.contains) {
            return true
        }

        return commandLooksLikeProjectRunner(scriptCommand)
    }

    private static func scriptPriorityRank(_ scriptName: String) -> Int {
        let tokens = scriptNameTokens(scriptName)
        let exactName = scriptName.lowercased()
        let priorities = ["dev", "start", "serve", "preview", "storybook", "server"]

        for (index, priority) in priorities.enumerated() where exactName == priority {
            return index
        }

        for (index, priority) in priorities.enumerated() where tokens.contains(priority) {
            return priorities.count + index
        }

        return priorities.count * 2
    }

    private static var runnableScriptTokens: Set<String> {
        ["dev", "start", "serve", "preview", "storybook", "server"]
    }

    private static var maintenanceScriptTokens: Set<String> {
        [
            "analyze", "audit", "build", "check", "clean", "codegen", "compile", "deploy", "eslint", "fmt",
            "format", "gen", "generate", "jest", "lint", "migrate", "mocha", "prettier", "release", "spec",
            "stylelint", "test", "tsc", "type", "typecheck", "typegen", "types", "typings", "validate", "vitest"
        ]
    }

    private static func scriptNameTokens(_ name: String) -> Set<String> {
        let tokens = name
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        return Set(tokens)
    }

    private static func commandLooksLikeProjectRunner(_ command: String) -> Bool {
        let normalizedCommand = command
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalizedCommand.isEmpty else { return false }

        let maintenanceCommandPatterns = [
            #"\b(eslint|prettier|stylelint|tsc|vitest|jest|mocha|playwright|cypress|tsup|rollup)\b"#,
            #"\b(typecheck|type-check|typegen|codegen)\b"#,
            #"\b(prisma\s+generate|graphql-codegen)\b"#,
            #"\b(next|vite|astro|nuxt|remix)\s+build\b"#
        ]

        if maintenanceCommandPatterns.contains(where: { normalizedCommand.matches(pattern: $0) }) {
            return false
        }

        let runnerCommandPatterns = [
            #"(^|&&|\|\||;)\s*(next|nuxt|astro|remix|vite)\s+(dev|start|preview)\b"#,
            #"(^|&&|\|\||;)\s*webpack\s+serve\b"#,
            #"(^|&&|\|\||;)\s*(storybook|start-storybook)\b"#,
            #"(^|&&|\|\||;)\s*(http-server|serve|sirv)\b"#,
            #"(^|&&|\|\||;)\s*(node|tsx|ts-node|bun)\s+.*\b(server|app|index|main)\.(js|ts|mjs|cjs)\b"#,
            #"(^|&&|\|\||;)\s*docker(-compose|\s+compose)\b.*\b(up\s+.*-d|-d\s+.*up|start)\b"#
        ]

        return runnerCommandPatterns.contains { normalizedCommand.matches(pattern: $0) }
    }

    private static func displayName(forScriptName scriptName: String) -> String {
        switch scriptName {
        case "dev": "Dev"
        case "start": "Start"
        case "serve": "Serve"
        case "preview": "Preview"
        default:
            scriptName
                .replacingOccurrences(of: ":", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func suggestedIconCategory(scriptName: String, scriptCommand: String) -> IconCategory {
        let haystack = "\(scriptName) \(scriptCommand)".lowercased()
        if haystack.contains("docker compose") || haystack.contains("docker-compose") {
            return .docker
        }

        let webHints = ["next", "vite", "astro", "nuxt", "remix", "webpack", "storybook", "http-server", "serve", "--host", "--port"]
        if webHints.contains(where: { haystack.contains($0) }) || ["dev", "start", "preview"].contains(scriptName) {
            return .web
        }
        return .nodejs
    }

    private static func detectPort(in command: String) -> Int? {
        let patterns = [
            #"(?:--port|PORT=|port\s+|:)(\d{2,5})"#,
            #"(?:-p\s+)(\d{2,5})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            guard let match = regex.firstMatch(in: command, range: range), match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: command),
                  let port = Int(command[matchRange]), (1...65535).contains(port) else { continue }
            return port
        }

        return nil
    }

    private static func findComposeFiles(rootURL: URL) -> [URL] {
        ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
            .map { rootURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func friendlyDockerDiscoveryError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("cannot connect") || trimmed.localizedCaseInsensitiveContains("daemon") {
            return "Docker is not available or the daemon is not running."
        }
        if trimmed.localizedCaseInsensitiveContains("No such file") {
            return "Docker CLI was not found."
        }
        return trimmed.isEmpty ? "Docker Compose returned no details." : trimmed
    }
}

private extension String {
    func matches(pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

struct CommandResult {
    var exitCode: Int32
    var output: String
    var error: String
}

enum CommandRunner {
    static func run(executable: String, arguments: [String], workingDirectory: URL?) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(exitCode: process.terminationStatus, output: output, error: error))
                } catch {
                    continuation.resume(returning: CommandResult(exitCode: 127, output: "", error: error.localizedDescription))
                }
            }
        }
    }
}
