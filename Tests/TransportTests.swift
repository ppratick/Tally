import Foundation

@main enum TransportTests {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let session = AuthenticatedSession.make(requestTimeout: 5, resourceTimeout: 10)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: base + "/redirect")!)
        request.setValue("Bearer test-only", forHTTPHeaderField: "Authorization")
        request.setValue("test-only", forHTTPHeaderField: "X-OpenAI-API-Key")
        let (_, response) = try await session.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 302, "Authenticated requests must not follow redirects")
        let (_, normal) = try await session.data(from: URL(string: base + "/plain")!)
        precondition((normal as? HTTPURLResponse)?.statusCode == 200, "Ordinary requests must still work")
        let (stats, _) = try await session.data(from: URL(string: base + "/stats")!)
        let result = try JSONDecoder().decode(Stats.self, from: stats)
        precondition(result.redirectDestinationRequests == 0, "No request or credential may reach the redirect destination")
        precondition(result.cookieRequests == 0, "Session must not retain cookies")
        print("Transport passed: redirects rejected, credentials stay at the original endpoint, cookies disabled, ordinary requests work.")
    }
    private struct Stats: Decodable { let redirectDestinationRequests: Int; let cookieRequests: Int }
}
