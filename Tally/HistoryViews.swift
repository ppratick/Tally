import SwiftUI
import Charts

struct BalanceHistoryView: View {
    @Environment(TallyStore.self) private var store
    let accountID: String?
    var embedded = false
    @State private var selectedAccount = "all"
    @State private var range = 30
    @State private var selectedDate: Date?
    private var ids: Set<String> {
        if let accountID { return [accountID] }
        if selectedAccount != "all" { return [selectedAccount] }
        return Set(store.homeAccounts.map(\.id))
    }
    private var account: BankAccount? { ids.count == 1 ? store.dashboard.accounts.first { ids.contains($0.id) } : nil }
    private var points: [BalanceTrendPoint] {
        let since = range == 0 ? nil : Calendar.current.date(byAdding: .day, value: -(range - 1), to: Calendar.current.startOfDay(for: .now))
        return store.dashboard.balanceTrend(accountIDs: ids, since: since, asNet: accountID == nil && selectedAccount == "all")
    }
    private var highlighted: BalanceTrendPoint? {
        if let selectedDate { return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) } }
        return points.last
    }
    private var title: String { account.map { store.accountName($0) } ?? "Net balance" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Menu {
                        Picker("Period", selection: $range) {
                            Text("Last 7 days").tag(7); Text("Last 30 days").tag(30)
                            Text("Last 90 days").tag(90); Text("All time").tag(0)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(range == 0 ? "All time" : "Last \(range) days")
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                    }.font(.subheadline.weight(.semibold))
                    Spacer()
                    if accountID == nil {
                        Menu {
                            Picker("Account", selection: $selectedAccount) {
                                Text("Net balance").tag("all")
                                ForEach(store.dashboard.accounts) { Text("\($0.shortBank) · \($0.mask)\($0.archived == true ? " · disconnected" : "")").tag($0.id) }
                            }
                        } label: {
                            Text(selectedAccount == "all" ? "Net balance" : account.map { "\($0.shortBank) · \($0.mask)" } ?? "Net balance")
                                .font(.caption.weight(.medium)).lineLimit(1)
                        }
                    }
                }.padding(.horizontal, 3)
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(highlighted?.value)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        if let point = highlighted { Text(point.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if points.isEmpty {
                        ContentUnavailableView("History starts here", systemImage: "chart.xyaxis.line", description: Text("Refresh your accounts to save the first daily balance snapshot."))
                    } else {
                        Chart(points) { point in
                            LineMark(x: .value("Day", point.date), y: .value("Balance", point.value)).foregroundStyle(Color.tallyAccent).lineStyle(StrokeStyle(lineWidth: 2.5))
                            PointMark(x: .value("Day", point.date), y: .value("Balance", point.value)).foregroundStyle(Color.tallyAccent).symbolSize(points.count == 1 ? 65 : 12)
                            if let selectedDate, point.id == highlighted?.id {
                                RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary.opacity(0.25))
                            }
                        }
                        .chartXSelection(value: $selectedDate)
                        .chartYScale(domain: chartDomain)
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                            AxisValueLabel { if let number = value.as(Double.self) { Text(number.formatted(.number.notation(.compactName))).font(.caption2) } }
                        } }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                        .frame(height: 235)
                    }
                    Text(points.isEmpty ? "Daily snapshots will appear after your first refresh." : points.count < 2 ? "Your first observation is saved. A trend will appear as more daily balances are collected." : "Daily observed balances. Press and slide on the chart to inspect a date.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22).tallyHistoryCard()
            }.padding(20)
        }
        .background(Color.tallyCanvas).navigationTitle(embedded ? "Insights" : "Balance history").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton() } }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .onChange(of: selectedAccount) { _, _ in selectedDate = nil }
    }
    private var chartDomain: ClosedRange<Double> {
        let low = points.map(\.value).min() ?? 0, high = points.map(\.value).max() ?? 0
        let padding = max((high - low) * 0.2, max(abs(high) * 0.02, 1))
        return (low - padding)...(high + padding)
    }
}
private extension View {
    func tallyHistoryCard() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.035), lineWidth: 0.5) }
    }
}
