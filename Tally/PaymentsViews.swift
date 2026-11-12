import SwiftUI

struct CreditPaymentSummary: View {
    @Environment(TallyStore.self) private var store
    let account: BankAccount
    @State private var showExplanation = false
    private var statement: CreditStatement? { store.dashboard.statement(for: account) }
    private var bank: BankConnection? { store.dashboard.banks.first { $0.id == account.bankID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Next payment").font(.subheadline.weight(.semibold))
                    Text(statement?.dueLabel ?? "Payment details unavailable").font(.caption)
                        .foregroundStyle(statement?.overdue == true ? Color.orange : .secondary)
                }
                Spacer()
                if let due = bankDay(statement?.dueDate) { Text(due.formatted(.dateTime.month(.abbreviated).day())).font(.subheadline.weight(.medium)) }
                Button { showExplanation = true } label: { Image(systemName: "info.circle").font(.subheadline) }.accessibilityLabel("About statement balances")
            }
            HStack(alignment: .top, spacing: 12) {
                metric("Statement balance", value: statement?.statementBalance)
                metric("Minimum payment", value: statement?.minimumPayment)
            }
            if let date = bankDay(statement?.statementDate) { Text("Statement issued \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary) }
            if bank?.liabilityError != nil { PaymentDataNotice(bank: bank, kind: .statement) }
        }
        .alert("Statement balance", isPresented: $showExplanation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This is the balance when the statement was issued, not the remaining amount to pay. Payments made since then may already cover part or all of it. Check your bank's remaining statement balance before paying. Total balance also includes newer and pending activity.")
        }
    }
    private func metric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(money(value, currency: account.currency)).font(.system(.headline, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private enum PaymentDataKind { case statement, recurring }
private struct PaymentDataNotice: View {
    @Environment(TallyStore.self) private var store
    let bank: BankConnection?
    let kind: PaymentDataKind
    private var code: String? { kind == .statement ? bank?.liabilityError : bank?.recurringError }
    var body: some View {
        if let bank, let code {
            VStack(alignment: .leading, spacing: 8) {
                Text(message(code)).font(.caption).foregroundStyle(.secondary)
                if ["ADDITIONAL_CONSENT_REQUIRED", "ACCESS_NOT_GRANTED", "ITEM_LOGIN_REQUIRED"].contains(code) {
                    Button("Review bank permissions") { Task { await store.reconnect(bank) } }.font(.caption.weight(.medium)).disabled(store.busy)
                } else if !["INVALID_PRODUCT", "PRODUCT_NOT_SUPPORTED", "INSTITUTION_NOT_SUPPORTED"].contains(code) {
                    Button("Refresh accounts") { Task { await store.refreshManually() } }.font(.caption.weight(.medium)).disabled(store.busy)
                }
            }
        }
    }
    private func message(_ code: String) -> String {
        switch code {
        case "ADDITIONAL_CONSENT_REQUIRED", "ACCESS_NOT_GRANTED": "\(bank?.name ?? "Your bank") needs permission to share these details."
        case "ITEM_LOGIN_REQUIRED": "Sign in again to update these details."
        case "PRODUCT_NOT_READY": "Your bank is still preparing these details."
        case "INVALID_PRODUCT", "PRODUCT_NOT_SUPPORTED", "INSTITUTION_NOT_SUPPORTED": "These details aren't available for \(bank?.name ?? "this bank")."
        default: "\(bank?.name ?? "Your bank") couldn't update these details. Any saved information is still shown."
        }
    }
}
struct RecurringPaymentsView: View {
    @Environment(TallyStore.self) private var store
    private var streams: [RecurringPayment] { store.dashboard.activeRecurring.filter(\.isBill) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recurring bills").font(.title2.weight(.semibold))
                    Text("\(streams.count) active \(streams.count == 1 ? "bill" : "bills") · Original billing schedules")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
                if streams.isEmpty {
                    ContentUnavailableView("No recurring bills detected", systemImage: "repeat", description: Text("Patterns appear as your bank provides more transaction history."))
                } else {
                    ForEach(streams) { stream in
                        NavigationLink { RecurringDetailView(stream: stream) } label: { RecurringRow(stream: stream) }.buttonStyle(.plain)
                    }
                }
                ForEach(store.dashboard.banks.filter { $0.archived != true && $0.recurringError != nil }) { bank in
                    PaymentDataNotice(bank: bank, kind: .recurring).padding(18).financeCard()
                }
                Text("Amounts and next dates are estimates, not scheduled payments. Transfers and credit card payments are excluded from bills.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }.padding(20)
        }.background(Color.tallyCanvas).navigationTitle("Insights").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton() } }
    }
}
private struct RecurringRow: View {
    @Environment(TallyStore.self) private var store
    let stream: RecurringPayment
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "repeat").font(.subheadline).foregroundStyle(Color.tallyAccent).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(stream.merchant).font(.subheadline.weight(.semibold))
                Text(stream.frequencyLabel + (stream.status == "EARLY_DETECTION" ? " · New pattern" : "")).font(.caption).foregroundStyle(.secondary)
                if let account = store.dashboard.accounts.first(where: { $0.id == stream.accountID }) { Text("\(account.shortBank) · \(account.mask)").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(money((stream.lastAmount ?? stream.averageAmount).map(abs), currency: stream.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let date = bankDay(stream.nextDate) { Text("Est. \(date.formatted(.dateTime.month(.abbreviated).day()))").font(.caption2).foregroundStyle(.secondary) }
                else { Text("Next date unknown").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(18).financeCard()
    }
}
private struct RecurringDetailView: View {
    @Environment(TallyStore.self) private var store
    let stream: RecurringPayment
    private var transactions: [BankTransaction] { store.dashboard.sortedTransactions.filter { stream.transactionIDs.contains($0.id) && $0.accountID == stream.accountID && !$0.pending } }
    var body: some View {
        List {
            Section {
                LabeledContent("Schedule", value: stream.frequencyLabel)
                LabeledContent("Last amount", value: money(stream.lastAmount.map(abs), currency: stream.currency))
                LabeledContent("Average amount", value: money(stream.averageAmount.map(abs), currency: stream.currency))
                if let date = bankDay(stream.nextDate) { LabeledContent("Estimated next date", value: date.formatted(date: .abbreviated, time: .omitted)) }
            }
            Section("Matched transactions") {
                if transactions.isEmpty { Text("No matched transactions in saved history.").foregroundStyle(.secondary) }
                ForEach(transactions) { transaction in
                    NavigationLink { TransactionDetailView(transaction: transaction) } label: { TransactionRow(transaction: transaction, showsAccount: false) }
                }
            }
        }.navigationTitle(stream.merchant).navigationBarTitleDisplayMode(.inline)
        .tallyTopFade()
    }
}
extension View {
    func financeCard() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.035), lineWidth: 0.5) }
    }
}
