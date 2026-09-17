import BregeCore
import SwiftUI

/// Search through the phone notifications Brêge has seen: "what did that message say on Tuesday?"
/// Everything comes from the Mac's own encrypted cache, which keeps a week.
struct NotificationHistoryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var results: [StoredNotification] = []

    var body: some View {
        List(results, id: \.key) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.appLabel.isEmpty ? item.package : item.appLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatting.shortDate(ms: item.postedMs)).font(.caption).foregroundStyle(.secondary)
                }
                if !item.title.isEmpty { Text(item.title).lineLimit(1) }
                if !item.text.isEmpty {
                    Text(item.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([item.title, item.text].filter { !$0.isEmpty }
                        .joined(separator: "\n"), forType: .string)
                }
            }
        }
        .navigationTitle("Notification History")
        .searchable(text: $query, placement: .toolbar, prompt: "Search notifications")
        .onChange(of: query) { _ in reload() }
        .onAppear { reload() }
        .overlay {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.badge").font(.largeTitle).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Nothing yet" : "Nothing found").font(.headline)
                    Text("Brêge keeps a week of phone notifications on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func reload() {
        results = app.notificationHistory(matching: query)
    }
}
