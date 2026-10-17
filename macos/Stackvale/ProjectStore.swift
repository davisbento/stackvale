import Foundation
import SQLite3
import SwiftUI

// MARK: - Persistence

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedProjectID: UUID?

    private let database: StackvaleDatabase?
    private let legacyJSONURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport.appendingPathComponent("Stackvale", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("stackvale.sqlite3")
        legacyJSONURL = directory.appendingPathComponent("projects.json")

        var openedDatabase: StackvaleDatabase?

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            openedDatabase = try StackvaleDatabase(url: databaseURL)
            try openedDatabase?.bootstrap()
            try Self.migrateLegacyJSONIfNeeded(using: openedDatabase, legacyJSONURL: legacyJSONURL)

            if let snapshot = try openedDatabase?.load() {
                projects = snapshot.projects
                selectedProjectID = snapshot.selectedProjectID
            }
        } catch {
            NSLog("Stackvale failed to open SQLite store: \(error.localizedDescription)")
            projects = []
            selectedProjectID = nil
        }

        database = openedDatabase

        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
    }

    var selectedProject: Project? {
        guard let selectedProjectID else { return projects.first }
        return projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    func save() {
        guard let database else { return }

        do {
            try database.save(PersistedProjects(selectedProjectID: selectedProjectID, projects: projects))
        } catch {
            NSLog("Stackvale failed to save SQLite store: \(error.localizedDescription)")
        }
    }

    func addProject(_ project: Project) {
        projects.append(project)
        selectedProjectID = project.id
        save()
    }

    func renameProject(_ projectID: UUID, name: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func removeProject(_ projectID: UUID) {
        projects.removeAll { $0.id == projectID }
        if selectedProjectID == projectID {
            selectedProjectID = projects.first?.id
        }
        save()
    }

    func addService(_ service: ServiceDefinition, to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].services.append(service)
        save()
    }

    func addServices(_ services: [ServiceDefinition], to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].services.append(contentsOf: services)
        save()
    }

    func updateService(_ service: ServiceDefinition) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == service.projectId }),
              let serviceIndex = projects[projectIndex].services.firstIndex(where: { $0.id == service.id }) else { return }
        projects[projectIndex].services[serviceIndex] = service
        save()
    }

    func removeService(_ serviceID: UUID, from projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[projectIndex].services.removeAll { $0.id == serviceID }
        save()
    }

    func serviceNameExists(_ name: String, in projectID: UUID, excluding serviceID: UUID? = nil) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        return project.services.contains {
            $0.id != serviceID && $0.name.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    private static func migrateLegacyJSONIfNeeded(using database: StackvaleDatabase?, legacyJSONURL: URL) throws {
        guard let database,
              database.isEmpty,
              FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }

        let data = try Data(contentsOf: legacyJSONURL)
        let snapshot = try JSONDecoder.stackvale.decode(PersistedProjects.self, from: data)
        try database.save(snapshot)
    }
}

private struct PersistedProjects: Codable {
    var selectedProjectID: UUID?
    var projects: [Project]
}

// MARK: - SQLite database

private final class StackvaleDatabase {
    private let db: OpaquePointer?

    var isEmpty: Bool {
        (try? countRows(in: "projects")) == 0
    }

    init(url: URL) throws {
        var openedDatabase: OpaquePointer?
        guard sqlite3_open(url.path, &openedDatabase) == SQLITE_OK else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database."
            sqlite3_close(openedDatabase)
            throw SQLiteStoreError.openFailed(message)
        }
        db = openedDatabase
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(db)
    }

    func bootstrap() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS app_preferences (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            root_path TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS services (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            working_directory TEXT NOT NULL,
            source TEXT NOT NULL,
            command_executable TEXT,
            command_arguments_json TEXT NOT NULL,
            command_display TEXT NOT NULL,
            compose_file TEXT,
            compose_service TEXT,
            display_port INTEGER,
            icon_category TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE CASCADE
        );
        """)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_services_project_sort
        ON services(project_id, sort_order);
        """)
    }

    func load() throws -> PersistedProjects {
        let selectedProjectID = try loadSelectedProjectID()
        let servicesByProjectID = try loadServicesByProjectID()

        let rows = try query(
            "SELECT id, name, root_path, created_at FROM projects ORDER BY created_at ASC;"
        )

        let projects = rows.compactMap { row -> Project? in
            guard let idValue = row["id"],
                  let id = UUID(uuidString: idValue),
                  let name = row["name"],
                  let rootPath = row["root_path"],
                  let createdAtRaw = row["created_at"],
                  let createdAtSeconds = TimeInterval(createdAtRaw) else { return nil }

            return Project(
                id: id,
                name: name,
                rootPath: rootPath,
                createdAt: Date(timeIntervalSince1970: createdAtSeconds),
                services: servicesByProjectID[id] ?? []
            )
        }

        return PersistedProjects(selectedProjectID: selectedProjectID, projects: projects)
    }

    func save(_ snapshot: PersistedProjects) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try execute("DELETE FROM services;")
            try execute("DELETE FROM projects;")
            try execute("DELETE FROM app_preferences WHERE key = 'selectedProjectID';")

            if let selectedProjectID = snapshot.selectedProjectID {
                try execute(
                    "INSERT INTO app_preferences (key, value) VALUES (?, ?);",
                    [.text("selectedProjectID"), .text(selectedProjectID.uuidString)]
                )
            }

            for project in snapshot.projects {
                try execute(
                    """
                    INSERT INTO projects (id, name, root_path, created_at)
                    VALUES (?, ?, ?, ?);
                    """,
                    [
                        .text(project.id.uuidString),
                        .text(project.name),
                        .text(project.rootPath),
                        .double(project.createdAt.timeIntervalSince1970)
                    ]
                )

                for (index, service) in project.services.enumerated() {
                    let argumentsData = try JSONEncoder.stackvale.encode(service.commandArguments)
                    let argumentsJSON = String(data: argumentsData, encoding: .utf8) ?? "[]"

                    try execute(
                        """
                        INSERT INTO services (
                            id,
                            project_id,
                            name,
                            kind,
                            working_directory,
                            source,
                            command_executable,
                            command_arguments_json,
                            command_display,
                            compose_file,
                            compose_service,
                            display_port,
                            icon_category,
                            sort_order
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(service.id.uuidString),
                            .text(service.projectId.uuidString),
                            .text(service.name),
                            .text(service.kind.rawValue),
                            .text(service.workingDirectory),
                            .text(service.source.rawValue),
                            service.commandExecutable.map(SQLiteValue.text) ?? .null,
                            .text(argumentsJSON),
                            .text(service.commandDisplay),
                            service.composeFile.map(SQLiteValue.text) ?? .null,
                            service.composeService.map(SQLiteValue.text) ?? .null,
                            service.displayPort.map(SQLiteValue.integer) ?? .null,
                            .text(service.iconCategory.rawValue),
                            .integer(index)
                        ]
                    )
                }
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func loadSelectedProjectID() throws -> UUID? {
        let rows = try query(
            "SELECT value FROM app_preferences WHERE key = 'selectedProjectID' LIMIT 1;"
        )
        guard let value = rows.first?["value"] else { return nil }
        return UUID(uuidString: value)
    }

    private func loadServicesByProjectID() throws -> [UUID: [ServiceDefinition]] {
        let rows = try query(
            """
            SELECT
                id,
                project_id,
                name,
                kind,
                working_directory,
                source,
                command_executable,
                command_arguments_json,
                command_display,
                compose_file,
                compose_service,
                display_port,
                icon_category
            FROM services
            ORDER BY project_id ASC, sort_order ASC;
            """
        )

        var servicesByProjectID: [UUID: [ServiceDefinition]] = [:]

        for row in rows {
            guard let idRaw = row["id"],
                  let id = UUID(uuidString: idRaw),
                  let projectIDRaw = row["project_id"],
                  let projectID = UUID(uuidString: projectIDRaw),
                  let name = row["name"],
                  let kindRaw = row["kind"],
                  let kind = ServiceKind(rawValue: kindRaw),
                  let workingDirectory = row["working_directory"],
                  let sourceRaw = row["source"],
                  let source = ServiceSource(rawValue: sourceRaw),
                  let commandArgumentsJSON = row["command_arguments_json"],
                  let commandArgumentsData = commandArgumentsJSON.data(using: .utf8),
                  let commandArguments = try? JSONDecoder.stackvale.decode([String].self, from: commandArgumentsData),
                  let commandDisplay = row["command_display"],
                  let iconCategoryRaw = row["icon_category"],
                  let iconCategory = IconCategory(rawValue: iconCategoryRaw) else { continue }

            let displayPort = row["display_port"].flatMap(Int.init)
            let service = ServiceDefinition(
                id: id,
                projectId: projectID,
                name: name,
                kind: kind,
                workingDirectory: workingDirectory,
                source: source,
                commandExecutable: row["command_executable"],
                commandArguments: commandArguments,
                commandDisplay: commandDisplay,
                composeFile: row["compose_file"],
                composeService: row["compose_service"],
                displayPort: displayPort,
                iconCategory: iconCategory
            )

            servicesByProjectID[projectID, default: []].append(service)
        }

        return servicesByProjectID
    }

    private func countRows(in table: String) throws -> Int {
        let rows = try query("SELECT COUNT(*) AS count FROM \(table);")
        return rows.first?["count"].flatMap(Int.init) ?? 0
    }

    private func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executeFailed(lastErrorMessage)
        }
    }

    private func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        var rows: [[String: String]] = []

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteStoreError.queryFailed(lastErrorMessage)
            }

            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                if sqlite3_column_type(statement, index) != SQLITE_NULL,
                   let text = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: text)
                }
            }
            rows.append(row)
        }

        return rows
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32

            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .text(let text):
                result = sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(integer))
            case .double(let double):
                result = sqlite3_bind_double(statement, position, double)
            }

            guard result == SQLITE_OK else {
                throw SQLiteStoreError.bindFailed(lastErrorMessage)
            }
        }
    }

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
    }
}

private enum SQLiteValue {
    case null
    case text(String)
    case integer(Int)
    case double(Double)
}

private extension SQLiteValue {
    init(_ value: String?) {
        if let value {
            self = .text(value)
        } else {
            self = .null
        }
    }

    init(_ value: String) {
        self = .text(value)
    }

    init(_ value: Int?) {
        if let value {
            self = .integer(value)
        } else {
            self = .null
        }
    }

    init(_ value: Int) {
        self = .integer(value)
    }

    init(_ value: Double) {
        self = .double(value)
    }
}

private enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case executeFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open SQLite store: \(message)"
        case .prepareFailed(let message): "Could not prepare SQLite statement: \(message)"
        case .bindFailed(let message): "Could not bind SQLite values: \(message)"
        case .executeFailed(let message): "Could not execute SQLite statement: \(message)"
        case .queryFailed(let message): "Could not query SQLite store: \(message)"
        }
    }
}

private extension JSONEncoder {
    static var stackvale: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var stackvale: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
