import SwiftUI
import Charts

private enum InsightsSection: String, CaseIterable {
    case spending = "Spending", balances = "Balances", bills = "Recurring"
}
struct InsightsView: View {
    @State private var section = InsightsSection.spending
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(InsightsSection.allCases, id: \.self) { item in
                    Button { withAnimation(.easeInOut(duration: 0.16)) { section = item } } label: {
                        Text(item.rawValue).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(section == item ? Color.primary : Color.secondary)
                            .background {
                                if section == item { RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)).shadow(color: .black.opacity(0.05), radius: 2, y: 1) }
                            }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }.padding(4).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
            switch section {
            case .balances: BalanceHistoryView(accountID: nil, embedded: true)
            case .spending: MonthlySpendingView()
            case .bills: RecurringPaymentsView()
            }
        }.background(Color.tallyCanvas)
    }
}
struct MonthlySpendingView: View {
    @Environment(TallyStore.self) private var store
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now))!
    @State private var selectedAccount = "all"
    private var ids: Set<String> { selectedAccount == "all" ? Set(store.dashboard.accounts.map(\.id)) : [selectedAccount] }
    var body: some View {
        let index = store.spendingIndex
        let accountIDs = ids
        let summary = index.summary(month: month, accountIDs: accountIDs)
        let months = index.months(accountIDs: accountIDs)
        let chartMonths = months.prefix(6).reversed().map { index.summary(month: $0, accountIDs: accountIDs) }
        let categories = summary.categories
        let categoryTotal = max(1, categories.filter { $0.amount > 0 }.map(\.amount).reduce(0, +))
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Menu {
                        Picker("Month", selection: $month) {
                            ForEach(months, id: \.self) { date in Text(date.formatted(.dateTime.month(.wide).year())).tag(date) }
                        }
                    } label: {
                        HStack(spacing: 7) { Text(month.formatted(.dateTime.month(.wide).year())); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
                    }.font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        Picker("Account", selection: $selectedAccount) {
                            Text("All accounts").tag("all")
                            ForEach(store.dashboard.accounts) { Text("\($0.shortBank) · \($0.mask)").tag($0.id) }
                        }
                    } label: {
                        Text(store.dashboard.accounts.first { $0.id == selectedAccount }.map { "\($0.shortBank) · \($0.mask)" } ?? "All accounts")
                            .font(.caption.weight(.medium)).lineLimit(1)
                    }
                }.padding(.horizontal, 3)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(Calendar.current.isDate(month, equalTo: .now, toGranularity: .month) ? "Spent this month" : "Monthly spending").font(.subheadline).foregroundStyle(.secondary)
                        Text(money(summary.total)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        if !summary.pending.isEmpty {
                            Text("\(money(summary.pendingTotal)) pending included").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if chartMonths.count > 1 {
                        Chart(chartMonths) { item in
                            BarMark(x: .value("Month", item.month, unit: .month), y: .value("Spent", item.total))
                                .foregroundStyle(Color.tallyAccent.opacity(Calendar.current.isDate(item.month, equalTo: month, toGranularity: .month) ? 1 : 0.25)).cornerRadius(4)
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .gesture(SpatialTapGesture().onEnded { tap in
                                        guard let anchor = proxy.plotFrame else { return }
                                        let plot = geometry[anchor]
                                        guard plot.contains(tap.location),
                                              let date: Date = proxy.value(atX: tap.location.x - plot.minX),
                                              let selected = chartMonths.first(where: { Calendar.current.isDate($0.month, equalTo: date, toGranularity: .month) }) else { return }
                                        withAnimation(.easeInOut(duration: 0.15)) { month = selected.month }
                                    })
                            }
                        }
                        .accessibilityActions {
                            ForEach(chartMonths) { item in
                                Button("Show \(item.month.formatted(.dateTime.month(.wide).year()))") { month = item.month }
                            }
                        }
                        .chartXAxis { AxisMarks(values: chartMonths.map(\.month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                            AxisValueLabel { if let amount = value.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))).font(.caption2) } }
                        } }.frame(height: 140)
                    }
                    Text("Based on saved transactions. Months may be partial.").font(.caption2).foregroundStyle(.secondary)
                }.padding(22).financeCard()
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "By category")
                    if categories.isEmpty {
                        ContentUnavailableView("No spending yet", systemImage: "chart.bar", description: Text("Purchases will appear here as your accounts update."))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(categories) { category in
                                NavigationLink {
                                    SpendingTransactionsView(title: category.name, transactions: summary.includedTransactions.filter { $0.category == category.category })
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Text(category.name).font(.subheadline)
                                            Spacer()
                                            Text(money(category.amount)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if category.amount > 0 { GeometryReader { proxy in
                                            Capsule().fill(Color.tallyAccent.opacity(0.1))
                                                .overlay(alignment: .leading) { Capsule().fill(Color.tallyAccent).frame(width: proxy.size.width * min(1, category.amount / categoryTotal)) }
                                        }.frame(height: 4) }
                                    }.padding(18).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if category.id != categories.last?.id { Divider().padding(.horizontal, 18) }
                            }
                        }.financeCard()
                    }
                }
                if !summary.includedTransactions.isEmpty {
                    NavigationLink { SpendingTransactionsView(title: month.formatted(.dateTime.month(.wide)), transactions: summary.includedTransactions) } label: {
                        HStack { Text("View spending transactions"); Spacer(); Image(systemName: "chevron.right").font(.caption) }.font(.subheadline.weight(.medium)).padding(18).financeCard()
                    }.buttonStyle(.plain)
                }
                Text("Purchases including pending, minus refunds. Transfers and loan/card payments are excluded. USD only.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                NavigationLink {
                    ChatView(context: "Monthly spending screen. Month: \(month.formatted(.iso8601.year().month())). Selected account ID: \(selectedAccount). USD spending includes pending, minus refunds, excluding transfers and card payments.", initialPrompt: "Explain my spending for \(month.formatted(.dateTime.month(.wide).year())).")
                } label: {
                    Label("Explain this spending", systemImage: "sparkles").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(18).financeCard()
                }.buttonStyle(.plain)
            }.padding(20)
        }.background(Color.tallyCanvas).navigationTitle("Insights").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton() } }
    }
}
private struct SpendingTransactionsView: View {
    let title: String
    let transactions: [BankTransaction]
    var body: some View {
        List {
            ForEach(transactions) { transaction in
                NavigationLink { TransactionDetailView(transaction: transaction) } label: { TransactionRow(transaction: transaction) }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
