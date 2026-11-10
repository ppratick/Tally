import Foundation

@main enum BalanceTests {
    static func account(_ id: String, current: Double?, available: Double?, credit: Bool = true, currency: String = "USD", limit: Double = 10000) -> BankAccount {
        BankAccount(id: id, bankID: id, bank: "Test Bank", name: "Test", mask: "0000", type: credit ? "credit" : "depository", current: current, available: available, limit: credit ? limit : nil, currency: currency)
    }
    static func entry(_ id: String, account: String, amount: Double, pending: Bool = true, pendingID: String? = nil, currency: String = "USD") -> BankTransaction {
        BankTransaction(id: id, accountID: account, merchant: "Test", amount: amount, currency: currency, date: "2026-11-10", pending: pending, category: "OTHER", pendingID: pendingID)
    }
    static func expect(_ actual: Double?, _ expected: Double) {
        precondition(actual != nil && abs(actual! - expected) < 0.000001, "Incorrect balance")
    }
    static func main() {
        let checking = account("checking", current: 4330.86, available: 4401.82, credit: false)
        let robinhood = account("robinhood", current: 923.39, available: 8898)
        let chase = account("chase", current: 227.10, available: 15369.61, limit: 15600)
        var d = Dashboard(accounts: [checking, robinhood, chase], transactions: [
            entry("r", account: "robinhood", amount: 178.65),
            entry("c1", account: "chase", amount: 3.29),
            entry("c2", account: "chase", amount: 2.79),
            entry("checkPending", account: "checking", amount: -70.96)
        ])
        expect(d.displayBalance(for: checking), 4401.82) // Don't apply checking pending activity twice.
        expect(d.displayBalance(for: robinhood), 1102.04)
        expect(d.displayBalance(for: chase), 233.18)
        expect(d.cash - d.debt, 3066.60)
        expect(d.availableAfterPending(for: robinhood), 8897.96)
        expect(d.availableAfterPending(for: chase), 15366.82)
        precondition(parseBankDate("2026-11-10T04:44:57.257Z") != nil)
        precondition(parseBankDate("2026-11-10T04:44:57Z") != nil)
        precondition(parseBankDate("invalid") == nil)
        let posted = (0..<8).map { entry("posted-\($0)", account: "chase", amount: 10, pending: false) }
        for count in [0, 3, 5, 7] {
            let pending = (0..<count).map { entry("pending-\($0)", account: "chase", amount: 1) }
            let recent = Dashboard(accounts: [chase], transactions: posted + pending).recentActivity()
            precondition(recent.count == max(5, count))
            precondition(recent.prefix(count).allSatisfy(\.pending))
            precondition(recent.filter(\.pending).count == count)
        }
        let mixed = Dashboard(accounts: [chase, robinhood], transactions: posted + [entry("other-bank-pending", account: "robinhood", amount: 1)])
        precondition(mixed.recentActivity(accountID: "chase").allSatisfy { $0.accountID == "chase" })
        precondition(mixed.recentActivity(accountID: "robinhood").count == 1)
        precondition(Dashboard().recentActivity().isEmpty)
        d.transactions.append(entry("refund", account: "robinhood", amount: -10))
        expect(d.displayBalance(for: robinhood), 1092.04)
        d.transactions.append(entry("posted", account: "chase", amount: 3.29, pending: false, pendingID: "c1"))
        expect(d.pendingTotal(for: chase), 2.79) // Matched posted replacement removes pending contribution.
        d.transactions.append(entry("otherCurrency", account: "chase", amount: 100, currency: "EUR"))
        expect(d.pendingTotal(for: chase), 2.79)
        let fallback = account("fallback", current: 100, available: nil, credit: false)
        expect(d.displayBalance(for: fallback), 100)
        precondition(d.balanceLabel(for: fallback) == "current")
        let unknown = account("unknown", current: nil, available: 50)
        precondition(d.displayBalance(for: unknown) == nil) // Missing current balance is not zero.
        let flowData = Dashboard(accounts: [chase, robinhood], transactions: [
            entry("incoming", account: "chase", amount: -15, pending: false),
            entry("outgoing", account: "chase", amount: 12),
            entry("zero", account: "chase", amount: 0, pending: false),
            entry("other-bank", account: "robinhood", amount: -20)
        ])
        let incoming = ActivityFilter(direction: .incoming).apply(to: flowData)
        precondition(Set(incoming.map(\.id)) == ["incoming", "other-bank"])
        let scoped = ActivityFilter(accountID: "chase", direction: .incoming).apply(to: flowData)
        precondition(scoped.count == 1 && scoped[0].id == "incoming")
        let outgoingPending = ActivityFilter(accountID: "chase", status: .pending, direction: .outgoing).apply(to: flowData)
        precondition(outgoingPending.count == 1 && outgoingPending[0].id == "outgoing")
        precondition(ActivityFilter(direction: .outgoing).apply(to: flowData).allSatisfy { $0.amount > 0 })
        precondition(ActivityFilter(status: .posted).apply(to: flowData).allSatisfy { !$0.pending })
        precondition(ActivityFilter().apply(to: flowData, search: "   TEST   ").count == 4)
        precondition(ActivityFilter(accountID: "chase").apply(to: flowData).allSatisfy { $0.accountID == "chase" })
        func point(_ id: String, day: String, current: Double, available: Double?, pending: Double = 0) -> BalancePoint {
            BalancePoint(accountID: id, day: day, observedAt: day + "T12:00:00Z", current: current, available: available, pending: pending, currency: "USD")
        }
        let historical = Dashboard(accounts: [checking, chase], history: [
            point("checking", day: "2026-11-09", current: 1000, available: 1000),
            point("chase", day: "2026-11-09", current: 200, available: 1000, pending: 5),
            point("checking", day: "2026-11-10", current: 1200, available: 1200)
        ])
        let trend = historical.balanceTrend(accountIDs: ["checking", "chase"], asNet: true)
        precondition(trend.count == 2)
        expect(trend[0].value, 795)
        expect(trend[1].value, 995)
        expect(historical.balanceTrend(accountIDs: ["chase"]).first?.value, 205)
        expect(historical.balanceTrend(accountIDs: ["chase"], asNet: true).first?.value, -205)
        var archived = checking; archived.archived = true
        let archivedData = Dashboard(accounts: [archived, chase], transactions: [entry("saved", account: "checking", amount: 20, pending: false)])
        precondition(archivedData.activeAccounts.count == 1 && archivedData.sortedTransactions.count == 1)
        precondition(archivedData.balanceTrend(accountIDs: ["checking"]).isEmpty)
        let due = CreditStatement(accountID: "chase", dueDate: "2026-12-01", minimumPayment: 25, statementBalance: 100, statementDate: "2026-11-08", overdue: false, updatedAt: "2026-11-10T12:00:00Z")
        precondition(due.daysUntilDue(now: bankDay("2026-11-10")!) == 21)
        precondition(due.daysUntilDue(now: bankDay("2026-12-01")!) == 0)
        precondition(due.daysUntilDue(now: bankDay("2026-12-02")!) == -1)
        precondition(bankDay("invalid") == nil)
        func expense(_ id: String, amount: Double, day: String = "2026-11-10", category: String = "FOOD_AND_DRINK", pending: Bool = false, pendingID: String? = nil, currency: String = "USD") -> BankTransaction {
            BankTransaction(id: id, accountID: "chase", merchant: "Test", amount: amount, currency: currency, date: day, pending: pending, category: category, pendingID: pendingID)
        }
        let spendingData = Dashboard(accounts: [chase], transactions: [
            expense("purchase", amount: 120), expense("refund", amount: -20),
            expense("payment", amount: 100, category: "LOAN_PAYMENTS"), expense("transfer", amount: 500, category: "TRANSFER_OUT"),
            expense("salary", amount: -2000, category: "INCOME"), expense("old", amount: 50, day: "2026-10-31"),
            expense("next", amount: 50, day: "2026-12-01"), expense("foreign", amount: 500, currency: "EUR"),
            expense("pending", amount: 10, pending: true), expense("replacement", amount: 12, pendingID: "pending"),
            expense("still-pending", amount: 7, pending: true)
        ])
        let spending = spendingData.spending(month: bankDay("2026-11-01")!, accountIDs: ["chase"])
        expect(spending.total, 119); expect(spending.pendingTotal, 7)
        precondition(spending.transactions.count == 3 && spending.pending.count == 1)
        expect(spending.categories.first?.amount, 119)
        precondition(spendingData.spending(month: bankDay("2026-11-01")!, accountIDs: []).transactions.isEmpty)
        var postedSpending = spendingData
        postedSpending.transactions.append(expense("posted-last", amount: 7, pendingID: "still-pending"))
        let settledSpending = postedSpending.spending(month: bankDay("2026-11-01")!, accountIDs: ["chase"])
        expect(settledSpending.total, 119); expect(settledSpending.pendingTotal, 0)
        let indexed = SpendingIndex(dashboard: spendingData)
        expect(indexed.summary(month: bankDay("2026-11-01")!, accountIDs: ["chase"]).total, 119)
        expect(indexed.summary(month: bankDay("2026-10-01")!, accountIDs: ["chase"]).total, 50)
        let invalidDate = Dashboard(accounts: [chase], transactions: [expense("invalid-day", amount: 999, day: "2026-11-99")])
        expect(invalidDate.spending(month: bankDay("2026-11-01")!, accountIDs: ["chase"]).total, 0)
        let weekly = RecurringPayment(id: "weekly", accountID: "chase", merchant: "Gym", direction: "outgoing", category: "PERSONAL_CARE", frequency: "WEEKLY", nextDate: nil, lastDate: "2026-11-01", averageAmount: 12, lastAmount: 12, currency: "USD", active: true, status: "MATURE", transactionIDs: [])
        expect(weekly.monthlyEstimate, 52)
        let unknownSchedule = RecurringPayment(id: "unknown", accountID: "chase", merchant: "Transfer", direction: "outgoing", category: "LOAN_PAYMENTS", frequency: "UNKNOWN", nextDate: nil, lastDate: "2026-11-01", averageAmount: nil, lastAmount: nil, currency: "USD", active: true, status: "MATURE", transactionIDs: [])
        precondition(!unknownSchedule.isBill && unknownSchedule.monthlyEstimate == nil)
        print("Payment and spending tests passed: due dates, net refunds, excluded transfers/card payments/income, month boundaries, foreign currencies, pending replacements and recurring normalization.")
        print("Balance and activity tests passed: credit availability, fractional timestamps, 0/3/5/7 pending lists, incoming/outgoing and status filters, per-account isolation, search, archived history preservation, daily history and carried balances, credits, posted replacements, and missing values.")
    }
}
