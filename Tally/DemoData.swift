#if DEBUG
import Foundation

/// Sample data for previews and Simulator runs (launch with `-TallyDemo`). Debug builds only; never touches the network.
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-TallyDemo") }

    private static func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    private static let iso = ISO8601DateFormatter().string(from: .now)

    static var dashboard: Dashboard {
        var d = Dashboard()
        d.accounts = [
            BankAccount(id: "demo-checking", bankID: "demo-bank-1", bank: "Sample Bank", name: "Everyday Checking", mask: "1234", type: "depository", current: 2_480.55, available: 2_412.10, limit: nil, currency: "USD"),
            BankAccount(id: "demo-savings", bankID: "demo-bank-1", bank: "Sample Bank", name: "High-Yield Savings", mask: "5678", type: "depository", current: 6_150.00, available: 6_150.00, limit: nil, currency: "USD"),
            BankAccount(id: "demo-card", bankID: "demo-bank-2", bank: "Example Card Co", name: "Rewards Card", mask: "4321", type: "credit", current: 642.18, available: 4_357.82, limit: 5_000, currency: "USD"),
        ]
        let rows: [(String, String, Double, Int, Bool, String)] = [
            ("demo-card", "Corner Coffee", 5.75, 0, true, "FOOD_AND_DRINK"),
            ("demo-card", "Fresh Market", 64.32, -1, false, "FOOD_AND_DRINK"),
            ("demo-checking", "Payroll Deposit", -1_850.00, -2, false, "INCOME"),
            ("demo-card", "City Transit", 2.90, -2, false, "TRANSPORTATION"),
            ("demo-card", "Streaming Plus", 15.99, -3, false, "ENTERTAINMENT"),
            ("demo-checking", "Electric Utility", 82.40, -5, false, "RENT_AND_UTILITIES"),
            ("demo-card", "Bookstore", 28.50, -6, false, "GENERAL_MERCHANDISE"),
            ("demo-card", "Taco Spot", 13.25, -8, false, "FOOD_AND_DRINK"),
        ]
        d.transactions = rows.enumerated().map { i, r in
            BankTransaction(id: "demo-tx-\(i)", accountID: r.0, merchant: r.1, amount: r.2, currency: "USD", date: day(r.3), pending: r.4, category: r.5, pendingID: nil)
        }
        d.banks = [
            BankConnection(id: "demo-bank-1", name: "Sample Bank", checkedAt: iso, updatedAt: iso, balanceUpdatedAt: iso, error: nil, importComplete: true),
            BankConnection(id: "demo-bank-2", name: "Example Card Co", checkedAt: iso, updatedAt: iso, balanceUpdatedAt: iso, error: nil, importComplete: true),
        ]
        d.statements = [CreditStatement(accountID: "demo-card", dueDate: day(9), minimumPayment: 35, statementBalance: 512.44, statementDate: day(-12), overdue: false, updatedAt: iso)]
        d.lastFullRefreshAt = iso
        return d
    }

    static var chat: [ChatMessage] {
        [
            ChatMessage(id: "demo-q1", role: "user", text: "How much have I spent on food this week?"),
            ChatMessage(id: "demo-a1", role: "assistant", text: """
            You've spent **$83.32** on food and drink in the last 7 days across 3 purchases.

            | Merchant | Date | Amount |
            |---|---|---|
            | Fresh Market | Yesterday | $64.32 |
            | Taco Spot | 8 days ago | $13.25 |
            | Corner Coffee | Today (pending) | $5.75 |

            That's about **$12 a day**, a little under your usual pace.
            """, sources: Array(dashboard.transactions.filter { $0.category == "FOOD_AND_DRINK" }), modelCalls: 2, retrievedAt: iso),
        ]
    }
}
#endif
