import Foundation

// Build once per dashboard snapshot. Month buckets avoid parsing and sorting the entire
// history every time SwiftUI reads a chart, category, label, or account filter.
struct SpendingIndex {
    private struct Bucket {
        let date: Date
        var transactions: [BankTransaction] = []
        var accountIDs: Set<String> = []
    }
    private var buckets: [String: Bucket] = [:]
    private let replaced: Set<String>
    init(dashboard: Dashboard) {
        let transactions = dashboard.sortedTransactions
        replaced = Set(transactions.filter { !$0.pending }.compactMap(\.pendingID))
        for transaction in transactions {
            let key = String(transaction.date.prefix(7))
            if buckets[key] == nil {
                guard let date = bankDay(key + "-01") else { continue }
                buckets[key] = Bucket(date: date)
            }
            guard transaction.date.utf8.count == 10, transaction.date.dropFirst(7).hasPrefix("-"),
                  let day = Int(transaction.date.suffix(2)), let bucket = buckets[key],
                  let days = Calendar.current.range(of: .day, in: .month, for: bucket.date), days.contains(day) else { continue }
            buckets[key]?.transactions.append(transaction)
            buckets[key]?.accountIDs.insert(transaction.accountID)
        }
    }
    func months(accountIDs: Set<String>, now: Date = .now) -> [Date] {
        let current = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
        let values = buckets.values.filter { !$0.accountIDs.isDisjoint(with: accountIDs) && $0.date <= current }.map(\.date)
        return Array(Set(values + [current])).sorted(by: >)
    }
    func summary(month: Date, accountIDs: Set<String>) -> MonthlySpending {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month], from: month)
        let start = calendar.date(from: parts)!
        let key = String(format: "%04d-%02d", parts.year!, parts.month!)
        let excluded: Set<String> = ["INCOME", "TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS"]
        let eligible = (buckets[key]?.transactions ?? []).filter {
            accountIDs.contains($0.accountID) && $0.currency == "USD" && !excluded.contains($0.category)
        }
        return MonthlySpending(month: start, transactions: eligible.filter { !$0.pending },
            pending: eligible.filter { $0.pending && !replaced.contains($0.id) })
    }
}
