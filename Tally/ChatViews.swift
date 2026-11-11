import SwiftUI
import UIKit
import AVFAudio

struct ChatView: View {
    @Environment(TallyStore.self) private var store
    var context = "Ask Tally. No account or date filter selected."
    var initialPrompt = ""
    @State private var draft = ""
    @State private var selectedTransaction: BankTransaction?
    @State private var confirmClear = false
    @State private var showAbout = false
    @State private var copiedMessageID: String?
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
                LazyVStack(alignment: .leading, spacing: 28) {
                    if store.chatMessages.isEmpty { welcome }
                    ForEach(store.chatMessages) { message in
                        messageView(message).id(message.id)
                    }
                    if store.chatSending {
                        VStack(alignment: .leading, spacing: 12) {
                            assistantLabel
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking your saved activity…").font(.subheadline).foregroundStyle(.secondary) }
                        }.accessibilityElement(children: .ignore).accessibilityLabel("Tally is checking your saved activity")
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
                    if store.chatMessages.last?.role == "assistant", !store.chatSending, store.pendingChatRequest == nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(["Show the transactions", "Compare with last month", "Explain that more simply"], id: \.self) { question in
                                    Button { choose(question) } label: {
                                        Text(question).font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 11)
                                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(.top, -14).accessibilityLabel("Follow-up questions")
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 4)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Ask Tally").font(.headline)
                    Text("Your money, explained").font(.caption2).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New chat", systemImage: "square.and.pencil") { confirmClear = true }.disabled(store.chatSending || dictation.isBusy || store.chatMessages.isEmpty)
                    NavigationLink { AISettingsView() } label: { Label("OpenAI key", systemImage: "key") }
                    Button("How it works", systemImage: "info.circle") { showAbout = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(.primary) }.accessibilityLabel("Chat options")
            }
        }
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
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 36)
                Text(message.text).font(.body).lineSpacing(3).textSelection(.enabled).padding(.horizontal, 18).padding(.vertical, 14)
                    .background(Color.tallyAccent.opacity(0.1), in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22))
                    .overlay { UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22).strokeBorder(Color.tallyAccent.opacity(0.08), lineWidth: 1) }
            }
        } else {
        VStack(alignment: .leading, spacing: 15) {
            assistantLabel
            ChatAnswerText(text: message.text)
                .equatable()
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "tally", url.host == "transaction" else { return .discarded }
                    let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
                    guard let transaction = message.sources.first(where: { $0.id == id }) else { return .discarded }
                    selectedTransaction = store.dashboard.transactions.first(where: { $0.id == id }) ?? transaction
                    return .handled
                })
            if !message.sources.isEmpty {
                DisclosureGroup {
                    ForEach(message.sources) { transaction in
                        Button {
                            selectedTransaction = store.dashboard.transactions.first(where: { $0.id == transaction.id }) ?? transaction
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: transaction.symbol).font(.subheadline).foregroundStyle(Color.tallyAccent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(transaction.merchant).lineLimit(2)
                                    Text(transaction.dateValue.formatted(.dateTime.month(.abbreviated).day()) + (transaction.pending ? " · Pending" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(money(transaction.amount, currency: transaction.currency)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.font(.subheadline).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if transaction.id != message.sources.last?.id { Divider() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.tallyAccent)
                        Text("View transactions").foregroundStyle(.primary)
                        Text("\(message.sources.count)").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.05), in: Capsule())
                    }.font(.subheadline.weight(.medium))
                }.tint(.secondary).padding(.horizontal, 15).padding(.vertical, 13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 4) {
                Button { UIPasteboard.general.string = message.text; copiedMessageID = message.id } label: {
                    Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
                }.accessibilityLabel(copiedMessageID == message.id ? "Answer copied" : "Copy answer")
                ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Share answer")
                Spacer()
                if let date = parseBankDate(message.retrievedAt) { Text(date.formatted(date: .omitted, time: .shortened)).font(.caption2) }
                if let calls = message.modelCalls {
                    Menu {
                        Text("\(calls) AI \(calls == 1 ? "call" : "calls") for this answer")
                        if let date = parseBankDate(message.retrievedAt) { Text("Answered \(date.formatted(date: .abbreviated, time: .shortened))") }
                    } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }.accessibilityLabel("Answer details")
                }
            }.font(.system(size: 15)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.horizontal, -10).padding(.top, -8)
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var assistantLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.tallyAccent)
                .frame(width: 28, height: 28).background(Color.tallyAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            Text("Tally").font(.subheadline.weight(.semibold))
        }.accessibilityElement(children: .combine)
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
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your money…", text: $draft, axis: .vertical)
                    .font(.body).lineLimit(1...6).focused($composing).padding(.leading, 17).padding(.vertical, 15)
                    .accessibilityLabel("Your question")
                    .disabled(dictation.isBusy)
                    .onChange(of: draft) { _, value in if value.count > 4000 { draft = String(value.prefix(4000)) } }
                Button {
                    if dictation.isRecording { dictation.finish() }
                    else { startDictation() }
                } label: {
                    Group {
                        if dictation.isStarting || dictation.isFinishing { ProgressView().controlSize(.small) }
                        else { Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic").font(.system(size: 20, weight: .medium)) }
                    }.foregroundStyle(dictation.isRecording ? Color.red : Color.tallyAccent).frame(width: 44, height: 48)
                }.buttonStyle(.plain).accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate question")
                    .disabled(!store.hasOpenAIKey || store.chatSending || store.pendingChatRequest != nil || dictation.isStarting || dictation.isFinishing)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canSend ? Color(uiColor: .systemBackground) : Color.secondary.opacity(0.65))
                        .frame(width: 38, height: 38).background(canSend ? Color.tallyAccent : Color.primary.opacity(0.06), in: Circle())
                        .frame(width: 48, height: 48)
                }.buttonStyle(.plain).accessibilityLabel("Send message").disabled(!canSend).padding(.trailing, 5).padding(.bottom, 4)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 27))
            .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .shadow(color: .black.opacity(0.025), radius: 10, y: 3)
            if !store.hasOpenAIKey {
                NavigationLink { AISettingsView() } label: { Label("Add your OpenAI key to get started", systemImage: "key").font(.caption) }
            }
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            .background { LinearGradient(colors: [.tallyCanvas.opacity(0), .tallyCanvas, .tallyCanvas], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
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
