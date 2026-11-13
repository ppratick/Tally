import SwiftUI

struct CardPaymentTrackingSection: View {
    @Environment(TallyStore.self) private var store
    let transaction: BankTransaction
    @State private var saving = false
    @State private var failure: String?
    @State private var choosingWithdrawal = false
    private var tracking: CardPaymentTracking? {
        store.dashboard.paymentTracking?.first { $0.transactionID == transaction.id || $0.transactionID == transaction.pendingID }
    }
    private var sources: [BankAccount] {
        store.dashboard.activeAccounts.filter { $0.type == "depository" && $0.currency == transaction.currency }
    }
    var body: some View {
        Section {
            if let tracking {
                if let source = store.dashboard.accounts.first(where: { $0.id == tracking.sourceAccountID }) {
                    LabeledContent("Paid from", value: "\(source.shortBank) · \(store.accountName(source)) · \(source.mask)")
                }
                Label(status(tracking), systemImage: tracking.status == "complete" ? "checkmark.circle" : "clock")
                if tracking.reservedAmount > 0 {
                    Text("\(money(tracking.reservedAmount, currency: tracking.currency)) is reserved from this account’s spendable balance until its withdrawal appears.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if tracking.status == "pending" {
                    Text("The pending withdrawal is already included in the bank’s available balance. No extra reserve is applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !tracking.candidateIDs.isEmpty && tracking.status != "complete" {
                    Button("Match a withdrawal…") { choosingWithdrawal = true }
                }
            }
            Menu(tracking == nil ? "Select the account you paid from" : "Change source account") {
                ForEach(sources) { account in
                    Button("\(account.shortBank) · \(store.accountName(account)) · \(account.mask)") { save(source: account.id) }
                }
            }.disabled(saving || store.busy || sources.isEmpty)
            if sources.isEmpty { Text("Connect a checking or savings account in this currency to track this payment.").font(.caption).foregroundStyle(.secondary) }
            if tracking != nil {
                Button("Remove payment link", role: .destructive) { save(source: nil) }.disabled(saving || store.busy)
            }
            if saving { ProgressView("Saving payment…") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } header: { Text("Card payment") } footer: {
            Text("Link this received payment to the account it came from. Tally watches for a matching withdrawal; this does not move money.")
        }
        .sheet(isPresented: $choosingWithdrawal) {
            NavigationStack {
                List {
                    ForEach(store.dashboard.sortedTransactions.filter { tracking?.candidateIDs.contains($0.id) == true }) { withdrawal in
                        Button {
                            choosingWithdrawal = false
                            save(source: tracking?.sourceAccountID, match: withdrawal.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(withdrawal.merchant)
                                Text("\(withdrawal.date) · \(money(withdrawal.amount, currency: withdrawal.currency))" + (withdrawal.pending ? " · Pending" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.navigationTitle("Match withdrawal")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingWithdrawal = false } } }
            }
        }
    }
    private func status(_ payment: CardPaymentTracking) -> String {
        switch payment.status {
        case "complete": "Withdrawal matched"
        case "pending": payment.reservedAmount > 0 ? "Withdrawal pending · reserve retained" : "Withdrawal pending · no extra reserve"
        case "review": "Payment needs review"
        default: "Waiting for withdrawal"
        }
    }
    private func save(source: String?, match: String? = nil) {
        saving = true; failure = nil
        Task {
            if !(await store.trackCardPayment(transaction, sourceAccountID: source, matchedTransactionID: match)) {
                failure = "Couldn’t save this link. Refresh and try again."
            }
            saving = false
        }
    }
}
