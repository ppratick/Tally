import Foundation

@main enum RefreshTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(RefreshPolicy.interval(0) == 30)
        precondition(RefreshPolicy.interval(15) == 15)
        precondition(RefreshPolicy.interval(60) == 60)
        precondition(RefreshPolicy.isDue(lastSuccess: nil, pendingSince: nil, minutes: 30, now: now))
        for minutes in RefreshPolicy.intervals {
            let boundary = now.addingTimeInterval(-Double(minutes * 60))
            precondition(RefreshPolicy.isDue(lastSuccess: boundary, pendingSince: nil, minutes: minutes, now: now))
            precondition(!RefreshPolicy.isDue(lastSuccess: boundary.addingTimeInterval(1), pendingSince: nil, minutes: minutes, now: now))
        }
        // An accepted job may still be running; failed/abandoned jobs must not suppress the next refresh forever.
        precondition(!RefreshPolicy.isDue(lastSuccess: nil, pendingSince: now.addingTimeInterval(-30), minutes: 30, now: now))
        precondition(RefreshPolicy.isDue(lastSuccess: nil, pendingSince: now.addingTimeInterval(-180), minutes: 30, now: now))
        precondition(RefreshPolicy.isDue(lastSuccess: now.addingTimeInterval(60), pendingSince: nil, minutes: 30, now: now))
        func bank(_ id: String, checked: Date, balance: Date, error: String? = nil, archived: Bool = false) -> BankConnection {
            BankConnection(id: id, name: "Test", checkedAt: checked.ISO8601Format(), updatedAt: nil,
                           balanceUpdatedAt: balance.ISO8601Format(), error: error, importComplete: true, archived: archived)
        }
        let start = now.addingTimeInterval(-20), old = start.addingTimeInterval(-1)
        let fresh = bank("one", checked: now, balance: now)
        precondition(RefreshPolicy.completedAt(banks: [fresh], since: start) == now)
        precondition(RefreshPolicy.completedAt(banks: [], since: start) == nil)
        precondition(RefreshPolicy.completedAt(banks: [fresh, bank("two", checked: old, balance: now)], since: start) == nil)
        precondition(RefreshPolicy.completedAt(banks: [fresh, bank("two", checked: now, balance: old)], since: start) == nil)
        precondition(RefreshPolicy.completedAt(banks: [bank("one", checked: now, balance: now, error: "INSTITUTION_DOWN")], since: start) == nil)
        precondition(RefreshPolicy.completedAt(banks: [fresh, bank("archived", checked: old, balance: old, archived: true)], since: start) == now)
        print("Refresh policy passed: interval boundaries, defaults, pending recovery, clock changes, partial failures, stale balances, and archived banks.")
    }
}
