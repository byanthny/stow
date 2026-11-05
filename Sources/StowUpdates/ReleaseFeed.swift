import Foundation
import StowCore

/// The opt-in check's one request: an unauthenticated read of a release list, with nothing downloaded.
public enum ReleaseFeed {
    /// Replies longer than this are refused.
    public static let maximumResponseBytes = 1024 * 1024

    /// A GET with fixed headers and no cookies or credentials.
    public static func request(for source: ReleaseSource = .stow) -> URLRequest {
        var request = URLRequest(
            url: source.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Stow", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// An ephemeral session with no cookies, credentials, or cache.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Asks GitHub for the source's releases and reads at most `maximumResponseBytes` of the reply.
    public static func fetchReleases(
        from source: ReleaseSource = .stow, configuration: URLSessionConfiguration = sessionConfiguration()
    ) async throws -> [StowRelease] {
        let session = URLSession(configuration: configuration)
        // Also stops a reply that runs past the limit.
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request(for: source))
        } catch {
            throw UpdateCheckError.unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw UpdateCheckError.unreadable }
        switch status {
        case 200: break
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.unavailable
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { throw UpdateCheckError.tooLarge }
                data.append(byte)
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.unreachable
        }
        return try source.releases(from: data)
    }
}
