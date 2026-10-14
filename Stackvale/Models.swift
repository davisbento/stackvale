import Foundation
import SwiftUI

// MARK: - Models

struct Project: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    var services: [ServiceDefinition]

    var rootURL: URL { URL(fileURLWithPath: rootPath) }
}

struct ServiceDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var projectId: UUID
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

    var workingDirectoryURL: URL { URL(fileURLWithPath: workingDirectory) }

    var displayIconCategory: IconCategory {
        if kind == .localCommand, localCommandLooksDockerBacked {
            return .docker
        }

        return iconCategory
    }

    var identityText: String {
        if let displayPort {
            return ":\(displayPort)"
        }

        switch kind {
        case .localCommand:
            switch displayIconCategory {
            case .docker:
                return "Docker"
            case .nodejs:
                return "Node.js"
            default:
                return "Command"
            }
        case .dockerCompose:
            return "Docker"
        }
    }

    var resolvedCommand: String {
        switch kind {
        case .localCommand:
            return commandDisplay
        case .dockerCompose:
            guard let composeFile, let composeService else { return "docker compose" }
            return "docker compose -f \"\(composeFile)\" up -d \(composeService)"
        }
    }

    private var localCommandLooksDockerBacked: Bool {
        let haystack = "\(name) \(commandDisplay) \(commandArguments.joined(separator: " "))".lowercased()
        return haystack.contains("docker compose")
            || haystack.contains("docker-compose")
            || haystack.contains("docker:up")
            || haystack.contains("docker:start")
    }
}

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case localCommand
    case dockerCompose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localCommand: "Command"
        case .dockerCompose: "Docker Compose"
        }
    }
}

enum ServiceSource: String, Codable, CaseIterable, Identifiable {
    case discovered
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .discovered: "Discovered"
        case .manual: "Manual"
        }
    }
}

enum IconCategory: String, Codable, CaseIterable, Identifiable {
    case web
    case docker
    case nodejs
    case generic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .web: "Web"
        case .docker: "Docker"
        case .nodejs: "Node.js"
        case .generic: "Generic"
        }
    }

    var symbolName: String {
        switch self {
        case .web: "globe"
        case .docker: "shippingbox"
        case .nodejs: "chevron.left.forwardslash.chevron.right"
        case .generic: "terminal"
        }
    }
}

enum RuntimeStatus: String, CaseIterable {
    case stopped
    case starting
    case running
    case stopping
    case failed
    case external
    case unknown

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .failed: "Failed"
        case .external: "External"
        case .unknown: "Unknown"
        }
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }

    var statusSymbol: String {
        switch self {
        case .running: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .starting, .stopping: "clock.fill"
        case .external: "link.circle.fill"
        case .unknown: "questionmark.circle"
        case .stopped: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .external: .blue
        case .unknown: .secondary
        case .stopped: .secondary
        }
    }
}

struct ServiceRuntime {
    var serviceId: UUID
    var status: RuntimeStatus
    var pidOrContainerId: String?
    var lastExitCode: Int?
    var lastError: String?
    var log: String

    static func stopped(serviceId: UUID) -> ServiceRuntime {
        ServiceRuntime(serviceId: serviceId, status: .stopped, log: "")
    }
}
