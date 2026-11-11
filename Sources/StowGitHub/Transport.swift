import Darwin
import Foundation

public enum GraphQLValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case null
    case array([GraphQLValue])
    case object([String: GraphQLValue])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Int.self) {
            self = .integer(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode([GraphQLValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: GraphQLValue].self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var int: Int? { if case .integer(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var array: [GraphQLValue] { if case .array(let v) = self { v } else { [] } }
    var object: [String: GraphQLValue] { if case .object(let v) = self { v } else { [:] } }
    subscript(_ key: String) -> GraphQLValue { object[key] ?? .null }
    var isNull: Bool { self == .null }
}

public struct GraphQLResponse: Sendable {
    public var body: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var exitCode: Int32
    public init(body: Data, statusCode: Int = 200, headers: [String: String] = [:], exitCode: Int32 = 0) {
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
        self.exitCode = exitCode
    }
}

public protocol GraphQLTransport: Sendable {
    func execute(query: String, variables: [String: GraphQLValue]) async throws -> GraphQLResponse
}

public enum GitHubError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound, authenticationRequired, requestFailed, invalidResponse, timedOut, unavailable,
        unsupportedHost
    case rateLimited(until: Date)
    /// `gh` answered as another account than the profile uses.
    case accountMismatch(actualLogin: String)
    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "GitHub CLI was not found. Install gh or choose its executable in settings."
        case .authenticationRequired: "GitHub CLI needs authentication. Run gh auth login for github.com."
        case .requestFailed:
            "GitHub could not complete the request. Check your connection and GitHub CLI authentication."
        case .invalidResponse: "GitHub returned an unreadable response."
        case .timedOut: "GitHub took too long to respond. Try again later."
        case .unavailable: "This pull request is unavailable or you do not have access."
        case .unsupportedHost: "Stow currently supports github.com pull requests."
        case .accountMismatch: "GitHub is signed in as a different account than this profile uses."
        case .rateLimited(let date):
            "GitHub requests are paused until \(date.formatted(date: .omitted, time: .standard))."
        }
    }
}

/// Uses gh's existing credential store. No shell, credential reading, or response logging.
public struct GHProcessTransport: GraphQLTransport {
    public var executableURL: URL
    public var timeout: TimeInterval
    public init(executableURL: URL, timeout: TimeInterval = 45) {
        self.executableURL = executableURL
        self.timeout = timeout
    }
    static func decodeCLIOutput(_ output: Data, exitCode: Int32) -> GraphQLResponse {
        ProcessControl.parse(output, exitCode: exitCode)
    }
    public func execute(query: String, variables: [String: GraphQLValue]) async throws -> GraphQLResponse {
        let input = try JSONEncoder().encode(
            GraphQLValue.object(["query": .string(query), "variables": .object(variables)]))
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Task.checkCancellation()
                return try control.run(executable: executableURL, input: input, timeout: timeout)
            }.value
        } onCancel: {
            control.cancel()
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func drain(_ file: FileHandle) {
        while true {
            let part = file.availableData
            if part.isEmpty { break }
            lock.lock()
            if bytes.count + part.count <= 32 * 1_024 * 1_024 { bytes.append(part) } else { overflow = true }
            lock.unlock()
        }
    }
    func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if overflow { throw GitHubError.invalidResponse }
        return bytes
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false
    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        stop(p)
    }
    private func expire() {
        lock.lock()
        expired = true
        let p = process
        lock.unlock()
        stop(p)
    }
    private func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        // A hung helper must not prevent cancellation or retain the pipe readers forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    func run(executable: URL, input: Data, timeout: TimeInterval) throws -> GraphQLResponse {
        let p = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        // A write to a closed pipe fails with EPIPE instead of raising SIGPIPE.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw GitHubError.requestFailed
        }
        p.executableURL = executable
        p.arguments = ["api", "--hostname", "github.com", "graphql", "--input", "-", "--include"]
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = stdin
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        process = p
        do { try p.run() } catch {
            lock.unlock()
            throw GitHubError.requestFailed
        }
        lock.unlock()
        let out = DataBuffer()
        let err = DataBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            out.drain(stdout.fileHandleForReading)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            err.drain(stderr.fileHandleForReading)
            group.leave()
        }
        let deadline = DispatchWorkItem { self.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let wroteInput: Bool
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            wroteInput = true
        } catch {
            try? stdin.fileHandleForWriting.close()
            wroteInput = false
        }
        p.waitUntilExit()
        deadline.cancel()
        group.wait()
        lock.lock()
        let wasCancelled = cancelled
        let wasExpired = expired
        process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasExpired { throw GitHubError.timedOut }
        let raw = try out.result()
        // Inspect only known authentication markers; never return stderr or private API text.
        if raw.isEmpty || !wroteInput {
            let marker = (try? err.result()).flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""
            if marker.contains("gh auth login") || marker.contains("requires authentication")
                || marker.contains("http 401")
            {
                throw GitHubError.authenticationRequired
            }
            throw GitHubError.requestFailed
        }
        return Self.parse(raw, exitCode: p.terminationStatus)
    }
    static func parse(_ raw: Data, exitCode: Int32) -> GraphQLResponse {
        guard let text = String(data: raw, encoding: .utf8), text.hasPrefix("HTTP/") else {
            return .init(body: raw, exitCode: exitCode)
        }
        let separator = text.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        guard let split = text.range(of: separator) else { return .init(body: raw, exitCode: exitCode) }
        let lines = text[..<split.lowerBound].components(separatedBy: .newlines).filter { !$0.isEmpty }
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 200
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        return .init(
            body: Data(text[split.upperBound...].utf8), statusCode: status, headers: headers, exitCode: exitCode)
    }
}
