import Foundation

enum RefreshPolicy {
    static let intervals = [15, 30, 60]
    static func interval(_ minutes: Int) -> Int { intervals.contains(minutes) ? minutes : 30 }

}

struct BankAccount: Codable, Identifiable, Hashable {
    let id: String
    let bankID: String
    let bank: String
    let name: String
    let mask: String
    let type: String
    let current: Double?
    let available: Double?
    let limit: Double?
    let currency: String
    var archived: Bool? = nil
    var logo: String? = nil
    var isCredit: Bool { type == "credit" }
    var displayName: String {
        if bank.localizedCaseInsensitiveContains("Robinhood") && isCredit { return "Gold Card" }
        if bank.localizedCaseInsensitiveContains("Chase") { return "Credit Card" }
        return name
    }
    var shortBank: String {
        if bank.localizedCaseInsensitiveContains("America") { return "Bank of America" }
        return bank
    }

}
struct BankTransaction: Codable, Identifiable, Hashable {
    let id: String
    let accountID: String
    let merchant: String
    let amount: Double
    let currency: String
    let date: String
    let pending: Bool
    let category: String
    let pendingID: String?
    var categoryName: String { category.replacingOccurrences(of: "_", with: " ").capitalized }
    var dateValue: Date { bankDay(date) ?? .distantPast }
    var symbol: String {
        switch category {
        case "FOOD_AND_DRINK": return "fork.knife"
        case "TRANSPORTATION", "TRAVEL": return "car.fill"
        case "GENERAL_MERCHANDISE", "GENERAL_SERVICES": return "bag.fill"
        case "ENTERTAINMENT": return "play.fill"
        case "LOAN_PAYMENTS", "TRANSFER_IN", "TRANSFER_OUT": return "arrow.left.arrow.right"
        case "INCOME": return "arrow.down.left"
        case "RENT_AND_UTILITIES": return "house.fill"
        case "MEDICAL", "PERSONAL_CARE": return "heart.fill"
        default: return amount < 0 ? "arrow.down.left" : "creditcard.fill"
        }
    }
}
struct BankConnection: Codable, Identifiable {
    let id: String
    let name: String
    let checkedAt: String?
    let updatedAt: String?
    let balanceUpdatedAt: String?
    let error: String?
    let importComplete: Bool
    var archived: Bool? = nil
    var syncPending: Bool? = nil
    var liabilityError: String? = nil
    var liabilityUpdatedAt: String? = nil
    var recurringError: String? = nil
    var recurringUpdatedAt: String? = nil
    var updateDate: Date? { parseBankDate(updatedAt) }
    var balanceDate: Date? { parseBankDate(balanceUpdatedAt) }
    var checkDate: Date? { parseBankDate(checkedAt) }
    var needsAttention: Bool { error != nil || !importComplete || syncPending == true }
    var statusText: String {
        switch error {
        case "ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION": return "Sign in again to reconnect this bank."
        case "PRODUCT_NOT_READY": return "Your bank is still preparing transaction history. Sync again shortly."
        case .some: return "This bank couldn't update. Your last saved data is still available."
        case nil: return syncPending == true ? "Update queued. Saved data is shown until it finishes." : importComplete ? "Connected" : "Importing transaction history"
        }
    }
}
struct CardPaymentTracking: Codable, Identifiable {
    let transactionID: String
    let sourceAccountID: String
    let cardAccountID: String
    let amount: Double
    let currency: String
    let date: String
    let matchedTransactionID: String?
    let status: String
    let reservedAmount: Double
    let candidateIDs: [String]
    var id: String { transactionID }
}
struct Dashboard: Codable {
    var accounts: [BankAccount] = []
    var transactions: [BankTransaction] = []
    var banks: [BankConnection] = []
    var history: [BalancePoint]? = nil
    var automaticRefreshMinutes: Int? = nil
    var lastFullRefreshAt: String? = nil
    var pendingLinkID: String? = nil
    var statements: [CreditStatement]? = nil
    var recurring: [RecurringPayment]? = nil
    var paymentTracking: [CardPaymentTracking]? = nil
    var activeAccounts: [BankAccount] { accounts.filter { $0.archived != true } }
    var sortedTransactions: [BankTransaction] {
        let accountIDs = Set(accounts.map(\.id))
        return transactions.filter { accountIDs.contains($0.accountID) }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }
    var cash: Double { sumMoney(activeAccounts.filter { !$0.isCredit && $0.currency == "USD" }.compactMap { displayBalance(for: $0) }) }
    var debt: Double { sumMoney(activeAccounts.filter { $0.isCredit && $0.currency == "USD" }.compactMap { displayBalance(for: $0) }) }
    var pending: [BankTransaction] {
        // A matched posted replacement must not be counted as pending a second time.
        let entries = sortedTransactions
        let postedReplacements = Set(entries.filter { !$0.pending }.compactMap(\.pendingID))
        return entries.filter { $0.pending && !postedReplacements.contains($0.id) }
    }
    func displayBalance(for account: BankAccount) -> Double? {
        if account.isCredit {
            guard let current = account.current else { return nil }
            return sumMoney([current, pendingTotal(for: account)])
        }
        // Available already reflects the bank's pending activity: never add it again.
        return (account.available ?? account.current).map { sumMoney([$0, -paymentReserve(for: account)]) }
    }
    func paymentReserve(for account: BankAccount) -> Double {
        sumMoney((paymentTracking ?? []).filter { $0.sourceAccountID == account.id && $0.currency == account.currency }.map(\.reservedAmount))
    }
    func isCardPayment(_ transaction: BankTransaction) -> Bool {
        guard transaction.amount < 0, accounts.contains(where: { $0.id == transaction.accountID && $0.isCredit && $0.archived != true }) else { return false }
        return ["LOAN_PAYMENTS", "TRANSFER_IN", "TRANSFER_OUT"].contains(transaction.category) ||
            transaction.merchant.range(of: #"\bpayment\b|autopay|auto pay"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    func recentActivity(accountID: String? = nil, minimumCount: Int = 5) -> [BankTransaction] {
        let entries = sortedTransactions
        let replacements = Set(entries.filter { !$0.pending }.compactMap(\.pendingID))
        let pendingEntries = entries.filter { $0.pending && !replacements.contains($0.id) && (accountID == nil || $0.accountID == accountID) }
        let posted = entries.lazy.filter { !$0.pending && (accountID == nil || $0.accountID == accountID) }
        return pendingEntries + posted.prefix(max(0, minimumCount - pendingEntries.count))
    }
    func availableAfterPending(for account: BankAccount) -> Double? {
        guard account.isCredit, let limit = account.limit, let total = displayBalance(for: account) else { return nil }
        return sumMoney([limit, -total])
    }
    func utilization(for account: BankAccount) -> Double? {
        guard let limit = account.limit, limit > 0, let total = displayBalance(for: account) else { return nil }
        return max(0, total / limit)
    }
    func balanceLabel(for account: BankAccount) -> String {
        account.isCredit ? "incl. pending" : (paymentReserve(for: account) > 0 ? "after payments" : (account.available == nil ? "current" : "available"))
    }
    func pendingTotal(for account: BankAccount) -> Double {
        let accountIDs = Set(accounts.map(\.id))
        let entries = transactions.filter { accountIDs.contains($0.accountID) }
        let replacements = Set(entries.filter { !$0.pending }.compactMap(\.pendingID))
        return sumMoney(entries.filter { $0.pending && !replacements.contains($0.id) && $0.accountID == account.id && $0.currency == account.currency }.map(\.amount))
    }
}
private func sumMoney(_ values: [Double]) -> Double {
    let total = values.reduce(Decimal.zero) { $0 + (Decimal(string: String($1), locale: Locale(identifier: "en_US_POSIX")) ?? .zero) }
    return NSDecimalNumber(decimal: total).doubleValue
}
func money(_ value: Double?, currency: String = "USD") -> String {
    guard let value else { return "—" }
    return value.formatted(.currency(code: currency))
}

func parseBankDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? BankTimestampParser.fractional.parse(value)) ?? (try? BankTimestampParser.whole.parse(value))
}
private enum BankTimestampParser {
    static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let whole = Date.ISO8601FormatStyle()
}

enum ActivityStatus: String, CaseIterable {
    case all, pending, posted
    var label: String {
        switch self { case .all: "All statuses"; case .pending: "Pending"; case .posted: "Posted" }
    }
}
enum ActivityDirection: String, CaseIterable {
    case all, incoming, outgoing
    var label: String {
        switch self { case .all: "All activity"; case .incoming: "Incoming"; case .outgoing: "Outgoing" }
    }
}
struct ActivityFilter {
    var accountID: String? = nil
    var status: ActivityStatus = .all
    var direction: ActivityDirection = .all
    func apply(to dashboard: Dashboard, search: String = "") -> [BankTransaction] {
        let entries = dashboard.sortedTransactions
        let replacements = Set(entries.filter { !$0.pending }.compactMap(\.pendingID))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { transaction in
            (!transaction.pending || !replacements.contains(transaction.id)) &&
            (accountID == nil || transaction.accountID == accountID) &&
            (status == .all || (status == .pending ? transaction.pending : !transaction.pending)) &&
            (direction == .all || (direction == .incoming ? transaction.amount < 0 : transaction.amount > 0)) &&
            (query.isEmpty || transaction.merchant.localizedCaseInsensitiveContains(query) || transaction.categoryName.localizedCaseInsensitiveContains(query))
        }
    }
}

struct BalancePoint: Codable, Identifiable {
    let accountID: String
    let day: String
    let observedAt: String
    let current: Double?
    let available: Double?
    let pending: Double
    let currency: String
    var id: String { accountID + day }
    var date: Date {
        bankDay(day) ?? .distantPast
    }
    func balance(isCredit:Bool) -> Double? {
        if isCredit { return current.map { sumMoney([$0,pending]) } }
        return available ?? current
    }
}
struct BalanceTrendPoint: Identifiable {
    let day: String
    let date: Date
    let value: Double
    var id: String { day }
}
extension Dashboard {
    func balanceTrend(accountIDs:Set<String>,since:Date?=nil,asNet:Bool=false) -> [BalanceTrendPoint] {
        let selected=accounts.filter { accountIDs.contains($0.id)&&$0.currency=="USD" }
        guard !selected.isEmpty else{return []}
        let points=(history ?? []).filter { accountIDs.contains($0.accountID)&&$0.currency=="USD" }
        let days=Dictionary(grouping:points,by:\.day).sorted { $0.key < $1.key }
        var latest:[String:BalancePoint]=[:],result:[BalanceTrendPoint]=[]
        for (day,updates) in days {
            for point in updates { latest[point.accountID]=point }
            guard selected.allSatisfy({latest[$0.id] != nil}),let date=updates.first?.date else{continue}
            var values:[Double]=[]
            var valid=true
            for account in selected {
                guard let value=latest[account.id]?.balance(isCredit:account.isCredit) else{valid=false;break}
                values.append(!asNet && selected.count==1 ? value : (account.isCredit ? -value : value))
            }
            if valid && (since == nil || date >= since!) {result.append(BalanceTrendPoint(day:day,date:date,value:sumMoney(values)))}
        }
        return result
    }
}
