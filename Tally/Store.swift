import SwiftUI
import Security
import LocalAuthentication
import WidgetKit

struct ConnectionSettings: Codable {
    var url: String
    var token: String
}
enum Vault {
    static let service = "com.pratick.Tally.connection"
    static func read() -> ConnectionSettings? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ConnectionSettings.self, from: data)
    }
    static func save(_ settings: ConnectionSettings) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let data = try JSONEncoder().encode(settings)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Couldn't save the connection securely.") }
        } else if status != errSecSuccess { throw AppError.message("Couldn't update the secure connection.") }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
@MainActor @Observable final class TallyStore {
    var dashboard = Dashboard() { didSet { cachedSpendingIndex = nil } }
    @ObservationIgnored private var cachedSpendingIndex: SpendingIndex?
    var spendingIndex: SpendingIndex {
        let snapshot = dashboard
        if let cachedSpendingIndex { return cachedSpendingIndex }
        let index = SpendingIndex(dashboard: snapshot)
        cachedSpendingIndex = index
        return index
    }
    var busy = false
    var unlocked = false
    var authenticating = false
    var error: String?
    var isOffline = false
    var savedAt: Date?
    var settings: ConnectionSettings?
    var reconnectURL: URL?
    var selectedTab = 0
    var connectionMessage: String?
    var pendingLinkSessionID: String?
    var accountOrder: [String]
    var hiddenAccountIDs: [String]
    var accountNames: [String:String]
    private var browserIsAdding = false
    var useFaceID: Bool { didSet { UserDefaults.standard.set(useFaceID, forKey: "useFaceID") } }
    var configured: Bool { settings != nil }
    private var lastManualRefresh: Date?
    private let session: URLSession
    private var cacheURL: URL { URL.documentsDirectory.appending(path: "dashboard.json") }
    init() {
        // Apply the owner's request once for existing installations, then retain optional future choices.
        let preferences = UserDefaults.standard
        if !preferences.bool(forKey: "optionalLockMigration") {
            preferences.set(false, forKey: "useFaceID")
            preferences.set(true, forKey: "optionalLockMigration")
        }
        accountOrder = preferences.stringArray(forKey: "homeAccountOrder") ?? []
        hiddenAccountIDs = preferences.stringArray(forKey: "hiddenAccountIDs") ?? []
        accountNames = preferences.dictionary(forKey: "accountNames") as? [String:String] ?? [:]
        pendingLinkSessionID = preferences.string(forKey: "pendingLinkSessionID")
        useFaceID = preferences.object(forKey: "useFaceID") as? Bool ?? false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config)
        settings = Vault.read()
        // Installation-only pairing file; consumed into this device's Keychain, then removed.
        let pairing = URL.documentsDirectory.appending(path: "Pairing.plist")
        if let data = try? Data(contentsOf: pairing), let value = try? PropertyListDecoder().decode(ConnectionSettings.self, from: data) {
            do { try Vault.save(value); settings = value; try FileManager.default.removeItem(at: pairing) }
            catch { self.error = "Couldn't finish secure pairing. Open Settings to reconnect." }
        }
    }
    func authenticate() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if useFaceID {
            let context = LAContext()
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your finances in Tally")
                guard success else { return }
            } catch { self.error = "Unlock was cancelled. Tap Unlock to try again."; return }
        }
        unlocked = true
        loadCache()
        if configured { await refresh() }
    }
    func becameActive() async {
        if unlocked && configured && !authenticating { await refresh() }
    }
    func lock() { if useFaceID { unlocked = false; dashboard = Dashboard() } }
    func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(CachedDashboard.self, from: data) else { return }
        dashboard = saved.dashboard; savedAt = saved.date
    }
    func configure(url: String, token: String) async -> Bool {
        guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), endpoint.scheme == "https",
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
              endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/", token.count >= 32 else {
            error = "Enter an HTTPS server address and a valid access key."; return false
        }
        let value = ConnectionSettings(url: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let result: Dashboard = try await request("/v1/dashboard", settings: value)
            try Vault.save(value); settings = value; dashboard = result
            try? FileManager.default.removeItem(at: cacheURL)
            await refresh(path: "/v1/sync")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func refresh(path: String = "/v1/dashboard") async {
        guard let settings, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result: Dashboard = try await request(path, method: path == "/v1/dashboard" ? "GET" : "POST", settings: settings)
            dashboard = result; isOffline = false; savedAt = .now
            pendingLinkSessionID = result.pendingLinkID
            UserDefaults.standard.set(pendingLinkSessionID, forKey: "pendingLinkSessionID")
            try persistDashboard()
            await configureWidgetIfNeeded()
            updateWidget()
        } catch { self.error = error.localizedDescription; isOffline = true }
    }
    func refreshManually() async {
        guard !busy else { return }
        // Repeated gestures share the server snapshot rather than hitting bank rate limits.
        if let lastManualRefresh, Date.now.timeIntervalSince(lastManualRefresh) < 30 {
            await refresh()
            return
        }
        lastManualRefresh = .now
        await refresh(path: "/v1/balances")
        if error != nil { lastManualRefresh = nil }
    }
    func reconnect(_ bank: BankConnection) async {
        guard let settings, !busy else { return }
        busy = true; browserIsAdding = false; defer { busy = false }
        do {
            struct Link: Decodable { let url: String }
            let result: Link = try await request("/v1/reconnect/\(bank.id)", method: "POST", settings: settings)
            guard let url = URL(string: result.url), url.scheme == "https", let host = url.host,
                  host == "plaid.com" || host.hasSuffix(".plaid.com") else { throw AppError.message("Invalid bank sign-in address.") }
            reconnectURL = url
        } catch { self.error = error.localizedDescription }
    }
    func eraseCache() {
        do { if FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }; dashboard = Dashboard(); savedAt = nil }
        catch { self.error = "Couldn't clear the local cache." }
    }
    var orderedAccounts: [BankAccount] {
        let base = dashboard.activeAccounts.sorted {
            $0.isCredit == $1.isCredit ? ($0.bank == $1.bank ? $0.id < $1.id : $0.bank < $1.bank) : !$0.isCredit
        }
        return base.sorted { (accountOrder.firstIndex(of: $0.id) ?? (base.firstIndex(of: $0)! + accountOrder.count)) < (accountOrder.firstIndex(of: $1.id) ?? (base.firstIndex(of: $1)! + accountOrder.count)) }
    }
    var homeAccounts: [BankAccount] { orderedAccounts.filter { !hiddenAccountIDs.contains($0.id) } }
    var homeDashboard: Dashboard {
        var result = dashboard; result.accounts = homeAccounts; return result
    }
    func accountName(_ account: BankAccount) -> String { accountNames[account.id] ?? account.displayName }
    func reorderAccounts(from offsets: IndexSet, to destination: Int) {
        var ids = orderedAccounts.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        accountOrder = ids; savePreferences(); updateWidget()
    }
    func renameAccount(_ account: BankAccount, to name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { accountNames.removeValue(forKey: account.id) } else { accountNames[account.id] = String(value.prefix(60)) }
        savePreferences(); updateWidget()
    }
    func setHomeVisibility(_ account: BankAccount, visible: Bool) {
        hiddenAccountIDs.removeAll { $0 == account.id }
        if !visible { hiddenAccountIDs.append(account.id) }
        savePreferences(); updateWidget()
    }
    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(accountOrder, forKey: "homeAccountOrder")
        defaults.set(hiddenAccountIDs, forKey: "hiddenAccountIDs")
        defaults.set(accountNames, forKey: "accountNames")
    }
    func startAddingBank() async {
        guard let settings, !busy else { return }
        busy = true; error = nil; connectionMessage = nil
        defer { busy = false }
        do {
            struct Session: Decodable { let sessionID: String; let url: String }
            let result: Session = try await request("/v1/link/start", method: "POST", settings: settings)
            guard let url = URL(string: result.url), url.scheme == "https", let host = url.host, host == "plaid.com" || host.hasSuffix(".plaid.com") else { throw AppError.message("Invalid secure bank address.") }
            pendingLinkSessionID = result.sessionID
            UserDefaults.standard.set(result.sessionID, forKey: "pendingLinkSessionID")
            browserIsAdding = true; reconnectURL = url
        } catch { self.error = error.localizedDescription }
    }
    func browserDismissed() async {
        if browserIsAdding { await completeBankConnection() }
        else { await refresh(path: "/v1/sync") }
    }
    func completeBankConnection() async {
        guard let settings, let id = pendingLinkSessionID, !busy else { return }
        busy = true; defer { busy = false }
        do {
            struct Result: Decodable { let status: String; let message: String? }
            let result: Result = try await request("/v1/link/\(id)/complete", method: "POST", settings: settings)
            connectionMessage = result.message
            if result.status != "pending" {
                pendingLinkSessionID = nil; UserDefaults.standard.removeObject(forKey: "pendingLinkSessionID")
            }
            let value: Dashboard = try await request("/v1/dashboard", settings: settings)
            dashboard = value; savedAt = .now; isOffline = false
            try persistDashboard()
            await configureWidgetIfNeeded(); updateWidget()
        } catch { self.error = error.localizedDescription }
    }
    func cancelBankConnection() async {
        guard let settings, let id = pendingLinkSessionID, !busy else { return }
        busy = true; defer { busy = false }
        do {
            struct Result: Decodable { let status: String }
            let _: Result = try await request("/v1/link/\(id)/cancel", method: "POST", settings: settings)
            pendingLinkSessionID = nil; UserDefaults.standard.removeObject(forKey: "pendingLinkSessionID")
            connectionMessage = nil
        } catch { self.error = error.localizedDescription }
    }
    func disconnect(_ bank: BankConnection) async -> Bool {
        guard let settings, !busy else { return false }
        busy = true; defer { busy = false }
        do {
            let result: Dashboard = try await request("/v1/connections/\(bank.id)", method: "DELETE", settings: settings)
            dashboard = result; savedAt = .now
            try persistDashboard()
            updateWidget(); connectionMessage = "Disconnected. Your saved history is kept."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func persistDashboard() throws {
        let data = try JSONEncoder().encode(CachedDashboard(dashboard: dashboard, date: savedAt ?? .now))
        try data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
        var url = cacheURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func configureWidgetIfNeeded() async {
        guard let settings else { return }
        if let value = WidgetStorage.read("configuration", as: WidgetPreferences.self), value.server == settings.url { return }
        do {
            struct Access: Decodable { let token: String }
            let result: Access = try await request("/v1/widget/access", settings: settings)
            WidgetStorage.save(WidgetPreferences(server: settings.url, token: result.token, order: accountOrder, hidden: hiddenAccountIDs, names: accountNames), key: "configuration")
        } catch { /* The app remains usable when widget setup needs another refresh. */ }
    }
    func updateWidget() {
        if var config = WidgetStorage.read("configuration", as: WidgetPreferences.self) {
            config.order = homeAccounts.map(\.id); config.hidden = hiddenAccountIDs; config.names = accountNames
            WidgetStorage.save(config, key: "configuration")
        }
        let accounts = homeAccounts.map { account in
            WidgetAccount(id: account.id, bank: account.bank, name: accountName(account), mask: account.mask, isCredit: account.isCredit, currency: account.currency, balance: dashboard.displayBalance(for: account))
        }
        WidgetStorage.save(WidgetSnapshot(date: ISO8601DateFormatter().string(from: savedAt ?? .now), accounts: accounts), key: "snapshot")
        WidgetCenter.shared.reloadTimelines(ofKind: "TallyBalances")
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", settings: ConnectionSettings) async throws -> T {
        guard let url = URL(string: settings.url + path) else { throw AppError.message("Invalid server address.") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("Tally/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("The server didn't respond.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AppError.message("Your access key wasn't accepted. Update it in Settings.") }
            if http.statusCode == 429 { throw AppError.message("Please wait 30 seconds before syncing again.") }
            throw AppError.message("The server couldn't update right now. Try again shortly.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
private struct CachedDashboard: Codable { let dashboard: Dashboard; let date: Date }
