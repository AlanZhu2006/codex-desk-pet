import Foundation
import SQLite3

/// Observes newly appended local desktop events. It never replays conversation history.
final class ActivityMonitor {
    static var defaultCodexHome: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private enum Eligibility { case unknown, accepted, rejected }

    private final class Cursor {
        let url: URL
        let threadID: String
        var identity: Identity
        var offset: UInt64
        var eligibility = Eligibility.unknown
        var buffer = Data()
        var droppingLongLine = false
        var lastOrdinal: Int64?

        init(url: URL, threadID: String, identity: Identity, offset: UInt64) {
            self.url = url
            self.threadID = threadID
            self.identity = identity
            self.offset = offset
        }
    }

    private struct Task: Hashable {
        let thread: String
        let turn: String
    }

    /// Projects small protocol fields while skipping strings/objects that can contain conversations.
    /// Skipped values are never decoded into Swift strings or retained as JSON objects.
    private struct EventProjection {
        private let bytes: [UInt8]
        private let metadata: Bool
        private var position = 0
        private let topKeys: Set<String> = ["type", "timestamp", "ordinal"]
        private let payloadKeys: Set<String> = ["type", "turn_id", "root_turn_id", "terminal", "fatal"]
        private let metadataKeys: Set<String> = ["originator", "id", "session_id", "agent_path", "parent_thread_id"]

        init(_ data: Data, metadata: Bool = false) {
            bytes = Array(data)
            self.metadata = metadata
        }

        mutating func read() -> [String: Any]? {
            guard let result = object(keys: metadata ? ["type"] : topKeys, includePayload: true) else { return nil }
            whitespace()
            return position == bytes.count ? result : nil
        }

        private mutating func whitespace() {
            while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private mutating func stringBounds() -> Range<Int>? {
            whitespace()
            guard position < bytes.count, bytes[position] == 34 else { return nil }
            let start = position
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 { return start..<position }
                if byte == 92 {
                    guard position < bytes.count else { return nil }
                    position += 1
                }
            }
            return nil
        }

        private mutating func smallString() -> String? {
            guard let bounds = stringBounds(), bounds.count <= 1024,
                  let value = try? JSONSerialization.jsonObject(with: Data(bytes[bounds]), options: [.fragmentsAllowed]) else { return nil }
            return value as? String
        }

        private mutating func scalar() -> Any? {
            whitespace()
            guard position < bytes.count else { return nil }
            if bytes[position] == 34 { return smallString() }
            let start = position
            while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
            guard position > start, position - start <= 32 else { return nil }
            let value = String(decoding: bytes[start..<position], as: UTF8.self)
            if value == "true" { return true }
            if value == "false" { return false }
            if value == "null" { return NSNull() }
            return Int64(value)
        }

        private mutating func object(keys: Set<String>, includePayload: Bool, metadataPayload: Bool = false) -> [String: Any]? {
            guard take(123) else { return nil }
            var result: [String: Any] = [:]
            if take(125) { return result }
            while true {
                guard let key = smallString(), take(58) else { return nil }
                if includePayload && key == "payload" {
                    guard let payload = object(keys: metadata ? metadataKeys : payloadKeys,
                                               includePayload: false, metadataPayload: metadata) else { return nil }
                    result[key] = payload
                } else if metadataPayload && key == "source" {
                    guard let subagent = sourceHasSubagent() else { return nil }
                    result["source_has_subagent"] = subagent
                } else if keys.contains(key) {
                    guard let value = scalar() else { return nil }
                    result[key] = value
                } else if !skipValue(depth: 0) { return nil }
                if take(125) { return result }
                guard take(44) else { return nil }
            }
        }

        /// A source string is skipped, and a source object contributes only subagent-key presence.
        /// Neither its nested agent information nor any unrelated metadata values are decoded.
        private mutating func sourceHasSubagent() -> Bool? {
            whitespace()
            guard position < bytes.count else { return nil }
            guard bytes[position] == 123 else {
                return skipValue(depth: 0) ? false : nil
            }
            position += 1
            var found = false
            if take(125) { return found }
            while true {
                guard let key = smallString(), take(58), skipValue(depth: 0) else { return nil }
                if key == "subagent" { found = true }
                if take(125) { return found }
                guard take(44) else { return nil }
            }
        }

        private mutating func skipValue(depth: Int) -> Bool {
            guard depth < 64 else { return false }
            whitespace()
            guard position < bytes.count else { return false }
            switch bytes[position] {
            case 34: return stringBounds() != nil
            case 123:
                position += 1
                if take(125) { return true }
                while true {
                    guard stringBounds() != nil, take(58), skipValue(depth: depth + 1) else { return false }
                    if take(125) { return true }
                    guard take(44) else { return false }
                }
            case 91:
                position += 1
                if take(93) { return true }
                while true {
                    guard skipValue(depth: depth + 1) else { return false }
                    if take(93) { return true }
                    guard take(44) else { return false }
                }
            default:
                let start = position
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                return position > start
            }
        }
    }

    private let codexHome: URL
    private let onUpdate: (String, String) -> Void
    private let queue = DispatchQueue(label: "ClaudeDesktopPet.ActivityMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cursors: [String: Cursor] = [:]
    private var active: [Task: Date] = [:]
    private var watchStartedAt = Date()
    private var lastDiscovery = Date.distantPast
    private var transientUntil: Date?
    private var output = (state: "idle", text: "等待 Codex 活动")
    private let maximumRead = 256 * 1024
    private let maximumLine = 2 * 1024 * 1024
    private let staleInterval: TimeInterval = 2 * 60 * 60
    private let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeDate = ISO8601DateFormatter()

    init(codexHome: URL = ActivityMonitor.defaultCodexHome, claudeHome: URL? = nil,
         onUpdate: @escaping (String, String) -> Void) {
        self.codexHome = codexHome.standardizedFileURL
        self.onUpdate = onUpdate
        // claudeHome is reserved for an optional legacy adapter. Codex events own this monitor.
        _ = claudeHome
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            self.watchStartedAt = Date()
            self.lastDiscovery = self.watchStartedAt
            self.active.removeAll()
            self.cursors.removeAll()
            self.transientUntil = nil
            self.discover(baseline: true)
            self.publish("idle", "等待 Codex 活动", force: true)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.tick(now: Date()) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            self.cursors.removeAll()
            self.active.removeAll()
            self.transientUntil = nil
        }
    }

    deinit { timer?.cancel() }

    private func publish(_ state: String, _ text: String, force: Bool = false) {
        guard force || output.state != state || output.text != text else { return }
        output = (state, text)
        let callback = onUpdate
        DispatchQueue.main.async { callback(state, text) }
    }

    private func tick(now: Date) {
        if now.timeIntervalSince(lastDiscovery) >= 10 {
            discover(baseline: false)
            lastDiscovery = now
        }
        for cursor in Array(cursors.values) { readAppends(cursor, now: now) }
        expire(now: now)
    }

    private func expire(now: Date) {
        let expired = active.filter { now.timeIntervalSince($0.value) >= staleInterval }.map(\.key)
        for task in expired { active.removeValue(forKey: task) }
        if !expired.isEmpty {
            transientUntil = nil
            if active.isEmpty { publish("idle", "等待 Codex 活动") }
            else { publish("tool", "Codex 正在工作…") }
        }
        if let deadline = transientUntil, now >= deadline {
            transientUntil = nil
            if active.isEmpty { publish("idle", "等待 Codex 活动") }
            else { publish("tool", "Codex 正在工作…") }
        }
    }

    private func attributes(_ url: URL) -> (Identity, UInt64)? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber,
              let device = values[.systemNumber] as? NSNumber else { return nil }
        return (Identity(device: device.uint64Value, inode: inode.uint64Value), size.uint64Value)
    }

    /// The index locates resumed chats whose rollout files can live in older date directories.
    /// SQLite is opened read-only; schema differences simply disable discovery until the next poll.
    private func indexedRollouts() -> [(String, URL)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: codexHome,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let databases: [(Int, URL)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }
        guard let database = databases.max(by: { $0.0 < $1.0 })?.1 else { return [] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if connection != nil { sqlite3_close(connection) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK else { return [] }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) { columns.insert(String(cString: value)) }
        }
        sqlite3_finalize(statement)
        statement = nil
        guard columns.contains("id"), columns.contains("rollout_path") else { return [] }
        var filters = ["rollout_path IS NOT NULL"]
        if columns.contains("originator") { filters.append("originator = 'codex_work_desktop'") }
        if columns.contains("agent_path") { filters.append("(agent_path IS NULL OR agent_path = '')") }
        let order = columns.contains("updated_at") ? "updated_at" : (columns.contains("created_at") ? "created_at" : "rowid")
        let sql = "SELECT id, rollout_path FROM threads WHERE \(filters.joined(separator: " AND ")) ORDER BY \(order) DESC LIMIT 32"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let sessionsPrefix = codexHome.appendingPathComponent("sessions", isDirectory: true).path + "/"
        var result: [(String, URL)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0), let rawPath = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: rawID)
            let url = URL(fileURLWithPath: String(cString: rawPath)).standardizedFileURL
            guard !id.isEmpty, url.path.hasPrefix(sessionsPrefix), url.pathExtension == "jsonl" else { continue }
            result.append((id, url))
        }
        return result
    }

    private func discover(baseline: Bool) {
        let rollouts = indexedRollouts()
        guard !rollouts.isEmpty else { return }
        let indexedPaths = Set(rollouts.map { $0.1.path })
        for (id, url) in rollouts {
            guard cursors[url.path] == nil, let (identity, size) = attributes(url) else { continue }
            // A newly resumed old chat can contain years of history. Inspect at most its latest read window.
            let offset = baseline ? size : (size > UInt64(maximumRead) ? size - UInt64(maximumRead) : 0)
            let cursor = Cursor(url: url, threadID: id, identity: identity, offset: offset)
            cursor.droppingLongLine = !baseline && offset > 0
            cursors[url.path] = cursor
            // At startup only record EOF. New files are inspected on the next bounded tail pass.
        }
        for (path, cursor) in cursors where !indexedPaths.contains(path) && !active.keys.contains(where: { $0.thread == cursor.threadID }) {
            cursors.removeValue(forKey: path)
        }
    }

    /// Read just the first JSONL record to verify the owner; retain no instructions or messages.
    private func verifyMetadata(_ cursor: Cursor) {
        guard let handle = try? FileHandle(forReadingFrom: cursor.url) else { return }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: maximumRead), !bytes.isEmpty else { return }
        guard let newline = bytes.firstIndex(of: 10) else {
            // A metadata line larger than the read bound is unsupported, never guessed to be a main chat.
            if bytes.count == maximumRead { cursor.eligibility = .rejected }
            return
        }
        var projection = EventProjection(Data(bytes[..<newline]), metadata: true)
        guard let object = projection.read(),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            cursor.eligibility = .rejected
            return
        }
        let agentPath = payload["agent_path"] as? String ?? ""
        let parent = payload["parent_thread_id"] as? String ?? ""
        let id = payload["id"] as? String ?? payload["session_id"] as? String
        guard payload["originator"] as? String == "codex_work_desktop", payload["source_has_subagent"] as? Bool != true,
              agentPath.isEmpty, parent.isEmpty, id == cursor.threadID else {
            cursor.eligibility = .rejected
            return
        }
        cursor.eligibility = .accepted
        if cursor.offset == 0 { cursor.offset = UInt64(newline + 1) }
    }

    private func forgetTasks(threadID: String) {
        let keys = active.keys.filter { $0.thread == threadID }
        for key in keys { active.removeValue(forKey: key) }
        if !keys.isEmpty {
            transientUntil = nil
            if active.isEmpty { publish("idle", "等待 Codex 活动") }
            else { publish("tool", "Codex 正在工作…") }
        }
    }

    private func readAppends(_ cursor: Cursor, now: Date) {
        guard let (identity, size) = attributes(cursor.url) else { return }
        if identity != cursor.identity || size < cursor.offset {
            cursor.identity = identity
            cursor.offset = size
            cursor.eligibility = .unknown
            cursor.buffer.removeAll(keepingCapacity: false)
            cursor.droppingLongLine = false
            cursor.lastOrdinal = nil
            forgetTasks(threadID: cursor.threadID)
            return
        }
        if cursor.eligibility == .unknown {
            verifyMetadata(cursor)
            // Metadata and incremental data each get their own poll, keeping total per-file I/O bounded.
            return
        }
        guard cursor.eligibility == .accepted, size > cursor.offset,
              let handle = try? FileHandle(forReadingFrom: cursor.url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            guard let chunk = try handle.read(upToCount: maximumRead), !chunk.isEmpty else { return }
            cursor.offset += UInt64(chunk.count)
            consume(chunk, cursor: cursor, now: now)
        } catch {
            // Temporary file access failures are not task failures.
        }
    }

    private func consume(_ chunk: Data, cursor: Cursor, now: Date) {
        var position = chunk.startIndex
        while position < chunk.endIndex {
            let end = chunk[position...].firstIndex(of: 10) ?? chunk.endIndex
            let hasNewline = end < chunk.endIndex
            if !cursor.droppingLongLine {
                if cursor.buffer.count + (end - position) > maximumLine {
                    cursor.buffer.removeAll(keepingCapacity: false)
                    cursor.droppingLongLine = true
                } else {
                    cursor.buffer.append(contentsOf: chunk[position..<end])
                }
            }
            if hasNewline {
                if !cursor.droppingLongLine { processLine(cursor.buffer, cursor: cursor, now: now) }
                cursor.buffer.removeAll(keepingCapacity: true)
                cursor.droppingLongLine = false
                position = end + 1
            } else {
                break
            }
        }
    }

    private func processLine(_ line: Data, cursor: Cursor, now: Date) {
        var projection = EventProjection(line)
        guard let object = projection.read(),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let kind = payload["type"] as? String,
              let stamp = object["timestamp"] as? String,
              let timestamp = fractionalDate.date(from: stamp) ?? wholeDate.date(from: stamp),
              timestamp >= watchStartedAt else { return }
        if let ordinal = object["ordinal"] as? NSNumber {
            let value = ordinal.int64Value
            if let previous = cursor.lastOrdinal, value <= previous { return }
            cursor.lastOrdinal = value
        }
        let turn = payload["turn_id"] as? String ?? payload["root_turn_id"] as? String
        let task = turn.flatMap { $0.isEmpty ? nil : Task(thread: cursor.threadID, turn: $0) }
        switch kind {
        case "task_started":
            guard let task = task else { return }
            // A main chat owns one current turn. If an earlier completion was
            // missed, a new start supersedes only that chat's orphaned turn;
            // work in other chats remains active. Do not publish an idle gap.
            for previous in active.keys.filter({ $0.thread == task.thread && $0 != task }) {
                active.removeValue(forKey: previous)
            }
            active[task] = now
            transientUntil = nil
            publish("tool", "Codex 正在工作…")
        case "task_complete":
            guard let task = task, active.removeValue(forKey: task) != nil else { return }
            if active.isEmpty {
                transientUntil = now.addingTimeInterval(4)
                publish("celebrate", "任务完成")
            }
        case "task_aborted", "turn_aborted":
            // Compatibility only: these termination variants were not observed in the sampled desktop logs.
            finishExceptional(task, state: "aborted", text: "任务已中断", now: now)
        case "error":
            // Generic errors can describe a retry. Only an explicit terminal marker qualifies.
            // These compatibility fields have not been observed in the sampled desktop logs.
            if payload["terminal"] as? Bool == true || payload["fatal"] as? Bool == true {
                finishExceptional(task, state: "crying", text: "任务遇到了错误", now: now)
            }
        default:
            // Keep a known task alive on protocol progress, without interpreting its contents.
            if let task = task, active[task] != nil { active[task] = now }
            else if task == nil && kind == "token_count" {
                // Anonymous usage progress belongs only to the chat's current
                // turn. A late event tagged with an old turn cannot renew it.
                let current = active.keys.filter { $0.thread == cursor.threadID }
                if current.count == 1, let task = current.first { active[task] = now }
            }
        }
    }

    private func finishExceptional(_ task: Task?, state: String, text: String, now: Date) {
        guard let task = task, active.removeValue(forKey: task) != nil else { return }
        if active.isEmpty {
            transientUntil = now.addingTimeInterval(4)
            publish(state, text)
        } else {
            // Another chat still owns live work; cancellation/failure must not make the whole desktop idle.
            transientUntil = nil
            publish("tool", "Codex 正在工作…")
        }
    }

    /// Exercises synthetic logs and a temporary read-only discovery database, never real user sessions.
    static func selfTest() throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-pet-monitor-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ActivityMonitor(codexHome: root) { _, _ in }
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.watchStartedAt = epoch
        monitor.lastDiscovery = epoch
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ type: String, _ payload: [String: Any], time: TimeInterval = 1) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: epoch.addingTimeInterval(time)), "payload": payload])
            bytes.append(10)
            return bytes
        }
        func event(_ kind: String, _ turn: String, time: TimeInterval = 1) throws -> Data {
            try line("event_msg", ["type": kind, "turn_id": turn], time: time)
        }
        func append(_ bytes: Data, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        }
        func makeFile(_ id: String, subagent: Bool = false) throws -> URL {
            let url = root.appendingPathComponent("sessions/\(id).jsonl")
            var metadata: [String: Any] = ["id": id, "originator": "codex_work_desktop", "source": "vscode"]
            if subagent { metadata["source"] = ["subagent": ["thread_spawn": ["depth": 1]]] }
            try line("session_meta", metadata, time: -10).write(to: url)
            return url
        }
        var privacyProjection = EventProjection(Data(#"{"payload":{"last_agent_message":"synthetic private text","type":"task_complete","turn_id":"privacy-test","item":{"arguments":"synthetic arguments"}},"type":"event_msg","timestamp":"2027-01-15T08:00:00.000Z","ordinal":17}"#.utf8))
        let projected = privacyProjection.read()
        let projectedPayload = projected?["payload"] as? [String: Any]
        try check(projectedPayload?.count == 2 && projectedPayload?["last_agent_message"] == nil && projectedPayload?["item"] == nil,
                  "Projection retained conversation or tool fields")
        try check((projected?["ordinal"] as? NSNumber)?.int64Value == 17, "Ordinal projection failed")
        let metadataFixture = Data(#"{"type":"session_meta","timestamp":"2027-01-15T08:00:00Z","payload":{"id":"meta-test","session_id":"meta-test","originator":"codex_work_desktop","agent_path":null,"parent_thread_id":null,"source":{"subagent":{"thread_spawn":{"parent_thread_id":"not-retained","agent_path":"not-retained"}},"unrelated":"not-retained"},"base_instructions":{"text":"synthetic private instructions"},"cwd":"synthetic-private-path","runtime_workspace_roots":["synthetic-private-root"],"creator_user_id":"synthetic-private-user","creator_account_id":"synthetic-private-account"}}"#.utf8)
        var metadataProjection = EventProjection(metadataFixture, metadata: true)
        let metadataResult = metadataProjection.read()
        let metadataPayload = metadataResult?["payload"] as? [String: Any]
        let allowedMetadata: Set<String> = ["id", "session_id", "originator", "agent_path", "parent_thread_id", "source_has_subagent"]
        try check(metadataResult?.count == 2 && Set(metadataPayload?.keys.map { $0 } ?? []) == allowedMetadata,
                  "Metadata projection retained instructions, paths, creator IDs, or nested source values")
        try check(metadataPayload?["source_has_subagent"] as? Bool == true, "Metadata lost subagent-key presence")
        var stringSourceProjection = EventProjection(Data(#"{"type":"session_meta","payload":{"id":"main","originator":"codex_work_desktop","source":"vscode","base_instructions":"synthetic private instructions"}}"#.utf8), metadata: true)
        let stringSourcePayload = stringSourceProjection.read()?["payload"] as? [String: Any]
        try check(stringSourcePayload?["source_has_subagent"] as? Bool == false && stringSourcePayload?["source"] == nil,
                  "String metadata source was rejected or decoded into retained output")
        let a = try makeFile("a")
        let b = try makeFile("b")
        try append(event("task_started", "old", time: -1), to: a)
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK, let db = database else {
            throw Failure(description: "Could not create synthetic index")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT, updated_at INTEGER, originator TEXT, agent_path TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw Failure(description: "Could not create synthetic schema")
        }
        func index(_ id: String, _ url: URL) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, ?, 1, 'codex_work_desktop', NULL)", -1, &statement, nil) == SQLITE_OK else {
                throw Failure(description: "Could not prepare synthetic row")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            _ = url.path.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(description: "Could not write synthetic row") }
        }
        try index("a", a)
        try index("b", b)
        monitor.discover(baseline: true)
        monitor.tick(now: epoch)
        try check(monitor.active.isEmpty, "Startup replayed old work")
        let partial = try event("task_started", "a1")
        try append(Data(partial.dropLast(3)), to: a)
        monitor.tick(now: epoch.addingTimeInterval(1))
        try check(monitor.active.isEmpty, "Processed an incomplete JSONL line")
        try append(Data(partial.suffix(3)), to: a)
        try append(event("task_started", "b1"), to: b)
        monitor.tick(now: epoch.addingTimeInterval(1))
        try check(monitor.active.count == 2 && monitor.output.state == "tool", "Concurrent tasks were not tracked")
        try append(event("task_complete", "a1", time: 2), to: a)
        monitor.tick(now: epoch.addingTimeInterval(2))
        try check(monitor.active.count == 1 && monitor.output.state == "tool", "One completion hid another live task")
        try append(event("task_complete", "b1", time: 3), to: b)
        monitor.tick(now: epoch.addingTimeInterval(3))
        try check(monitor.output.state == "celebrate", "Final task did not celebrate")
        monitor.expire(now: epoch.addingTimeInterval(7.1))
        try check(monitor.output.state == "idle", "Celebration did not expire")

        let c = try makeFile("c")
        try append(event("task_started", "copied", time: -1), to: c)
        try append(event("task_complete", "copied", time: -0.5), to: c)
        try index("c", c)
        monitor.discover(baseline: false)
        monitor.tick(now: epoch.addingTimeInterval(8))
        monitor.tick(now: epoch.addingTimeInterval(8))
        try check(monitor.active.isEmpty && monitor.output.state == "idle", "New file replayed copied history")
        let child = try makeFile("child", subagent: true)
        try append(event("task_started", "child-turn", time: 8), to: child)
        try index("child", child)
        monitor.discover(baseline: false)
        monitor.tick(now: epoch.addingTimeInterval(8))
        monitor.tick(now: epoch.addingTimeInterval(8))
        try check(monitor.active.isEmpty, "A subagent was counted as a desktop chat")

        try append(event("task_started", "failure", time: 9), to: a)
        try append(line("event_msg", ["type": "item_completed", "turn_id": "failure", "item": ["type": "CommandExecution", "status": "failed", "exit_code": 1]], time: 9), to: a)
        try append(event("error", "unrelated", time: 9), to: a)
        monitor.tick(now: epoch.addingTimeInterval(9))
        try check(monitor.output.state == "tool" && monitor.active.count == 1, "A tool failure or unrelated error ended the task")
        try append(event("error", "failure", time: 10), to: a)
        monitor.tick(now: epoch.addingTimeInterval(10))
        try check(monitor.output.state == "tool" && monitor.active.count == 1, "A retryable error ended live work")
        try append(line("event_msg", ["type": "error", "turn_id": "failure", "terminal": true], time: 10), to: a)
        monitor.tick(now: epoch.addingTimeInterval(10))
        try check(monitor.output.state == "crying" && monitor.active.isEmpty, "Associated error was not distinguished")
        for (index, kind) in ["turn_aborted", "task_aborted"].enumerated() {
            let turn = "abort-\(index)"
            try append(event("task_started", turn, time: 11), to: a)
            try append(event(kind, turn, time: 11), to: a)
            monitor.tick(now: epoch.addingTimeInterval(11))
            try check(monitor.output.state == "aborted" && monitor.active.isEmpty, "Cancellation was treated as failure")
        }
        try append(event("task_started", "stale", time: 12), to: a)
        monitor.tick(now: epoch.addingTimeInterval(12))
        monitor.expire(now: epoch.addingTimeInterval(12 + 7201))
        try check(monitor.active.isEmpty && monitor.output.state == "idle", "Stale tasks did not return to neutral idle")

        try append(event("task_started", "rotating", time: 13), to: a)
        monitor.tick(now: epoch.addingTimeInterval(13))
        try Data().write(to: a)
        monitor.tick(now: epoch.addingTimeInterval(14))
        try check(monitor.active.isEmpty && monitor.output.state == "idle", "Truncation left stale live work")
        let freshA = try makeFile("a")
        try append(event("task_started", "after-truncate", time: 15), to: freshA)
        monitor.tick(now: epoch.addingTimeInterval(15))
        monitor.tick(now: epoch.addingTimeInterval(15))
        try check(monitor.active.count == 1, "Monitoring did not recover after truncation")
        try append(event("task_complete", "after-truncate", time: 16), to: a)
        monitor.tick(now: epoch.addingTimeInterval(16))
        monitor.expire(now: epoch.addingTimeInterval(21))

        var oversized = Data(repeating: 120, count: monitor.maximumLine + 1)
        oversized.append(10)
        oversized.append(try event("task_started", "after-long-line", time: 22))
        try append(oversized, to: b)
        for _ in 0..<12 { monitor.tick(now: epoch.addingTimeInterval(22)) }
        try check(monitor.active.count == 1 && monitor.output.state == "tool", "Oversized-line recovery failed")
        try check(monitor.cursors.values.allSatisfy { $0.buffer.count <= monitor.maximumLine }, "A line exceeded the memory bound")

        let replacement = root.appendingPathComponent("replacement.jsonl")
        try line("session_meta", ["id": "b", "originator": "codex_work_desktop", "source": "vscode"], time: -10).write(to: replacement)
        try append(event("task_started", "rotated-history", time: 23), to: replacement)
        try FileManager.default.removeItem(at: b)
        try FileManager.default.moveItem(at: replacement, to: b)
        monitor.tick(now: epoch.addingTimeInterval(23))
        monitor.tick(now: epoch.addingTimeInterval(23))
        try check(monitor.active.isEmpty && monitor.output.state == "idle", "Rotation replayed history or retained old tasks")
        try append(event("task_started", "after-rotation", time: 24), to: b)
        monitor.tick(now: epoch.addingTimeInterval(24))
        try check(monitor.active.count == 1, "Monitoring did not recover after rotation")

        // A dropped completion must not let an obsolete turn survive every
        // later turn in that chat. Its late progress and termination events
        // must also leave the replacement and other chats untouched.
        let superseding = ActivityMonitor(codexHome: root) { _, _ in }
        superseding.watchStartedAt = epoch
        let sameCursor = Cursor(url: a, threadID: "same-chat", identity: Identity(device: 0, inode: 0), offset: 0)
        let otherCursor = Cursor(url: b, threadID: "other-chat", identity: Identity(device: 0, inode: 0), offset: 0)
        superseding.processLine(try event("task_started", "old-turn", time: 1), cursor: sameCursor, now: epoch.addingTimeInterval(1))
        superseding.processLine(try event("task_started", "other-turn", time: 1), cursor: otherCursor, now: epoch.addingTimeInterval(1))
        superseding.processLine(try event("task_started", "new-turn", time: 2), cursor: sameCursor, now: epoch.addingTimeInterval(2))
        let oldTask = Task(thread: "same-chat", turn: "old-turn")
        let newTask = Task(thread: "same-chat", turn: "new-turn")
        let otherTask = Task(thread: "other-chat", turn: "other-turn")
        try check(superseding.active.count == 2 && superseding.active[oldTask] == nil
                  && superseding.active[newTask] != nil && superseding.active[otherTask] != nil
                  && superseding.output.state == "tool", "New turn failed to supersede only its own chat's obsolete turn")
        for kind in ["task_complete", "task_aborted", "turn_aborted"] {
            superseding.processLine(try event(kind, "old-turn", time: 3), cursor: sameCursor, now: epoch.addingTimeInterval(3))
        }
        superseding.processLine(try line("event_msg", ["type": "error", "turn_id": "old-turn", "terminal": true], time: 4),
                                cursor: sameCursor, now: epoch.addingTimeInterval(4))
        try check(superseding.active.count == 2 && superseding.active[newTask] != nil && superseding.output.state == "tool",
                  "A late old-turn termination removed the replacement turn")
        superseding.processLine(try event("token_count", "old-turn", time: 5), cursor: sameCursor, now: epoch.addingTimeInterval(5))
        try check(superseding.active[newTask] == epoch.addingTimeInterval(2), "Old tagged progress renewed the replacement turn")
        superseding.processLine(try line("event_msg", ["type": "token_count"], time: 6), cursor: sameCursor, now: epoch.addingTimeInterval(6))
        try check(superseding.active[newTask] == epoch.addingTimeInterval(6)
                  && superseding.active[otherTask] == epoch.addingTimeInterval(1),
                  "Anonymous progress failed to refresh only the current turn in its own chat")
        superseding.processLine(try event("task_complete", "new-turn", time: 7), cursor: sameCursor, now: epoch.addingTimeInterval(7))
        try check(superseding.active.count == 1 && superseding.active[otherTask] != nil && superseding.output.state == "tool",
                  "Replacement completion hid another chat's live work")
        superseding.processLine(try event("task_complete", "other-turn", time: 8), cursor: otherCursor, now: epoch.addingTimeInterval(8))
        superseding.expire(now: epoch.addingTimeInterval(12.1))
        try check(superseding.active.isEmpty && superseding.output.state == "idle", "Superseded orphan prevented a final return to idle")
    }
}
