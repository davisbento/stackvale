import Foundation

/// Prepares Node in the service's shell, without changing the user's saved command or global environment.
enum NodeCommandEnvironment {
    struct LaunchCommand {
        var executable: String
        var arguments: [String]
    }

    private struct Requirement {
        var version: String
        var source: String
        var isRange: Bool
    }

    static func launchCommand(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> LaunchCommand {
        let original = LaunchCommand(executable: executable, arguments: arguments)
        guard isNodeCommand(executable: executable, arguments: arguments),
              let requirement = try findRequirement(in: workingDirectory) else { return original }

        let nvmDirectory = environment["NVM_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["XDG_CONFIG_HOME"].map { "\($0)/nvm" }
            ?? "\(environment["HOME"] ?? NSHomeDirectory())/.nvm"
        let version: String
        if requirement.isRange {
            let range = try NodeVersionRange(requirement.version)
            let versionsURL = URL(fileURLWithPath: nvmDirectory).appendingPathComponent("versions/node")
            let installed = (try? FileManager.default.contentsOfDirectory(at: versionsURL, includingPropertiesForKeys: nil)) ?? []
            let matching = installed.compactMap { url -> NodeVersion? in
                guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/node").path),
                      let version = NodeVersion(url.lastPathComponent), range.contains(version) else { return nil }
                return version
            }
            guard let selected = matching.max() else {
                throw PreparationError("No installed nvm Node version satisfies \(requirement.version) (\(requirement.source)). Install a compatible version with nvm, or pin one in .nvmrc.")
            }
            version = selected.description
        } else {
            version = requirement.version
        }

        // A second login shell could overwrite the PATH chosen by nvm. Keep the saved shell command
        // in a non-login shell, using the login environment already resolved by Stackvale.
        let command: String
        if executable == "/bin/zsh", arguments.count == 2, ["-lc", "-c"].contains(arguments[0]) {
            command = "exec /bin/zsh -c \(shellQuote(arguments[1]))"
        } else {
            command = "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ")
        }

        let script = """
        export NVM_DIR=\(shellQuote(nvmDirectory))
        stackvale_nvm_script="$NVM_DIR/nvm.sh"
        if [ ! -s "$stackvale_nvm_script" ]; then
            for stackvale_candidate in /opt/homebrew/opt/nvm/nvm.sh /usr/local/opt/nvm/nvm.sh; do
                if [ -s "$stackvale_candidate" ]; then
                    stackvale_nvm_script="$stackvale_candidate"
                    break
                fi
            done
        fi
        if [ ! -s "$stackvale_nvm_script" ]; then
            printf '%s\\n' \(shellQuote("[environment] nvm was not found. Install nvm to use Node \(version) required by \(requirement.source).")) >&2
            exit 127
        fi
        . "$stackvale_nvm_script" --no-use || exit $?
        printf '%s\\n' \(shellQuote("[environment] Selecting Node \(version) (\(requirement.source))"))
        nvm use --silent \(shellQuote(version)) || {
            printf '%s\\n' \(shellQuote("[environment] Could not select Node \(version). Install it with nvm before starting this service.")) >&2
            exit 1
        }
        \(command)
        """
        return LaunchCommand(executable: "/bin/zsh", arguments: ["-c", script])
    }

    private static func isNodeCommand(executable: String, arguments: [String]) -> Bool {
        let tools = ["node", "npm", "npx", "yarn", "pnpm"]
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if tools.contains(name) { return true }
        if name == "env", let tool = arguments.first {
            return tools.contains(URL(fileURLWithPath: tool).lastPathComponent)
        }
        guard ["zsh", "bash", "sh"].contains(name), let flag = arguments.first,
              flag.hasPrefix("-"), flag.contains("c"), arguments.count == 2 else { return false }
        let pattern = #"(?:^|&&|\|\||[;|(\n])\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*(?:exec\s+|env\s+)?(?:[^\s;&|]*/)?(?:node|npm|npx|yarn|pnpm)(?=\s|[;&|]|$)"#
        return arguments[1].range(of: pattern, options: .regularExpression) != nil
    }

    private static func findRequirement(in workingDirectory: URL) throws -> Requirement? {
        var directory = workingDirectory.standardizedFileURL
        while true {
            for name in [".nvmrc", ".node-version"] {
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let contents = try String(contentsOf: file, encoding: .utf8)
                let lines = contents.components(separatedBy: .newlines)
                    .map { $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains("=") }
                guard lines.count == 1, let version = lines.first, !version.hasPrefix("-"),
                      version.range(of: #"^[A-Za-z0-9.*_/+\-]+$"#, options: .regularExpression) != nil else {
                    throw PreparationError("Invalid Node version in \(file.path). Specify one Node version or nvm alias.")
                }
                return Requirement(version: version, source: file.path, isRange: false)
            }

            let packageURL = directory.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: packageURL.path) {
                let data = try Data(contentsOf: packageURL)
                let package = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let engines = package?["engines"] as? [String: Any], let node = engines["node"] as? String {
                    return Requirement(version: node, source: "\(packageURL.path) · engines.node", isRange: true)
                }
            }

            // Inherit a monorepo's configuration, but never cross its repository boundary.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return nil }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct PreparationError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

private struct NodeVersion: Comparable, CustomStringConvertible {
    var parts: [Int]
    var description: String { "v" + parts.map(String.init).joined(separator: ".") }

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }

    init(parts: [Int]) { self.parts = parts }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

/// The stable-version range syntax used by engines.node. Unsupported syntax fails explicitly.
private struct NodeVersionRange {
    private struct Bound {
        var operation: String
        var version: NodeVersion

        func contains(_ candidate: NodeVersion) -> Bool {
            switch operation {
            case ">=": return candidate >= version
            case ">": return candidate > version
            case "<=": return candidate <= version
            case "<": return candidate < version
            default: return candidate == version
            }
        }
    }
    private var alternatives: [[Bound]] = []

    init(_ expression: String) throws {
        for alternative in expression.components(separatedBy: "||") {
            let normalized = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"([<>]=?|[=~^])\s+"#, with: "$1", options: .regularExpression)
            let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count == 3, tokens[1] == "-" {
                alternatives.append(try Self.bounds(">=" + tokens[0]) + Self.bounds("<=" + tokens[2]))
            } else {
                alternatives.append(try tokens.flatMap(Self.bounds))
            }
        }
    }

    func contains(_ version: NodeVersion) -> Bool {
        alternatives.contains { $0.allSatisfy { $0.contains(version) } }
    }

    private static func bounds(_ token: String) throws -> [Bound] {
        var value = token
        var operation = "="
        for prefix in [">=", "<=", ">", "<", "=", "~", "^"] where value.hasPrefix(prefix) {
            operation = prefix
            value = String(value.dropFirst(prefix.count))
            break
        }
        if value.hasPrefix("v") { value = String(value.dropFirst()) }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var parts: [Int] = []
        var wildcard = false
        for piece in pieces {
            if ["x", "X", "*"].contains(piece) { wildcard = true; continue }
            guard !wildcard, !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece), number < Int.max else {
                throw unsupported(token)
            }
            parts.append(number)
        }
        guard pieces.count <= 3 else { throw unsupported(token) }
        let count = parts.count
        while parts.count < 3 { parts.append(0) }
        let lower = NodeVersion(parts: parts)
        func bound(_ operation: String, _ parts: [Int]) -> Bound {
            Bound(operation: operation, version: NodeVersion(parts: parts))
        }
        func next(_ index: Int) -> [Int] {
            var upper = parts
            upper[index] += 1
            for position in (index + 1)..<3 { upper[position] = 0 }
            return upper
        }
        if count == 0 {
            if [">", "<"].contains(operation) { return [bound("<", [0, 0, 0])] }
            return []
        }
        switch operation {
        case "~": return [bound(">=", parts), bound("<", next(count == 1 ? 0 : 1))]
        case "^":
            let index = parts.firstIndex(where: { $0 > 0 }) ?? (count - 1)
            return [bound(">=", parts), bound("<", next(min(index, count - 1)))]
        case ">": return count < 3 ? [bound(">=", next(count - 1))] : [Bound(operation: ">", version: lower)]
        case "<=": return count < 3 ? [bound("<", next(count - 1))] : [Bound(operation: "<=", version: lower)]
        case ">=", "<": return [Bound(operation: operation, version: lower)]
        default:
            return count < 3 ? [bound(">=", parts), bound("<", next(count - 1))] : [bound("=", parts)]
        }
    }

    private static func unsupported(_ token: String) -> NodeCommandEnvironment.PreparationError {
        .init("Unsupported engines.node range: \(token). Use a stable Node range or pin the required version in .nvmrc.")
    }
}
