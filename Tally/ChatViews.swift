import SwiftUI
import UIKit
import AVFAudio

struct ChatView: View {
    @Environment(TallyStore.self) private var store
    var context = "Ask Tally. No account or date filter selected."
    var initialPrompt = ""
    /// True for the Ask Tally tab (floating glass header); false when pushed from a detail screen.
    var inTab = false
    @State private var draft = ""
    @State private var selectedTransaction: BankTransaction?
    @State private var confirmClear = false
    @State private var showAbout = false
    @State private var detailsFor: ChatMessage?
    @State private var dictation = ChatDictation()
    @State private var dictationPrefix = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var composing: Bool
    private let suggestions: [(title: String, detail: String, icon: String, question: String)] = [
        ("This month's spending", "See where it went", "chart.pie", "How much have I spent this month? Break it down by category and include the date range."),
        ("Upcoming bills", "Know what's coming up", "calendar", "Which recurring bills are expected next? Show the estimated dates and amounts."),
        ("What's changed?", "Compare with last month", "chart.line.uptrend.xyaxis", "Compare my spending this month with the same number of days last month. What changed?"),
        ("Recent purchases", "Look through your activity", "magnifyingglass", "Show my 10 most recent purchases with links to the transactions.")
    ]
    private var canSend: Bool {
        store.hasOpenAIKey && !store.chatSending && !dictation.isStarting && store.pendingChatRequest == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.chatMessages.isEmpty { welcome }
                    ForEach(store.chatMessages) { message in
                        messageView(message).id(message.id)
                    }
                    if store.chatSending {
                        HStack(spacing: 10) {
                            TypingDots()
                            Text("Checking your activity…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .background(Self.assistantBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityElement(children: .ignore).accessibilityLabel("Tally is checking your saved activity")
                    }
                    if let error = store.chatError {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle").font(.title3).foregroundStyle(.orange).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Couldn't finish that answer").font(.subheadline.weight(.semibold))
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                if store.pendingChatRequest != nil {
                                    Button { Task { await store.retryChat() } } label: { Label("Try again", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold)) }.disabled(store.chatSending)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).financeCard()
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { if !store.chatMessages.isEmpty { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
            .onChange(of: store.chatMessages.count) { _, _ in withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
            .onChange(of: store.chatSending) { _, _ in withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
            .onChange(of: store.chatError) { _, _ in withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .background(Color.tallyCanvas)
        .navigationTitle("Ask Tally")
        .modifier(ChatChrome(inTab: inTab, menu: AnyView(chatMenu), newChat: { if !store.chatMessages.isEmpty && !store.chatSending { confirmClear = true } }))
        .confirmationDialog("Clear this conversation and start a new chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { Task { await store.clearChat() } }
        } message: { Text("This removes the conversation from this device and your Tally server. Usage totals are kept.") }
        .sheet(item: $selectedTransaction) { transaction in
            NavigationStack {
                TransactionDetailView(transaction: transaction)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedTransaction = nil } } }
            }
        }
        .sheet(isPresented: $showAbout) { about }
        .sheet(item: $detailsFor) { message in AnswerDetailsSheet(message: message) }
        .alert("Dictation", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            if dictation.needsSettings {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: { Text(dictation.error ?? "") }
        .onChange(of: dictation.transcript) { _, text in draft = dictatedQuestion(text) }
        .onChange(of: dictation.completedText) { _, text in
            guard let text, scenePhase == .active, store.unlocked else { return }
            draft = dictatedQuestion(text)
            send()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase != .active && (dictation.isRecording || dictation.isFinishing)) { dictation.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { _ in dictation.cancel() }
        .onDisappear { dictation.cancel() }
        .onAppear { store.refreshOpenAIKeyStatus(); if draft.isEmpty { draft = initialPrompt } }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 28, weight: .medium)).foregroundStyle(Color.tallyAccent)
                    .frame(width: 68, height: 68).background(Color.tallyAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 22)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("A little clarity.\nFor all your money.").font(.system(.largeTitle, design: .rounded, weight: .semibold)).tracking(-0.7).fixedSize(horizontal: false, vertical: true)
                    Text("Explore your spending, check your bills, or understand what changed.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("START WITH A QUESTION").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(suggestions.indices, id: \.self) { index in
                        let prompt = suggestions[index]
                        Button { choose(prompt.question) } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Image(systemName: prompt.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.tallyAccent)
                                    Spacer()
                                    Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(prompt.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(prompt.detail).font(.caption).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                            }.multilineTextAlignment(.leading).padding(16).frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.045), lineWidth: 1) }
                        }.buttonStyle(.plain).accessibilityLabel(prompt.question)
                    }
                }
            }
            Button { showAbout = true } label: {
                Label("Your saved activity. Answers backed by your data.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }.padding(.top, 12).padding(.bottom, 12)
    }
    static let assistantBubble = Color(uiColor: .secondarySystemGroupedBackground)
    private var chatMenu: some View {
        Group {
            Button("New chat", systemImage: "square.and.pencil") { confirmClear = true }.disabled(store.chatSending || dictation.isBusy || store.chatMessages.isEmpty)
            NavigationLink { AISettingsView() } label: { Label("OpenAI key", systemImage: "key") }
            Button("How it works", systemImage: "info.circle") { showAbout = true }
        }
    }
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.text).font(.body).lineSpacing(2).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Color.tallyAccent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ChatAnswerText(text: message.text)
                    .equatable()
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "tally", url.host == "transaction" else { return .discarded }
                        let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
                        guard let transaction = message.sources.first(where: { $0.id == id }) else { return .discarded }
                        selectedTransaction = store.dashboard.transactions.first(where: { $0.id == id }) ?? transaction
                        return .handled
                    })
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(Self.assistantBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button("Answer details", systemImage: "info.circle") { detailsFor = message }
                    }
                if !message.sources.isEmpty { sources(message) }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func sources(_ message: ChatMessage) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(message.sources) { transaction in
                    Button {
                        selectedTransaction = store.dashboard.transactions.first(where: { $0.id == transaction.id }) ?? transaction
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: transaction.symbol).font(.subheadline).foregroundStyle(Color.tallyAccent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.merchant).lineLimit(1)
                                Text(transaction.dateValue.formatted(.dateTime.month(.abbreviated).day()) + (transaction.pending ? " · Pending" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(transaction.amount, currency: transaction.currency)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }.font(.subheadline).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if transaction.id != message.sources.last?.id { Divider().padding(.leading, 38) }
                }
            }.padding(.top, 6)
        } label: {
            Label("\(message.sources.count) \(message.sources.count == 1 ? "transaction" : "transactions")", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
        }
        .tint(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Self.assistantBubble.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private var about: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("Answers from your activity", systemImage: "sparkles").font(.title2.weight(.semibold))
                    Text("Tally can search all your saved transactions, accounts, bills, and balance history. It retrieves the details needed for your question and calculates totals using the same spending rules as the app.")
                    Text("Your questions and relevant data are sent to OpenAI. Chats are saved on this device; recent context is kept on your server for up to 30 days. Clearing a chat removes that conversation, while keeping usage totals.")
                    Text("Bank history can be incomplete or out of date. Tally can explain your data, but it can't make payments or move money.").foregroundStyle(.secondary)
                }.font(.subheadline).lineSpacing(4).padding(24)
            }
            .navigationTitle("How it works").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAbout = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if !store.hasOpenAIKey {
                NavigationLink { AISettingsView() } label: { Label("Add your OpenAI key to get started", systemImage: "key").font(.caption.weight(.medium)) }
                    .padding(.horizontal, 12).padding(.vertical, 7).tallyGlass(in: Capsule())
            }
            HStack(alignment: .bottom, spacing: 6) {
                if inTab {
                    Menu { chatMenu } label: {
                        Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 48).contentShape(Rectangle())
                    }.accessibilityLabel("Chat options").padding(.leading, 6)
                }
                TextField("Ask about your money…", text: $draft, axis: .vertical)
                    .font(.body).lineLimit(1...6).focused($composing).padding(.leading, inTab ? 0 : 18).padding(.vertical, 14)
                    .accessibilityLabel("Your question")
                    .disabled(dictation.isBusy)
                    .onChange(of: draft) { _, value in if value.count > 4000 { draft = String(value.prefix(4000)) } }
                Button {
                    if dictation.isRecording { dictation.finish() }
                    else { startDictation() }
                } label: {
                    Group {
                        if dictation.isStarting || dictation.isFinishing { ProgressView().controlSize(.small) }
                        else { Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic").font(.system(size: 19, weight: .medium)) }
                    }.foregroundStyle(dictation.isRecording ? Color.red : Color.secondary).frame(width: 40, height: 48)
                }.buttonStyle(.plain).accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate question")
                    .disabled(!store.hasOpenAIKey || store.chatSending || store.pendingChatRequest != nil || dictation.isStarting || dictation.isFinishing)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.6))
                        .frame(width: 36, height: 36).background(canSend ? Color.tallyAccent : Color.primary.opacity(0.07), in: Circle())
                        .frame(width: 44, height: 48)
                }.buttonStyle(.plain).accessibilityLabel("Send message").disabled(!canSend).padding(.trailing, 4)
            }
            .tallyGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
    }
    private func choose(_ question: String) { dictation.cancel(); draft = question; composing = true }
    private func dictatedQuestion(_ text: String) -> String {
        String(([dictationPrefix, text].filter { !$0.isEmpty }.joined(separator: " ")).prefix(4000))
    }
    private func startDictation() {
        guard store.hasOpenAIKey, !store.chatSending, store.pendingChatRequest == nil, !dictation.isBusy else { return }
        dictationPrefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        composing = false
        Task { await dictation.start() }
    }
    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if dictation.isRecording || dictation.isFinishing {
            composing = false
            dictation.finish(send: true)
            return
        }
        draft = ""; composing = false
        Task { await store.sendChat(message, context: context) }
    }
}

/// Floating glass header in the tab; system bar with a soft fade when pushed from a detail screen.
private struct ChatChrome: ViewModifier {
    let inTab: Bool
    let menu: AnyView
    let newChat: () -> Void
    func body(content: Content) -> some View {
        if inTab {
            content.tallyRootScreen("Ask Tally") {
                HeaderIcon(systemImage: "square.and.pencil", label: "New chat", action: newChat)
            }
        } else {
            content.navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { menu } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Chat options") } }
                .tallyTopFade()
        }
    }
}

private struct TypingDots: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary).frame(width: 6, height: 6).opacity(phase == i ? 1 : 0.35)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityHidden(true)
    }
}

/// What went into an answer, shown from the long-press menu.
private struct AnswerDetailsSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let calls = message.modelCalls { LabeledContent("AI calls", value: "\(calls)") }
                else { LabeledContent("AI calls", value: "Unavailable") }
                LabeledContent("Transactions referenced", value: "\(message.sources.count)")
                if let date = parseBankDate(message.retrievedAt) {
                    LabeledContent("Answered", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .navigationTitle("Answer details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.height(280)]).presentationDragIndicator(.visible)
    }
}
