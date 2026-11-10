import Foundation

@main enum RefreshTests {
    static func main() throws {
        precondition(RefreshPolicy.interval(0) == 30)
        precondition(RefreshPolicy.interval(15) == 15)
        precondition(RefreshPolicy.interval(60) == 60)
        let timestamp = "2026-11-10T22:00:00Z"
        let original = Dashboard(automaticRefreshMinutes: 15, lastFullRefreshAt: timestamp)
        let cached = try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(original))
        precondition(cached.automaticRefreshMinutes == 15)
        precondition(cached.lastFullRefreshAt == timestamp)
        precondition(parseBankDate(cached.lastFullRefreshAt) != nil)
        // Downloading or caching a dashboard cannot invent a successful bank refresh.
        precondition(Dashboard().lastFullRefreshAt == nil)
        let downloadedAgain = try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(cached))
        precondition(downloadedAgain.lastFullRefreshAt == timestamp)
        print("Refresh metadata passed: supported intervals, defaults, server timestamps, and cached downloads preserve source freshness.")
    }
}
