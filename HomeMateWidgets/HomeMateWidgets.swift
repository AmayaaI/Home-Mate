import SwiftUI
import WidgetKit

struct HomeMateWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: HomeWidgetSnapshot
}

struct HomeMateTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeMateWidgetEntry {
        HomeMateWidgetEntry(date: Date(), snapshot: .make(householdName: "My Home", activities: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeMateWidgetEntry) -> Void) {
        completion(HomeMateWidgetEntry(date: Date(), snapshot: HomeWidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeMateWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = HomeWidgetSnapshotStore.read()
        let refresh = now.addingTimeInterval(15 * 60)
        // Entries at event end times keep expired events out even while the app is closed.
        let expirations = snapshot.activities.filter { $0.kind == .event }.map {
            $0.endDate ?? $0.date.addingTimeInterval(3600)
        }.filter { $0 > now && $0 < refresh }
        let dates = [now] + Set(expirations).sorted()
        let entries = dates.map { HomeMateWidgetEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

private struct HomeMateWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HomeMateWidgetEntry
    private let accent = Color(red: 0.12, green: 0.56, blue: 0.46)
    private var activities: [HomeWidgetActivity] { entry.snapshot.pendingActivities(at: entry.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 10 : 12) {
            HStack(spacing: 6) {
                Image(systemName: "house.fill").foregroundStyle(accent)
                Text("HomeMate").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if family == .systemMedium {
                    Text(entry.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !entry.snapshot.isActive {
                emptyState(title: "Your home, at a glance", subtitle: "Open HomeMate to sign in.")
            } else if activities.isEmpty {
                emptyState(title: "All caught up", subtitle: "Add a task, bill or event in HomeMate.")
            } else if family == .systemSmall {
                smallContents
            } else {
                mediumContents
            }
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(accent.opacity(0.09)).frame(width: 150, height: 150).offset(x: 65, y: -80)
                }
        }
        .privacySensitive()
        .accessibilityElement(children: .combine)
    }

    private var smallContents: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.snapshot.householdName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let first = activities.first {
                Text(first.title).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                HStack(spacing: 4) {
                    Image(systemName: first.kind.symbol)
                    dateLabel(first)
                }
                .font(.caption2).foregroundStyle(dateColor(first))
            }
            Spacer(minLength: 0)
            Text("\(activities.count) pending").font(.caption2.weight(.semibold)).foregroundStyle(accent)
        }
    }

    private var mediumContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.snapshot.householdName).font(.caption).lineLimit(1)
                Spacer()
                Text("\(activities.count) pending").font(.caption2.weight(.semibold)).foregroundStyle(accent)
            }
            .foregroundStyle(.secondary)
            ForEach(Array(activities.prefix(3))) { activity in
                HStack(spacing: 9) {
                    Image(systemName: activity.kind.symbol)
                        .font(.caption).foregroundStyle(accent).frame(width: 18)
                    Text(activity.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    dateLabel(activity).font(.caption2).foregroundStyle(dateColor(activity))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func dateLabel(_ activity: HomeWidgetActivity) -> Text {
        if activity.kind != .event && activity.date < Calendar.current.startOfDay(for: entry.date) {
            return Text("Overdue")
        }
        if Calendar.current.isDate(activity.date, inSameDayAs: entry.date) {
            return Text(activity.date, format: .dateTime.hour().minute())
        }
        return Text(activity.date, format: .dateTime.month(.abbreviated).day())
    }

    private func dateColor(_ activity: HomeWidgetActivity) -> Color {
        activity.kind != .event && activity.date < Calendar.current.startOfDay(for: entry.date) ? .orange : .secondary
    }
}

@main
struct HomeMateUpcomingWidget: Widget {
    let kind = HomeWidgetSnapshotStore.widgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeMateTimelineProvider()) { entry in
            HomeMateWidgetView(entry: entry)
        }
        .configurationDisplayName("Your home, upcoming")
        .description("See your next tasks, bills, maintenance and events. Tap to open HomeMate.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
