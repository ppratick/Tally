import SwiftUI
import WidgetKit

struct TallyEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: WidgetSnapshot?
}
// WidgetKit invokes this callback once after our single asynchronous fetch.
private struct TimelineCallback: @unchecked Sendable {
    let call: (Timeline<TallyEntry>) -> Void
}
struct TallyProvider: TimelineProvider, Sendable {
    func placeholder(in context: Context) -> TallyEntry { TallyEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (TallyEntry) -> Void) {
        completion(TallyEntry(date: .now, snapshot: WidgetStorage.read("snapshot", as: WidgetSnapshot.self)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TallyEntry>) -> Void) {
        let callback = TimelineCallback(call: completion)
        Task {
            var snapshot = WidgetStorage.read("snapshot", as: WidgetSnapshot.self)
            if let configuration = WidgetStorage.read("configuration", as: WidgetPreferences.self),
               let url = URL(string: configuration.server + "/v1/widget"), url.scheme == "https" {
                do {
                    var request = URLRequest(url: url); request.timeoutInterval = 20
                    request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
                    request.setValue("TallyWidget/1.0", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        let value = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
                        snapshot = configuration.applying(to: value)
                        if let snapshot { WidgetStorage.save(snapshot, key: "snapshot") }
                    }
                } catch { /* The last successful snapshot remains available offline. */ }
            }
            callback.call(Timeline(entries: [TallyEntry(date: .now, snapshot: snapshot)], policy: .after(.now.addingTimeInterval(1800))))
        }
    }
}
struct TallyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TallyEntry
    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
                if family == .systemMedium { medium(snapshot).privacySensitive() } else { small(snapshot).privacySensitive() }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Tally", systemImage: "chart.bar.fill").font(.headline)
                    Spacer()
                    Text("Your money, in view.").font(.headline)
                    Text("Open Tally to load your accounts.").font(.caption).foregroundStyle(.white.opacity(0.75))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .widgetURL(URL(string: "tally://home"))
        .containerBackground(for: .widget) { Color.black }
    }
    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Tally").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
            Text("Net balance").font(.caption2).foregroundStyle(.white.opacity(0.75))
            Text(snapshot.net, format: .currency(code: "USD")).font(.system(size: 29, weight: .semibold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).monospacedDigit()
            Spacer(minLength: 0)
            synced(snapshot)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Tally").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                Text("Net balance").font(.caption2).foregroundStyle(.white.opacity(0.75))
                Text(snapshot.net, format: .currency(code: "USD")).font(.system(size: 29, weight: .semibold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).monospacedDigit()
                Spacer(minLength: 0)
                synced(snapshot)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.white.opacity(0.16)).frame(width: 1).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(snapshot.accounts.prefix(3))) { account in
                    HStack(spacing: 6) {
                        Text(account.shortBank).font(.caption2).lineLimit(1)
                        Spacer(minLength: 1)
                        if let balance = account.balance {
                            Text((account.isCredit ? "−" : "") + balance.formatted(.currency(code: account.currency))).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        } else { Text("—").font(.caption2) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func synced(_ snapshot: WidgetSnapshot) -> some View {
        Group {
            if let date = snapshot.updatedDate { Text("Updated \(date, style: .relative) ago") }
            else { Text("Update time unavailable") }
        }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
    }
}
@main struct TallyWidget: Widget {
    let kind = "TallyBalances"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TallyProvider()) { entry in TallyWidgetView(entry: entry) }
            .configurationDisplayName("Tally balances").description("Available cash and card balances, including pending activity.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
