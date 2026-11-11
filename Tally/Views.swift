import SwiftUI
import SafariServices
import UniformTypeIdentifiers
import Charts

struct RootView: View {
    @Environment(TallyStore.self) private var store
    var body: some View {
        Group {
            if !store.unlocked { UnlockView() }
            else if !store.configured { SetupView() }
            else {
                TabView(selection: Binding(get: { store.selectedTab }, set: { store.selectedTab = $0 })) {
                    Tab("Home", systemImage: "square.grid.2x2.fill", value: 0) { NavigationStack { HomeView() } }
                    Tab("Insights", systemImage: "chart.xyaxis.line", value: 2) { NavigationStack { InsightsView() } }
                    Tab("Ask Tally", systemImage: "bubble.left.and.bubble.right", value: 3) { NavigationStack { ChatView() } }
                    Tab("Accounts", systemImage: "creditcard", value: 1) { NavigationStack { AccountsView() } }
                }
            }
        }
        .sheet(isPresented: Binding(get: { store.reconnectURL != nil }, set: { if !$0 { store.reconnectURL = nil } }), onDismiss: { Task { await store.browserDismissed() } }) {
            if let url = store.reconnectURL { BankSignIn(url: url).ignoresSafeArea() }
        }
        .task { if !store.unlocked { await store.authenticate() } }
    }
}
struct UnlockView: View {
    @Environment(TallyStore.self) private var store
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "leaf.fill").font(.system(size: 54)).foregroundStyle(Color.tallyAccent).padding(28).background(Color.tallyAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 32))
            Text("Tally").font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Your money, in view.").foregroundStyle(.secondary)
            Spacer()
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Button { Task { await store.authenticate() } } label: { Label("Unlock Tally", systemImage: "faceid").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.authenticating)
        }.padding(32).background(Color.tallyCanvas)
    }
}
struct SetupView: View {
    var canDismiss = false
    @Environment(\.dismiss) private var dismiss
    @Environment(TallyStore.self) private var store
    @State private var url = ""
    @State private var token = ""
    @State private var connecting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.fill").font(.largeTitle).foregroundStyle(Color.tallyAccent)
                        Text("A clearer view of your money.").font(.title2.bold())
                        Text("Connect Tally to your private server. Your bank credentials stay securely on the server.").foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("Private connection") {
                    TextField("https://your-worker.workers.dev", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Access key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error = store.error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
                Section {
                    Button { connecting = true; Task { let connected = await store.configure(url: url, token: token); connecting = false; if connected && canDismiss { dismiss() } } } label: { HStack { Text("Connect securely"); Spacer(); if connecting { ProgressView() } else { Image(systemName: "arrow.right") } } }.disabled(connecting || url.isEmpty || token.isEmpty)
                }
                Section { Text("Your access key is stored in this iPhone’s Keychain. Tally doesn't need your bank password.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Welcome to Tally").toolbar { if canDismiss { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } } }
        }
    }
}
// Shared visual rhythm keeps every screen quiet and consistent.
private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.035), lineWidth: 0.5) }
    }
}
private extension View {
    func tallyCard() -> some View { modifier(CardSurface()) }
}
struct RefreshButton: View {
    @Environment(TallyStore.self) private var store
    var body: some View {
        Button { Task { await store.refreshManually() } } label: {
            Group {
                if store.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").fontWeight(.medium) }
            }.frame(width: 26, height: 26)
        }.disabled(store.busy).accessibilityLabel("Refresh accounts")
    }
}
struct HomeView: View {
    @Environment(TallyStore.self) private var store
    @State private var showSettings = false
    private var accounts: [BankAccount] {
        store.homeAccounts
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                overview
                if let refreshed = store.lastFullRefreshAt {
                    Text("Last refreshed \(refreshed, style: .relative) ago")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, -12)
                }
                if store.error != nil || store.busy || store.isOffline || store.dashboard.banks.contains(where: { $0.error != nil }) {
                    StatusBanner()
                }
                if accounts.isEmpty {
                    ContentUnavailableView("Your accounts are on their way", systemImage: "creditcard", description: Text("Refresh to load your connected accounts."))
                    Button("Refresh accounts") { Task { await store.refreshManually() } }.buttonStyle(.borderedProminent).disabled(store.busy)
                } else {
                    VStack(spacing: 12) {
                        SectionHeading(title: "Your accounts")
                        VStack(spacing: 12) {
                            ForEach(accounts) { account in
                                NavigationLink { AccountDetailView(accountID: account.id) } label: {
                                    AccountRow(account: account).financeCard()
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    VStack(spacing: 12) {
                        SectionHeading(title: "Recent activity")
                        ActivityCard(transactions: store.homeDashboard.recentActivity()) {
                            TransactionsView()
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
        }
        .background(Color.tallyCanvas).navigationTitle("Tally")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { RefreshButton() }
            ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Net balance").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("USD").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.white.opacity(0.7))
            }
            Text(money(accounts.isEmpty ? nil : store.homeDashboard.cash - store.homeDashboard.debt))
                .font(.system(size: 42, weight: .semibold, design: .rounded)).tracking(-1.5)
                .minimumScaleFactor(0.6).lineLimit(1).monospacedDigit().contentTransition(.numericText())
            HStack(alignment: .top) {
                summary("Available cash", value: accounts.isEmpty ? nil : store.homeDashboard.cash)
                Spacer()
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 38).padding(.horizontal, 14)
                summary("Cards incl. pending", value: accounts.isEmpty ? nil : store.homeDashboard.debt)
            }
        }
        .padding(22).foregroundStyle(.white)
        .background(LinearGradient(colors: TallyTheme.gradient, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
    }
    private func summary(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
            Text(money(value)).font(.system(.headline, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct StatusBanner: View {
    @Environment(TallyStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Retry") { Task { await store.refreshManually() } }.disabled(store.busy)
                }.font(.caption)
            } else if store.busy {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Refreshing your accounts…") }.font(.caption).foregroundStyle(.secondary)
            } else if store.isOffline {
                Label("Offline · showing saved data", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            }
            if store.dashboard.banks.contains(where: { $0.error != nil }) {
                Label("A bank needs attention in Accounts", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 3)
    }
}
struct SectionHeading: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            Spacer()
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 3)
    }
}
struct BankMark: View {
    let account: BankAccount
    var size: CGFloat = 48
    var asset: String? {
        if account.bank.localizedCaseInsensitiveContains("Robinhood") { return "Robinhood" }
        if account.bank.localizedCaseInsensitiveContains("Chase") { return "Chase" }
        if account.bank.localizedCaseInsensitiveContains("America") { return "BankOfAmerica" }
        return nil
    }
    var body: some View {
        Group {
            if let asset { Image(asset).resizable().scaledToFit().padding(size * 0.06) }
            else if let logo = account.logo, let data = Data(base64Encoded: logo), let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().padding(size * 0.06) }
            else { Text(String(account.bank.prefix(1))).font(.headline).foregroundStyle(Color.tallyAccent) }
        }.frame(width: size, height: size).accessibilityLabel(account.shortBank)
    }
}
struct AccountRow: View {
    @Environment(TallyStore.self) private var store
    let account: BankAccount
    private var statement: CreditStatement? { store.dashboard.statement(for: account) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BankMark(account: account)
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.shortBank).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    Text("\(store.accountName(account)) · \(account.mask)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(money(store.dashboard.displayBalance(for: account), currency: account.currency)).font(.system(.headline, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    Text(store.dashboard.balanceLabel(for: account)).font(.caption2).foregroundStyle(.secondary)
                }.layoutPriority(1)
            }
            if account.isCredit {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let statement {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Statement · \(money(statement.statementBalance, currency: account.currency))").font(.caption.weight(.medium))
                            HStack(spacing: 5) {
                                if let date = bankDay(statement.dueDate) { Text(date.formatted(.dateTime.month(.abbreviated).day())); Text("·") }
                                Text(statement.dueLabel)
                            }.font(.caption2).foregroundStyle(statement.overdue == true ? Color.orange : .secondary)
                        }
                    } else { Text("Statement details unavailable").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if let utilization = store.dashboard.utilization(for: account) {
                        Text("\(utilization.formatted(.percent.precision(.fractionLength(1)))) used")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }.padding(.leading, 4)
            }
        }.padding(.horizontal, 18).padding(.vertical, 18).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
struct ActivityCard<Destination: View>: View {
    let transactions: [BankTransaction]
    var showsAccount = true
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        VStack(spacing: 0) {
            if transactions.isEmpty { Text("No recent activity").font(.subheadline).foregroundStyle(.secondary).padding(24) }
            ForEach(transactions) { transaction in
                NavigationLink { TransactionDetailView(transaction: transaction) } label: {
                    TransactionRow(transaction: transaction, showsAccount: showsAccount)
                }.buttonStyle(.plain)
                if transaction.id != transactions.last?.id { Divider().padding(.leading, 66) }
            }
            Divider().padding(.horizontal, 16)
            NavigationLink(destination: destination) {
                HStack {
                    Text("All transactions").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.weight(.medium))
                }.foregroundStyle(Color.tallyAccent).padding(.horizontal, 18).padding(.vertical, 17).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.tallyCard()
    }
}
struct TransactionRow: View {
    @Environment(TallyStore.self) private var store
    let transaction: BankTransaction
    var showsAccount = true
    private var account: BankAccount? { store.dashboard.accounts.first { $0.id == transaction.accountID } }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(transaction.amount < 0 ? Color.tallyAccent : Color.secondary)
                .frame(width: 38, height: 38)
                .background(transaction.amount < 0 ? Color.tallyAccent.opacity(0.08) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.merchant).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    if showsAccount { Text(account?.shortBank ?? "Account"); Text("·") }
                    Text(transaction.dateValue.formatted(.dateTime.month(.abbreviated).day()))
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 5) {
                Text((transaction.amount < 0 ? "+" : transaction.amount > 0 ? "−" : "") + money(abs(transaction.amount), currency: transaction.currency))
                    .font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(transaction.amount < 0 ? Color.tallyAccent : .primary)
                if transaction.pending { Text("Pending").font(.caption2.weight(.medium)).foregroundStyle(.orange) }
            }.layoutPriority(1)
        }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
struct TransactionsView: View {
    @Environment(TallyStore.self) private var store
    private let lockedAccountID: String?
    @State private var search = ""
    @State private var selectedAccount = "all"
    @State private var status = ActivityStatus.all
    @State private var direction = ActivityDirection.all
    init(accountID: String? = nil) { lockedAccountID = accountID }
    private var effectiveAccountID: String? { lockedAccountID ?? (selectedAccount == "all" ? nil : selectedAccount) }
    private var account: BankAccount? { store.dashboard.accounts.first { $0.id == effectiveAccountID } }
    private var accountLabel: String { account.map { "\($0.shortBank) · \($0.mask)" } ?? "All accounts" }
    private var hasFilters: Bool { status != .all || direction != .all || (lockedAccountID == nil && selectedAccount != "all") }
    private var filtered: [BankTransaction] {
        ActivityFilter(accountID: effectiveAccountID, status: status, direction: direction).apply(to: store.dashboard, search: search)
    }
    private var pending: [BankTransaction] { filtered.filter(\.pending) }
    private var postedGroups: [(String, [BankTransaction])] {
        Dictionary(grouping: filtered.filter { !$0.pending }, by: \.date).sorted { $0.key > $1.key }
    }
    var body: some View {
        List {
            Section {
                accountControl
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            Picker("Status", selection: $status) { ForEach(ActivityStatus.allCases, id: \.self) { Text($0.label).tag($0) } }
                        } label: { FilterLabel(text: status.label, symbol: "clock", active: status != .all) }
                        Menu {
                            Picker("Direction", selection: $direction) { ForEach(ActivityDirection.allCases, id: \.self) { Text($0.label).tag($0) } }
                        } label: { FilterLabel(text: direction.label, symbol: "arrow.up.arrow.down", active: direction != .all) }
                        if hasFilters {
                            Button { status = .all; direction = .all; selectedAccount = "all" } label: {
                                Text("Clear").font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 10)
                            }
                        }
                    }.padding(.vertical, 2)
                }.listRowSeparator(.hidden)
            } footer: { Text("\(filtered.count) transactions").font(.caption) }
            if let error = store.error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
            if filtered.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "magnifyingglass", description: Text("Try another search or filter."))
                    .listRowBackground(Color.clear)
            }
            if !pending.isEmpty {
                Section { ForEach(pending) { transactionLink($0) } } header: { Text("Pending · \(pending.count)") }
            }
            ForEach(postedGroups, id: \.0) { date, transactions in
                Section(transactions.first?.dateValue.formatted(.dateTime.month(.wide).day().year()) ?? date) {
                    ForEach(transactions) { transactionLink($0) }
                }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(18).scrollContentBackground(.hidden).background(Color.tallyCanvas)
        .navigationTitle("Transactions").navigationBarTitleDisplayMode(lockedAccountID == nil ? .large : .inline)
        .searchable(text: $search, prompt: "Search transactions")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton() } }
    }
    @ViewBuilder private var accountControl: some View {
        if lockedAccountID != nil {
            HStack(spacing: 10) {
                if let account { BankMark(account: account, size: 32) }
                Text(accountLabel).font(.subheadline.weight(.medium))
                Spacer()
            }.padding(.vertical, 2)
        } else {
            Menu {
                Picker("Account", selection: $selectedAccount) {
                    Text("All accounts").tag("all")
                    ForEach(store.dashboard.accounts) { Text("\($0.shortBank) · \($0.mask)").tag($0.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    if let account { BankMark(account: account, size: 30) }
                    else { Image(systemName: "creditcard").font(.subheadline).frame(width: 30) }
                    Text(accountLabel).font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.foregroundStyle(.primary).padding(.vertical, 5)
            }
        }
    }
    private func transactionLink(_ transaction: BankTransaction) -> some View {
        NavigationLink { TransactionDetailView(transaction: transaction) } label: {
            TransactionRow(transaction: transaction, showsAccount: effectiveAccountID == nil).padding(.horizontal, -16)
        }.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
    }
}
private struct FilterLabel: View {
    let text: String
    let symbol: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }.font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(active ? Color.tallyAccent : .secondary)
            .background(active ? Color.tallyAccent.opacity(0.09) : Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}
struct TransactionDetailView: View {
    @Environment(TallyStore.self) private var store
    let transaction: BankTransaction
    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: transaction.symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(Color.tallyAccent)
                        .frame(width: 64, height: 64).background(Color.tallyAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 8) {
                        Text((transaction.amount < 0 ? "+" : transaction.amount > 0 ? "−" : "") + money(abs(transaction.amount), currency: transaction.currency))
                            .font(.system(size: 42, weight: .semibold, design: .rounded)).tracking(-1).minimumScaleFactor(0.65).lineLimit(1)
                            .foregroundStyle(transaction.amount < 0 ? Color.tallyAccent : .primary)
                        Text(transaction.merchant).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                    }
                    Text(transaction.pending ? "Pending" : "Posted").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(transaction.pending ? Color.orange : .tallyAccent)
                        .background((transaction.pending ? Color.orange : .tallyAccent).opacity(0.08), in: Capsule())
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            Section("Details") {
                LabeledContent("Date", value: transaction.dateValue.formatted(date: .long, time: .omitted))
                LabeledContent("Category", value: transaction.categoryName)
                if let account = store.dashboard.accounts.first(where: { $0.id == transaction.accountID }) {
                    LabeledContent("Account", value: "\(account.shortBank) · \(account.mask)")
                }
                LabeledContent("Direction", value: transaction.amount < 0 ? "Incoming" : transaction.amount > 0 ? "Outgoing" : "No movement")
            }.font(.subheadline)
            Section {
                NavigationLink {
                    ChatView(context: "Transaction detail screen. Transaction ID: \(transaction.id). Account ID: \(transaction.accountID). Date: \(transaction.date).", initialPrompt: "Tell me about this charge and similar transactions.")
                } label: { Label("Ask about this transaction", systemImage: "sparkles") }
            }
            if transaction.pending {
                Section { Text("The amount or merchant may change when this transaction posts.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .listSectionSpacing(20).navigationTitle("Transaction").navigationBarTitleDisplayMode(.inline)
    }
}
struct AccountsView: View {
    @Environment(TallyStore.self) private var store
    @State private var settings = false
    @State private var management: BankAccount?
    @State private var addBank = false
    @State private var editMode = EditMode.inactive
    var body: some View {
        List {
            Section {
                StatusBanner()
                if let message = store.connectionMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                if store.pendingLinkSessionID != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Finish connecting your bank", systemImage: "building.columns").font(.headline)
                        HStack {
                            Button("Resume") { Task { await store.startAddingBank() } }.buttonStyle(.borderedProminent)
                            Button("Check connection") { Task { await store.completeBankConnection() } }.buttonStyle(.bordered)
                            Spacer()
                            Button("Cancel", role: .destructive) { Task { await store.cancelBankConnection() } }
                        }.font(.caption).disabled(store.busy)
                    }.padding(.vertical, 8)
                }
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 3))
            Section {
                ForEach(store.orderedAccounts) { account in
                    VStack(spacing: 0) {
                        Button { management = account } label: { ManagementAccountRow(account: account) }
                            .buttonStyle(.plain).disabled(editMode.isEditing)
                        if let bank = store.dashboard.banks.first(where: { $0.id == account.bankID }), bank.needsAttention {
                            Divider().padding(.horizontal, 18)
                            ConnectionStatus(bank: bank).padding(18)
                        }
                    }.listRowInsets(EdgeInsets()).deleteDisabled(true)
                }.onMove { offsets, destination in store.reorderAccounts(from: offsets, to: destination) }
            } header: { Text("Connected accounts") } footer: {
                if editMode.isEditing { Text("Drag the handles to set the order on Home and your widget.") }
            }
            ForEach(store.dashboard.banks.filter { bank in bank.archived != true && !store.dashboard.activeAccounts.contains { $0.bankID == bank.id } }) { bank in
                Button("Manage \(bank.name) connection") { Task { await store.reconnect(bank) } }
            }
            if store.dashboard.activeAccounts.isEmpty {
                ContentUnavailableView("Connect your first bank", systemImage: "building.columns", description: Text("Add checking, savings, or credit card accounts securely with Plaid."))
            }
            Section {
                Button { addBank = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "building.columns").font(.title3).foregroundStyle(Color.tallyAccent).frame(width: 38, height: 38)
                        Text("Link another bank").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.busy || editMode.isEditing)
            }
            if store.dashboard.accounts.contains(where: { $0.archived == true }) {
                Section("Disconnected accounts") {
                    ForEach(store.dashboard.accounts.filter { $0.archived == true }) { account in
                        Button { management = account } label: { ManagementAccountRow(account: account) }.buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(18)
        .scrollContentBackground(.hidden).background(Color.tallyCanvas).navigationTitle("Accounts")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Edit") { withAnimation { editMode = editMode.isEditing ? .inactive : .active } }
                    .disabled(store.orderedAccounts.count < 2)
            }
            ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(item: $management) { AccountManagementView(accountID: $0.id) }
        .confirmationDialog("Connect another bank", isPresented: $addBank, titleVisibility: .visible) {
            Button("Continue with Plaid") { Task { await store.startAddingBank() } }
        } message: { Text("Choose a new bank or login. To change accounts at an already-connected bank, use its connection settings. A new connection uses a Plaid trial slot.") }
    }
}
private struct ManagementAccountRow: View {
    @Environment(TallyStore.self) private var store
    let account: BankAccount
    var body: some View {
        HStack(spacing: 12) {
            BankMark(account: account)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.accountName(account)).font(.subheadline.weight(.semibold))
                Text("\(account.shortBank) · \(account.mask)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).font(.subheadline)
        }.padding(18).contentShape(Rectangle())
    }
}
struct AccountManagementView: View {
    @Environment(TallyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    @State private var nickname = ""
    @State private var confirmDisconnect = false
    private var account: BankAccount? { store.dashboard.accounts.first { $0.id == accountID } }
    var body: some View {
        NavigationStack {
            Form {
                if let account {
                    Section {
                        HStack(spacing: 14) {
                            BankMark(account: account, size: 52)
                            VStack(alignment: .leading, spacing: 5) { Text(account.shortBank).font(.headline); Text("\(account.displayName) · \(account.mask)").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }
                    Section {
                        TextField("Account nickname", text: $nickname).onSubmit { store.renameAccount(account, to: nickname) }
                        if account.archived != true {
                            Toggle("Include on Home", isOn: Binding(get: { !store.hiddenAccountIDs.contains(account.id) }, set: { store.setHomeVisibility(account, visible: $0) }))
                        }
                    } header: { Text("Personalize") } footer: { Text("Hidden accounts stay connected. Home totals and the widget include only visible accounts.") }
                    if account.archived == true {
                        Section("Saved history") {
                            NavigationLink("Balance history") { BalanceHistoryView(accountID: account.id) }
                            NavigationLink("Transactions") { TransactionsView(accountID: account.id) }
                        }
                    } else if let bank = store.dashboard.banks.first(where: { $0.id == account.bankID }) {
                        Section {
                            Button("Manage shared bank accounts") { store.renameAccount(account, to: nickname); dismiss(); Task { await store.reconnect(bank) } }
                            Button("Disconnect bank", role: .destructive) { confirmDisconnect = true }.disabled(store.busy)
                        } header: { Text("Connection") } footer: { Text("Disconnecting stops updates for every account under this bank login. Saved transactions and balance history are retained.") }
                    }
                    if let error = store.error { Section { Text(error).foregroundStyle(.orange).font(.caption) } }
                }
            }
            .navigationTitle("Account settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { if let account { store.renameAccount(account, to: nickname) }; dismiss() } } }
            .onAppear { if let account { nickname = store.accountName(account) } }
            .onDisappear { if let account { store.renameAccount(account, to: nickname) } }
            .confirmationDialog("Disconnect this bank?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                if let account, let bank = store.dashboard.banks.first(where: { $0.id == account.bankID }) {
                    Button("Disconnect \(bank.name)", role: .destructive) { Task { if await store.disconnect(bank) { dismiss() } } }
                }
            } message: { Text("All accounts for this login will stop updating. Your saved history will stay available.") }
        }
    }
}
private struct ConnectionStatus: View {
    @Environment(TallyStore.self) private var store
    let bank: BankConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if bank.error != nil || !bank.importComplete || bank.syncPending == true {
                Label(bank.statusText, systemImage: bank.error == nil ? "clock" : "exclamationmark.circle").foregroundStyle(.orange)
            }
            if bank.error == "ITEM_LOGIN_REQUIRED" || bank.error == "PENDING_EXPIRATION" {
                Button("Reconnect securely") { Task { await store.reconnect(bank) } }.disabled(store.busy).padding(.top, 3)
            } else if bank.error != nil || !bank.importComplete || bank.syncPending == true {
                Button("Try again") { Task { await store.refreshManually() } }.disabled(store.busy).padding(.top, 3)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct AccountDetailView: View {
    @Environment(TallyStore.self) private var store
    let accountID: String
    private var account: BankAccount? { store.dashboard.accounts.first { $0.id == accountID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let account {
                    hero(account)
                    NavigationLink {
                        ChatView(context: "Account detail screen. Account ID: \(accountID).", initialPrompt: "Give me an overview of this account.")
                    } label: {
                        Label("Ask about this account", systemImage: "sparkles").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(18).financeCard()
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: account.isCredit ? "Credit overview" : "Balance details")
                        balances(account)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Recent activity")
                        ActivityCard(transactions: store.dashboard.recentActivity(accountID: account.id), showsAccount: false) {
                            TransactionsView(accountID: account.id)
                        }
                    }
                    if let bank = store.dashboard.banks.first(where: { $0.id == account.bankID }), bank.needsAttention {
                        ConnectionStatus(bank: bank).padding(.horizontal, 4)
                    }
                } else {
                    ContentUnavailableView("Account unavailable", systemImage: "creditcard", description: Text("Return to Accounts and refresh your banks."))
                }
            }.padding(20)
        }
        .background(Color.tallyCanvas).navigationTitle(account?.shortBank ?? "Account").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton() } }
    }
    private func hero(_ account: BankAccount) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                BankMark(account: account, size: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.accountName(account)).font(.headline)
                    Text("•• \(account.mask)").font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(account.isCredit ? "Balance including pending" : (account.available == nil ? "Current balance" : "Available to spend"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(money(store.dashboard.displayBalance(for: account), currency: account.currency))
                    .font(.system(size: 42, weight: .semibold, design: .rounded)).tracking(-1).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            if account.isCredit {
                Divider()
                HStack {
                    metric("Current balance", value: account.current, currency: account.currency)
                    Spacer()
                    metric("Pending", value: store.dashboard.pendingTotal(for: account), currency: account.currency)
                }
                Divider()
                CreditPaymentSummary(account: account)
            }
        }.padding(22).tallyCard()
    }
    private func metric(_ title: String, value: Double?, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(money(value, currency: currency)).font(.system(.headline, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func balances(_ account: BankAccount) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if account.isCredit {
                if let adjusted = store.dashboard.availableAfterPending(for: account) {
                    LabeledContent("Available after pending", value: money(adjusted, currency: account.currency))
                    if let reported = account.available, abs(reported - adjusted) >= 0.005 {
                        LabeledContent("Bank-reported available", value: money(reported, currency: account.currency)).font(.caption).foregroundStyle(.secondary)
                    }
                } else { LabeledContent("Available credit", value: money(account.available, currency: account.currency)) }
                LabeledContent("Credit limit", value: money(account.limit, currency: account.currency))
                if let utilization = store.dashboard.utilization(for: account) {
                    Divider()
                    VStack(spacing: 11) {
                        HStack {
                            Text("Credit used").foregroundStyle(.secondary)
                            Spacer()
                            Text(utilization, format: .percent.precision(.fractionLength(1))).fontWeight(.semibold)
                        }
                        ProgressView(value: min(utilization, 1)).tint(.tallyAccent)
                    }
                }
                Text("Available after pending is calculated; bank holds and timing may cause differences.").font(.caption2).foregroundStyle(.secondary)
            } else {
                LabeledContent("Available balance", value: money(account.available, currency: account.currency))
                LabeledContent("Current balance", value: money(account.current, currency: account.currency))
            }
        }.font(.subheadline).padding(20).tallyCard()
    }
}
struct SettingsView: View {
    @Environment(TallyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showConnection = false
    @State private var clearCache = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy") {
                    Toggle("App lock", isOn: Binding(get: { store.useFaceID }, set: { store.useFaceID = $0 }))
                    Text("Optional Face ID or passcode protection.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { AISettingsView() } label: { Label("Ask Tally", systemImage: "sparkles") }
                }
                Section("Data") {
                    Picker("Automatic refresh", selection: Binding(get: { store.automaticRefreshMinutes }, set: { minutes in Task { await store.updateRefreshInterval(minutes) } })) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }.disabled(store.busy || store.savingRefreshInterval)
                    Button("Clear saved data on this iPhone", role: .destructive) { clearCache = true }
                }
                Section("How updates work") {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Your banks refresh automatically on the server at the selected interval, even when Tally is closed.", systemImage: "iphone")
                        Label("Open Tally to see the latest saved data. Tap Refresh for an extra bank refresh at any time.", systemImage: "arrow.clockwise")
                    }.font(.subheadline).padding(.vertical, 5)
                    Text("New purchases may take time to become available through your bank. Updates also arrive automatically when Plaid reports new activity.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Server connection") {
                        if let url = store.settings?.url { Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Button("Change connection") { showConnection = true }
                    }
                }
                Section {
                    LabeledContent("Tally", value: "1.0")
                    Text("Your accounts, in one place. Manage bank connections in Accounts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showConnection) { SetupView(canDismiss: true) }
            .confirmationDialog("Clear saved financial data?", isPresented: $clearCache, titleVisibility: .visible) {
                Button("Clear local cache", role: .destructive) { store.eraseCache() }
            } message: { Text("Your bank connections stay active. Refresh to download your data again.") }
        }
    }
}
struct BankSignIn: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
