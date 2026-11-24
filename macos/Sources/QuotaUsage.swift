import CoreFoundation
import Darwin
import Foundation

struct QuotaSnapshot {
    let providers: [QuotaProvider]
    let fetchedAt: Date
}

struct QuotaProvider {
    let id: String
    let name: String
    let accountNumber: Int?
    let plan: String?
    let windows: [QuotaWindow]
    let details: [String]
    let unavailable: Bool
}

struct QuotaWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?
}

enum QuotaFetchResult {
    case success(QuotaSnapshot)
    case missingDependency
    case failure
}

struct QuotaService {
    let id: String
    let name: String
    let enabled: Bool
}

enum QuotaServicesResult {
    case success([QuotaService])
    case missingDependency
    case failure
}

enum QuotaUsage {
    private static let timeout: TimeInterval = 25
    private static let refreshTimeout: TimeInterval = 35
    private static let configTimeout: TimeInterval = 10
    private static let outputLimit = 2 * 1024 * 1024

    // Call off the main thread. CodexBar owns account configuration and authentication.
    static func fetch() -> QuotaFetchResult {
        guard let command = codexBarCommand() else { return .missingDependency }
        let deadline = ProcessInfo.processInfo.systemUptime + refreshTimeout
        let arguments = ["usage", "--format", "json", "--json-only", "--web-timeout", "15"]
        guard let (data, exitStatus) = capture(executable: command.executable, arguments: arguments,
                                              environment: command.environment),
              let rows = usageRows(from: data) else { return .failure }
        let baseline = decode(rows, exitStatus: exitStatus)
        guard case let .success(snapshot) = baseline,
              rows.contains(where: isAntigravityAccount) else { return baseline }

        // A tagged baseline row means CodexBar selected a saved account. Scope
        // the follow-up to Antigravity and let CodexBar select its configured source.
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let scoped = remaining > 0 ? capture(
            executable: command.executable,
            arguments: arguments + ["--provider", "antigravity", "--all-accounts"],
            environment: command.environment,
            deadlineAfter: remaining
        ) : nil
        // CodexBar can return a nonzero status alongside usable account rows.
        return .success(expandingAntigravity(in: snapshot, with: scoped?.0))
    }

    static func services() -> QuotaServicesResult {
        guard let command = codexBarCommand() else { return .missingDependency }
        return services(using: command)
    }

    static func setService(_ id: String, enabled: Bool) -> QuotaServicesResult {
        guard isServiceID(id) else { return .failure }
        guard let command = codexBarCommand() else { return .missingDependency }
        let arguments = ["config", enabled ? "enable" : "disable", "--provider", id]
        guard let (_, exitStatus) = capture(executable: command.executable, arguments: arguments,
                                           environment: command.environment, deadlineAfter: configTimeout),
              exitStatus == 0 else { return .failure }
        let result = services(using: command)
        guard case let .success(services) = result,
              services.first(where: { $0.id == id })?.enabled == enabled else { return .failure }
        return result
    }

    private struct Command {
        let executable: String
        let environment: [String: String]
    }

    private static func codexBarCommand() -> Command? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let standardBins = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                            home.appendingPathComponent("bin").path, "/usr/bin", "/bin"]
        let inheritedBins = (environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let bins = standardBins + inheritedBins.filter { !standardBins.contains($0) }
        let helper = "CodexBar.app/Contents/Helpers/CodexBarCLI"
        let candidates = ["/Applications/" + helper, home.appendingPathComponent("Applications/" + helper).path]
            + bins.map { $0 + "/codexbar" }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        environment["PATH"] = bins.joined(separator: ":")
        environment.removeValue(forKey: "CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT")
        return Command(executable: executable, environment: environment)
    }

    private static func services(using command: Command) -> QuotaServicesResult {
        struct Entry: Decodable {
            let provider: String
            let displayName: String
            let enabled: Bool
        }
        let arguments = ["config", "providers", "--format", "json", "--json-only"]
        guard let (data, exitStatus) = capture(executable: command.executable, arguments: arguments,
                                              environment: command.environment, deadlineAfter: configTimeout),
              exitStatus == 0,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return .failure }
        var seen = Set<String>()
        let services = entries.compactMap { entry -> QuotaService? in
            guard isServiceID(entry.provider), seen.insert(entry.provider).inserted else { return nil }
            return QuotaService(id: entry.provider, name: cleanText(entry.displayName) ?? entry.provider,
                                enabled: entry.enabled)
        }
        return .success(services)
    }

    private static func isServiceID(_ id: String) -> Bool {
        id.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
    }

    // Poll the pipe with a monotonic deadline. A provider subprocess inheriting
    // stdout must never keep an unbounded read or wait alive after the deadline.
    private static func capture(executable: String, arguments: [String],
                                environment: [String: String], deadlineAfter: TimeInterval = timeout) -> (Data, Int32)? {
        let pipe = Pipe()
        let input = pipe.fileHandleForReading
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        defer { try? input.close() }
        let fd = input.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + deadlineAfter
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let ownGroup = getpgid(pid) == pid
        var completed = false
        defer {
            if !completed && (ownGroup || process.isRunning) {
                // Only signal a group when this exact process led it. Never
                // signal the desk pet's inherited process group.
                _ = kill(ownGroup ? -pid : pid, SIGKILL)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0, data.count <= outputLimit - count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard finished.wait(timeout: .now() + remaining) == .success else { return nil }
        completed = true
        return (data, process.terminationStatus)
    }

    private static func usageRows(from data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func isAntigravityAccount(_ row: [String: Any]) -> Bool {
        // Check only for the presence of the account tag. Its value may be an email.
        row["provider"] as? String == "antigravity"
            && (row["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func expandingAntigravity(in snapshot: QuotaSnapshot, with data: Data?) -> QuotaSnapshot {
        guard let index = snapshot.providers.firstIndex(where: { $0.id == "antigravity" }) else { return snapshot }
        let accountRows = data.flatMap(usageRows(from:))?.filter(isAntigravityAccount) ?? []
        var providers = snapshot.providers
        if accountRows.isEmpty {
            let current = providers[index]
            providers[index] = QuotaProvider(
                id: current.id, name: current.name, accountNumber: nil, plan: current.plan,
                windows: current.windows, details: current.details + ["暂未读取到多账号额度，正在显示当前账号。"],
                unavailable: current.unavailable)
        } else if accountRows.count > 1 {
            let accounts = accountRows.enumerated().compactMap { offset, row in
                makeProvider(row, accountNumber: offset + 1)
            }
            providers.replaceSubrange(index...index, with: accounts)
        } else {
            return snapshot
        }
        return QuotaSnapshot(providers: providers, fetchedAt: snapshot.fetchedAt)
    }

    // Project only display fields. The response can also contain account
    // identities and provider error diagnostics, which the pet does not display.
    private static func decode(_ rows: [[String: Any]], exitStatus: Int32, now: Date = Date()) -> QuotaFetchResult {
        if rows.isEmpty { return exitStatus == 0 ? .success(QuotaSnapshot(providers: [], fetchedAt: now)) : .failure }
        let providers = rows.compactMap { makeProvider($0) }
        guard !providers.isEmpty else { return .failure }
        // A provider error gives the whole CLI invocation a nonzero exit code,
        // but its successful sibling rows still carry valid quota data.
        return .success(QuotaSnapshot(providers: providers, fetchedAt: now))
    }

    private static let providerNames = [
        "codex": "Codex", "claude": "Claude", "openai": "OpenAI API", "gemini": "Gemini", "cursor": "Cursor",
        "copilot": "GitHub Copilot", "kimi": "Kimi", "grok": "Grok", "antigravity": "Antigravity",
        "openrouter": "OpenRouter", "opencode": "OpenCode", "opencodego": "OpenCode Go", "minimax": "MiniMax",
        "deepseek": "DeepSeek", "perplexity": "Perplexity", "ollama": "Ollama", "windsurf": "Windsurf",
        "qwencloud": "Qwen Cloud", "zai": "z.ai", "jetbrains": "JetBrains AI", "alibabacodingplan": "Alibaba Coding Plan",
        "alibabatokenplan": "Alibaba Token Plan", "mimo": "Xiaomi MiMo", "stepfun": "StepFun"
    ]

    private static func makeProvider(_ row: [String: Any], accountNumber: Int? = nil) -> QuotaProvider? {
        guard let id = cleanText(row["provider"], limit: 64), id != "cli" else { return nil }
        let usage = row["usage"] as? [String: Any] ?? [:]
        let labels = row["rateWindowLabels"] as? [String: Any] ?? [:]
        let observation = usage["planObservation"] as? [String: Any]
        let identity = usage["identity"] as? [String: Any]
        let plan = cleanText(observation?["rawPlan"]) ?? knownPlan(identity?["loginMethod"] ?? usage["loginMethod"])
        let namedWindows = (usage["extraRateWindows"] as? [[String: Any]] ?? []).compactMap { extra
            -> (id: String, title: Any?, window: [String: Any])? in
            guard extra["usageKnown"] as? Bool != false,
                  let raw = extra["window"] as? [String: Any],
                  raw["isSyntheticPlaceholder"] as? Bool != true,
                  let used = number(raw["usedPercent"]), used >= 0 else { return nil }
            return (extra["id"] as? String ?? "", extra["title"], raw)
        }
        // CodexBar copies Antigravity's compact representatives from its named quota summary.
        // Match the copied payload so independent windows and older fallback data still display.
        let antigravitySummaries = id == "antigravity" ? namedWindows.filter {
            $0.id.hasPrefix("antigravity-quota-summary-")
        }.map(\.window) : []
        var windows: [QuotaWindow] = []
        var details: [String] = []
        for (key, fallback) in [("primary", "主要额度"), ("secondary", "次要额度"), ("tertiary", "额外额度")] {
            guard let raw = usage[key] as? [String: Any] else { continue }
            if key != "tertiary", antigravitySummaries.contains(where: { NSDictionary(dictionary: raw).isEqual(to: $0) }) {
                continue
            }
            addWindow(raw, title: labels[key], fallback: fallback, windows: &windows, details: &details)
        }
        for extra in namedWindows {
            addWindow(extra.window, title: extra.title, fallback: "额外额度", windows: &windows, details: &details)
        }
        if let dashboard = row["openaiDashboard"] as? [String: Any] {
            if let limit = dashboard["codeReviewLimit"] as? [String: Any], number(limit["usedPercent"]) != nil {
                addWindow(limit, title: "代码审查", fallback: "代码审查", windows: &windows, details: &details)
            } else if let remaining = number(dashboard["codeReviewRemainingPercent"]), (0...100).contains(remaining) {
                windows.append(QuotaWindow(label: "代码审查", usedPercent: 100 - remaining,
                                           resetsAt: nil, resetDescription: nil))
            }
        }
        if let credits = row["credits"] as? [String: Any], credits["balanceReadSucceeded"] as? Bool != false,
           let remaining = number(credits["remaining"]), remaining >= 0 {
            details.append("剩余积分 \(amount(remaining))")
        }
        if let cost = usage["providerCost"] as? [String: Any], cost["balanceIsUnavailable"] as? Bool != true,
           let balance = number(cost["balance"]), let currency = cleanText(cost["currencyCode"], limit: 12) {
            details.append("余额 \(amount(balance)) \(currency)")
        }
        let unavailable = windows.isEmpty && details.isEmpty
        if !unavailable, let age = number(row["ageSeconds"]), age >= 60 {
            details.append("CodexBar 缓存 · \(amount((age / 60).rounded(.down))) 分钟前")
        }
        return QuotaProvider(id: id, name: providerNames[id] ?? id, accountNumber: accountNumber, plan: plan,
                             windows: windows, details: details, unavailable: unavailable)
    }

    private static func addWindow(_ raw: [String: Any], title: Any?, fallback: String,
                                  windows: inout [QuotaWindow], details: inout [String]) {
        guard raw["isSyntheticPlaceholder"] as? Bool != true,
              let used = number(raw["usedPercent"]), used >= 0 else { return }
        let interval = windowLength(raw["windowMinutes"])
        let label = cleanText(raw["title"]) ?? cleanText(title) ?? interval ?? fallback
        let length = ["session", "current session", "session limit"].contains(label.lowercased()) ? interval : nil
        let resolvedLabel = length ?? label
        let window = QuotaWindow(label: resolvedLabel, usedPercent: min(100, used), resetsAt: date(raw["resetsAt"]),
                                 resetDescription: cleanText(raw["resetDescription"], limit: 120))
        windows.append(window)
        if let limit = number(raw["quotaLimit"]), limit > 0,
           let unit = cleanText(raw["quotaUnit"], limit: 24) {
            details.append("\(resolvedLabel)限额 \(amount(limit)) \(unit)")
        }
    }

    private static func windowLength(_ value: Any?) -> String? {
        guard let minutes = number(value), minutes > 0, minutes <= 60 * 24 * 365 else { return nil }
        let time = Int(minutes)
        if time == 10_080 { return "每周额度" }
        if time.isMultiple(of: 1_440) { return "\(time / 1_440) 天额度" }
        if time.isMultiple(of: 60) { return "\(time / 60) 小时额度" }
        return "\(time) 分钟额度"
    }

    private static func knownPlan(_ value: Any?) -> String? {
        guard let plan = cleanText(value) else { return nil }
        let firstWord = plan.split(whereSeparator: \.isWhitespace).first?.lowercased()
        let known = ["free", "plus", "pro", "max", "team", "teams", "business", "enterprise", "edu", "education", "go"]
        return firstWord.map { known.contains($0) } == true ? plan : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            return nil
        }
        return value.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let parser = ISO8601DateFormatter()
            if let result = parser.date(from: string) { return result }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: string)
        }
        if let seconds = number(value), (0...32_503_680_000).contains(seconds) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func cleanText(_ value: Any?, limit: Int = 80) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= limit, text.rangeOfCharacter(from: .controlCharacters) == nil,
              !text.contains("@"), !text.contains("://") else { return nil }
        return text
    }

    private static func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    static func selfTest() throws {
        func decodeFixture(_ data: Data, exitStatus: Int32, now: Date = Date()) -> QuotaFetchResult {
            guard let rows = usageRows(from: data) else { return .failure }
            return decode(rows, exitStatus: exitStatus, now: now)
        }
        let fixture = Data(#"""
        [
          {"provider":"codex", "account":"private@example.test", "rateWindowLabels":{"secondary":"Weekly"},
           "usage":{"primary":null,"secondary":{"usedPercent":27.5,"resetsAt":"2026-11-25T16:30:00Z","windowMinutes":10080},
             "tertiary":{"usedPercent":0,"isSyntheticPlaceholder":true},"planObservation":{"rawPlan":"pro"},
             "extraRateWindows":[{"title":"GPT-5.1-Codex-Spark","window":{"usedPercent":9,"resetsAt":"2026-11-24T10:00:00.123Z"}},
               {"title":"Unreported","usageKnown":false,"window":{"usedPercent":0}}]},
           "credits":{"remaining":0,"balanceReadSucceeded":true},"openaiDashboard":{"codeReviewRemainingPercent":90,
             "codeReviewLimit":{"usedPercent":10,"resetsAt":"2026-11-25T16:30:00Z"}}},
          {"provider":"claude","error":{"code":1,"message":"private session data"}},
          {"provider":"kimi","usage":{"primary":{"usedPercent":103,"quotaLimit":1000,"quotaUnit":"requests","windowMinutes":300}}}
        ]
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case let .success(snapshot) = decodeFixture(fixture, exitStatus: 1, now: now),
              snapshot.providers.count == 3, snapshot.fetchedAt == now else { throw TestFailure.contract }
        let codex = snapshot.providers[0]
        guard codex.name == "Codex", codex.plan == "pro", !codex.unavailable,
              codex.windows.map(\.label) == ["Weekly", "GPT-5.1-Codex-Spark", "代码审查"],
              codex.windows.map(\.usedPercent) == [27.5, 9, 10],
              codex.windows.allSatisfy({ $0.resetsAt != nil }),
              codex.details == ["剩余积分 \(amount(0))"] else { throw TestFailure.contract }
        let claude = snapshot.providers[1]
        guard claude.unavailable, claude.windows.isEmpty, claude.details.isEmpty, claude.plan == nil else {
            throw TestFailure.contract
        }
        let kimi = snapshot.providers[2]
        guard kimi.windows.first?.usedPercent == 100, kimi.windows.first?.label == "5 小时额度",
              kimi.details == ["5 小时额度限额 \(amount(1000)) requests"] else { throw TestFailure.contract }
        guard case .failure = decodeFixture(Data(#"[{"provider":"cli","error":{"message":"private config detail"}}]"#.utf8), exitStatus: 1),
              case .failure = decodeFixture(Data("{}".utf8), exitStatus: 0),
              case let .success(empty) = decodeFixture(Data("[]".utf8), exitStatus: 0), empty.providers.isEmpty else {
            throw TestFailure.contract
        }
        try testAntigravitySummaryAliases()
        try testAntigravityAccounts()
    }

    private static func testAntigravityAccounts() throws {
        let baselineRows: [[String: Any]] = [
            ["provider": "codex", "usage": ["primary": ["usedPercent": 3]]],
            ["provider": "antigravity", "account": "first@example.test", "usage": ["primary": ["usedPercent": 20]]],
            ["provider": "claude", "usage": ["primary": ["usedPercent": 42]]]
        ]
        let accounts = Data(#"""
        [
          {"provider":"antigravity","account":"first@example.test","usage":{"primary":{"usedPercent":24}}},
          {"provider":"antigravity","account":"second@example.test","error":{"message":"private error data"}}
        ]
        """#.utf8)
        guard case let .success(baseline) = decode(baselineRows, exitStatus: 0),
              baselineRows.filter(isAntigravityAccount).count == 1,
              !isAntigravityAccount(["provider": "antigravity", "account": " "]),
              !isAntigravityAccount(["provider": "antigravity"]) else { throw TestFailure.contract }
        let expanded = expandingAntigravity(in: baseline, with: accounts).providers
        guard expanded.map(\.id) == ["codex", "antigravity", "antigravity", "claude"],
              expanded.map(\.accountNumber) == [nil, 1, 2, nil],
              expanded.map({ $0.windows.first?.usedPercent }) == [3, 24, nil, 42],
              expanded[2].unavailable, expanded[2].details.isEmpty else { throw TestFailure.contract }

        let single = Data(#"[{"provider":"antigravity","account":"first@example.test","usage":{"primary":{"usedPercent":24}}}]"#.utf8)
        let rejected = Data(#"[{"provider":"cli","error":{"message":"private error data"}}]"#.utf8)
        for fallback in [nil, rejected, single] {
            let original = expandingAntigravity(in: baseline, with: fallback).providers
            guard original.map(\.id) == ["codex", "antigravity", "claude"],
                  original.allSatisfy({ $0.accountNumber == nil }),
                  original[1].windows.first?.usedPercent == 20 else { throw TestFailure.contract }
        }
    }

    private static func testAntigravitySummaryAliases() throws {
        let session: [String: Any] = ["usedPercent": 17.1, "windowMinutes": 300, "resetsAt": "2026-11-24T04:50:00Z"]
        let weekly: [String: Any] = ["usedPercent": 5, "windowMinutes": 10_080, "resetsAt": "2026-11-30T23:50:00Z"]
        let thirdPartySession: [String: Any] = ["usedPercent": 0, "windowMinutes": 300, "resetsAt": "2026-11-24T06:50:00Z"]
        let thirdPartyWeekly: [String: Any] = ["usedPercent": 0, "windowMinutes": 10_080, "resetsAt": "2026-12-01T01:50:00Z"]
        func bucket(_ id: String, _ title: String, _ window: [String: Any], known: Bool = true) -> [String: Any] {
            ["id": "antigravity-quota-summary-" + id, "title": title, "window": window, "usageKnown": known]
        }
        let geminiWeekly = bucket("gemini-weekly", "Gemini weekly", weekly)
        let claudeWeekly = bucket("3p-weekly", "Claude/GPT weekly", thirdPartyWeekly)
        let all = [bucket("gemini-5h", "Gemini 5-hour", session), geminiWeekly,
                   bucket("3p-5h", "Claude/GPT 5-hour", thirdPartySession), claudeWeekly]
        func labels(primary: [String: Any], secondary: [String: Any], extras: [[String: Any]]) -> [String]? {
            makeProvider(["provider": "antigravity",
                          "rateWindowLabels": ["primary": "Gemini Models", "secondary": "Claude and GPT"],
                          "usage": ["primary": primary, "secondary": secondary, "extraRateWindows": extras]])?.windows.map(\.label)
        }
        guard labels(primary: session, secondary: thirdPartySession, extras: all) ==
            ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"],
            labels(primary: weekly, secondary: thirdPartyWeekly, extras: [geminiWeekly, claudeWeekly]) ==
                ["Gemini weekly", "Claude/GPT weekly"],
            labels(primary: session, secondary: thirdPartySession, extras: [geminiWeekly]) ==
                ["Gemini Models", "Claude and GPT", "Gemini weekly"],
            labels(primary: session, secondary: thirdPartySession,
                   extras: [bucket("gemini-5h", "Unavailable", session, known: false)]) ==
                ["Gemini Models", "Claude and GPT"] else { throw TestFailure.contract }
    }

    private enum TestFailure: LocalizedError {
        case contract
        var errorDescription: String? { "CodexBar 额度数据自测失败" }
    }
}
