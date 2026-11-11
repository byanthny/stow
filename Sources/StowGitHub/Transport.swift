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
    /// A folder whose `gh` is never launched.
    public var excludedFolder: URL?
    public init(executableURL: URL, timeout: TimeInterval = 45, excluding folder: URL? = nil) {
        self.executableURL = executableURL
        self.timeout = timeout
        excludedFolder = folder
    }
    static func decodeCLIOutput(_ output: Data, exitCode: Int32) -> GraphQLResponse {
        ProcessControl.parse(output, exitCode: exitCode)
    }
    public func execute(query: String, variables: [String: GraphQLValue]) async throws -> GraphQLResponse {
        let input = try JSONEncoder().encode(
            GraphQLValue.object(["query": .string(query), "variables": .object(variables)]))
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await control.run(executable: executableURL, excluding: excludedFolder, input: input, timeout: timeout)
        } onCancel: {
            control.cancel()
        }
    }
}

/// Output read so far, at most 32 MiB. Used only on its control's queue.
private final class DataBuffer {
    private var bytes = Data()
    private var overflow = false
    func append(_ part: DispatchData) {
        guard bytes.count + part.count <= 32 * 1_024 * 1_024 else {
            overflow = true
            return
        }
        part.enumerateBytes { buffer, _, _ in bytes.append(buffer) }
    }
    func result() throws -> Data {
        if overflow { throw GitHubError.invalidResponse }
        return bytes
    }
}

/// One launch of `gh`. Its pipes, deadline, and cancellation are handled on one serial queue, and nothing blocks.
private final class ProcessControl: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.stow.gh")
    // The rest is used only on `queue`.
    private var continuation: CheckedContinuation<GraphQLResponse, any Error>?
    private var process: Process?
    private var channels: [DispatchIO] = []
    private var openReads = 0
    private var hasExited = false
    private var cancelled = false
    private var wroteInput = false
    private let out = DataBuffer()
    private let err = DataBuffer()

    func cancel() {
        queue.async {
            self.cancelled = true
            self.stop(throwing: CancellationError())
        }
    }

    func run(executable: URL, excluding folder: URL?, input: Data, timeout: TimeInterval) async throws
        -> GraphQLResponse
    {
        // Checks the path again before launch.
        guard let checked = GHClient.checkedExecutable(atPath: executable.path, excluding: folder) else {
            throw GitHubError.executableNotFound
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(continuation, executable: checked, input: input, timeout: timeout) }
        }
    }

    private func start(
        _ continuation: CheckedContinuation<GraphQLResponse, any Error>, executable: URL, input: Data,
        timeout: TimeInterval
    ) {
        if cancelled { return continuation.resume(throwing: CancellationError()) }
        self.continuation = continuation
        let p = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        // A write to a closed pipe fails with EPIPE instead of raising SIGPIPE.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            return finish(throwing: GitHubError.requestFailed)
        }
        p.executableURL = executable
        p.arguments = ["api", "--hostname", "github.com", "graphql", "--input", "-", "--include"]
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = stdin
        let done = DispatchGroup()
        done.enter()
        p.terminationHandler = { _ in
            self.queue.async {
                self.exited()
                done.leave()
            }
        }
        do { try p.run() } catch { return finish(throwing: GitHubError.requestFailed) }
        process = p
        for (handle, buffer) in [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)] {
            let channel = open(handle, done: done)
            openReads += 1
            channel.setLimit(lowWater: 1)
            channel.read(offset: 0, length: Int.max, queue: queue) { finished, data, _ in
                if let data { buffer.append(data) }
                guard finished else { return }
                self.openReads -= 1
                self.ended(channel, done: done)
            }
        }
        let writer = open(stdin.fileHandleForWriting, done: done)
        writer.write(offset: 0, data: input.withUnsafeBytes { DispatchData(bytes: $0) }, queue: queue) {
            finished, _, error in
            guard finished else { return }
            self.wroteInput = error == 0
            self.ended(writer, done: done)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(throwing: GitHubError.timedOut) }
        done.notify(queue: queue) { self.complete(status: p.terminationStatus) }
    }

    /// A channel that closes `handle` once it's closed itself.
    private func open(_ handle: FileHandle, done: DispatchGroup) -> DispatchIO {
        done.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        channels.append(channel)
        return channel
    }

    private func ended(_ channel: DispatchIO, done: DispatchGroup) {
        channel.close()
        done.leave()
    }

    /// Looks again shortly after gh exits, once its output has had time to reach the end.
    private func exited() {
        hasExited = true
        guard let process else { return }
        self.process = nil
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.lingered(process) }
    }

    /// Ends what gh left holding its output open, then stops reading and keeps the output gh wrote.
    private func lingered(_ process: Process) {
        guard openReads > 0, continuation != nil else { return }
        Self.end(process)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, openReads > 0 else { return }
            for channel in channels { channel.close(flags: .stop) }
        }
    }

    /// Ends gh and its process group, closes every pipe, and fails the request.
    private func stop(throwing error: any Error) {
        guard continuation != nil else { return }
        if !hasExited, let process { Self.end(process) }
        for channel in channels { channel.close(flags: .stop) }
        finish(throwing: error)
    }

    private func finish(throwing error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func complete(status: Int32) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: Result { try response(status: status) })
    }

    private func response(status: Int32) throws -> GraphQLResponse {
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
        return Self.parse(raw, exitCode: status)
    }

    /// Sends SIGTERM to gh and its process group, then SIGKILL a second later to whatever is left.
    private static func end(_ process: Process) {
        let pid = process.processIdentifier
        let grouped = killpg(pid, SIGTERM) == 0 || errno != ESRCH
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if grouped { _ = killpg(pid, SIGKILL) }
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
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
