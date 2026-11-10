import Foundation

@main enum WidgetTests {
    static func main() throws {
        let older = "2026-11-08T10:00:00Z", newer = "2026-11-09T10:00:00.000Z"
        func account(_ id: String, updatedAt: String?) -> WidgetAccount {
            WidgetAccount(id: id, bank: "Test", name: "Test", mask: "0000", isCredit: false, currency: "USD", balance: 100, updatedAt: updatedAt)
        }
        let snapshot = WidgetSnapshot(date: "2026-11-10T12:00:00Z", accounts: [account("old", updatedAt: older), account("new", updatedAt: newer)])
        precondition(snapshot.updatedDate == widgetSourceDate(older))
        let fetchedAgain = WidgetSnapshot(date: "2026-11-11T12:00:00Z", accounts: snapshot.accounts)
        precondition(fetchedAgain.updatedDate == snapshot.updatedDate)
        let hidden = WidgetPreferences(server: "https://example.com", token: "test-only", order: [], hidden: ["old"], names: [:]).applying(to: snapshot)
        precondition(hidden.updatedDate == widgetSourceDate(newer))
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data("{\"date\":\"2026-11-10T12:00:00Z\",\"accounts\":[{\"id\":\"legacy\",\"bank\":\"Test\",\"name\":\"Test\",\"mask\":\"0000\",\"isCredit\":false,\"currency\":\"USD\",\"balance\":100}]}".utf8))
        precondition(legacy.updatedDate == nil)
        precondition(WidgetSnapshot(date: newer, accounts: [account("missing", updatedAt: nil)]).updatedDate == nil)
        precondition(WidgetSnapshot(date: newer, accounts: [account("invalid", updatedAt: "invalid")]).updatedDate == nil)
        precondition(oldestWidgetSource([newer, nil, older]) == older)
        print("Widget freshness tests passed: source timestamps stay stable across downloads, oldest visible account wins, unknown legacy dates stay unknown.")
    }
}
