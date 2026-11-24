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

enum QuotaUsage {
    private static let timeout: TimeInterval = 25
    private static let outputLimit = 2 * 1024 * 1024

    // Call off the main thread. CodexBar owns account configuration and authentication.
    static func fetch() -> QuotaFetchResult {
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
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .missingDependency
        }
        environment["PATH"] = bins.joined(separator: ":")
        environment.removeValue(forKey: "CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT")
        let arguments = ["usage", "--format", "json", "--json-only", "--web-timeout", "15"]
        guard let (data, exitStatus) = capture(executable: executable, arguments: arguments, environment: environment) else {
            return .failure
        }
        return decode(data, exitStatus: exitStatus)
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

    // Project only display fields. The response can also contain account
    // identities and provider error diagnostics, which the pet does not display.
    private static func decode(_ data: Data, exitStatus: Int32, now: Date = Date()) -> QuotaFetchResult {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return .failure }
        if rows.isEmpty { return exitStatus == 0 ? .success(QuotaSnapshot(providers: [], fetchedAt: now)) : .failure }
        let providers = rows.compactMap(makeProvider)
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

    private static func makeProvider(_ row: [String: Any]) -> QuotaProvider? {
        guard let id = cleanText(row["provider"], limit: 64), id != "cli" else { return nil }
        let usage = row["usage"] as? [String: Any] ?? [:]
        let labels = row["rateWindowLabels"] as? [String: Any] ?? [:]
        let observation = usage["planObservation"] as? [String: Any]
        let identity = usage["identity"] as? [String: Any]
        let plan = cleanText(observation?["rawPlan"]) ?? knownPlan(identity?["loginMethod"] ?? usage["loginMethod"])
        var windows: [QuotaWindow] = []
        var details: [String] = []
        for (key, fallback) in [("primary", "主要额度"), ("secondary", "次要额度"), ("tertiary", "额外额度")] {
            guard let raw = usage[key] as? [String: Any] else { continue }
            addWindow(raw, title: labels[key], fallback: fallback, windows: &windows, details: &details)
        }
        for extra in usage["extraRateWindows"] as? [[String: Any]] ?? [] {
            guard extra["usageKnown"] as? Bool != false, let raw = extra["window"] as? [String: Any] else { continue }
            addWindow(raw, title: extra["title"], fallback: "额外额度", windows: &windows, details: &details)
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
        return QuotaProvider(id: id, name: providerNames[id] ?? id, plan: plan,
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
        guard case let .success(snapshot) = decode(fixture, exitStatus: 1, now: now),
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
        guard case .failure = decode(Data(#"[{"provider":"cli","error":{"message":"private config detail"}}]"#.utf8), exitStatus: 1),
              case .failure = decode(Data("{}".utf8), exitStatus: 0),
              case let .success(empty) = decode(Data("[]".utf8), exitStatus: 0), empty.providers.isEmpty else {
            throw TestFailure.contract
        }
    }

    private enum TestFailure: LocalizedError {
        case contract
        var errorDescription: String? { "CodexBar 额度数据自测失败" }
    }
}
