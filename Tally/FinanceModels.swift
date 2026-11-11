import Foundation

private enum BankDayParser {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
func bankDay(_ value: String?) -> Date? {
    guard let value else { return nil }
    return BankDayParser.formatter.date(from: value)
}
struct CreditStatement: Codable, Identifiable {
    let accountID: String
    let dueDate: String?
    let minimumPayment: Double?
    let statementBalance: Double?
    let statementDate: String?
    let overdue: Bool?
    let updatedAt: String
    var id: String { accountID }
    func daysUntilDue(now: Date = .now) -> Int? {
        guard let due = bankDay(dueDate) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: due).day
    }
    var dueLabel: String {
        guard let days = daysUntilDue() else { return "Due date unavailable" }
        if overdue == true { return "Payment overdue" }
        if days < 0 { return "Last due date passed" }
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        return "Due in \(days) days"
    }
}
struct RecurringPayment: Codable, Identifiable {
    let id: String
    let accountID: String
    let merchant: String
    let direction: String
    let category: String
    let frequency: String
    let nextDate: String?
    let lastDate: String
    let averageAmount: Double?
    let lastAmount: Double?
    let currency: String
    let active: Bool
    let status: String
    let transactionIDs: [String]
    var isBill: Bool { direction == "outgoing" && !["TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS", "INCOME"].contains(category) }
    var frequencyLabel: String {
        switch frequency {
        case "WEEKLY": "Weekly"
        case "BIWEEKLY": "Every two weeks"
        case "SEMI_MONTHLY": "Twice a month"
        case "MONTHLY": "Monthly"
        case "ANNUALLY": "Yearly"
        default: "Variable schedule"
        }
    }
    var monthlyEstimate: Double? {
        guard let amount = averageAmount else { return nil }
        let multiplier: Double
        switch frequency {
        case "WEEKLY": multiplier = 52.0 / 12
        case "BIWEEKLY": multiplier = 26.0 / 12
        case "SEMI_MONTHLY": multiplier = 2
        case "MONTHLY": multiplier = 1
        case "ANNUALLY": multiplier = 1.0 / 12
        default: return nil
        }
        return abs(amount) * multiplier
    }
}
struct SpendingCategory: Identifiable {
    let category: String
    let amount: Double
    var id: String { category }
    var name: String { category.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct MonthlySpending: Identifiable {
    let month: Date
    let transactions: [BankTransaction]
    let pending: [BankTransaction]
    var id: Date { month }
    var includedTransactions: [BankTransaction] { pending + transactions }
    var total: Double { centsTotal(includedTransactions.map(\.amount)) }
    var pendingTotal: Double { centsTotal(pending.map(\.amount)) }
    var categories: [SpendingCategory] {
        Dictionary(grouping: includedTransactions, by: \.category).map { SpendingCategory(category: $0.key, amount: centsTotal($0.value.map(\.amount))) }.sorted { $0.amount > $1.amount }
    }
}
private func centsTotal(_ values: [Double]) -> Double { Double(values.reduce(Int64(0)) { $0 + Int64(($1 * 100).rounded()) }) / 100 }
extension Dashboard {
    func statement(for account: BankAccount) -> CreditStatement? { statements?.first { $0.accountID == account.id } }
    var activeRecurring: [RecurringPayment] {
        let ids = Set(activeAccounts.map(\.id))
        return (recurring ?? []).filter { $0.active && ids.contains($0.accountID) && ["MATURE", "EARLY_DETECTION"].contains($0.status) }
            .sorted { ($0.nextDate ?? "9999", $0.merchant, $0.id) < ($1.nextDate ?? "9999", $1.merchant, $1.id) }
    }
    func spending(month: Date, accountIDs: Set<String>) -> MonthlySpending {
        SpendingIndex(dashboard: self).summary(month: month, accountIDs: accountIDs)
    }
}
