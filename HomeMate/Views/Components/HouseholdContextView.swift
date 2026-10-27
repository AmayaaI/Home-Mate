import SwiftUI

struct HouseholdContextView: View {
    @ObservedObject var context: HouseholdContext
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Viewing household").font(.headline)
            HStack {
                Menu {
                    Button("My private household") { context.select(nil) }
                    ForEach(context.families) { family in
                        Button(family.name) { context.select(family) }
                    }
                } label: {
                    Label(context.family?.name ?? "My private household", systemImage: context.family == nil ? "person.crop.circle" : "person.3.fill")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                }.accessibilityLabel("Select household: \(context.family?.name ?? "My private household")")
                Spacer()
                if context.loading { ProgressView().accessibilityLabel("Refreshing household") }
                Button { Task { await context.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Refresh household").disabled(context.loading)
            }
            if let error = context.error { Text(error).font(.caption).foregroundStyle(.red).accessibilityLabel("Household error: \(error)") }
            Text("Choose the household shown on Home and in Communication. When adding a record, choose Private or Shared in its form.")
                .font(.caption).foregroundStyle(.secondary)
        }.tint(DashboardPalette.green)
    }
}

struct HouseholdAnnouncementsView: View {
    @ObservedObject var context: HouseholdContext
    var userID: String
    var authorName: String
    @State private var editing: FamilyAnnouncement?
    @State private var deleting: FamilyAnnouncement?
    var body: some View {
        List {
            if context.announcements.isEmpty {
                ContentUnavailableView("No announcements", systemImage: "megaphone", description: Text("Share an update with this household."))
            }
            ForEach(context.announcements) { announcement in
                VStack(alignment: .leading, spacing: 8) {
                    Label(announcement.title, systemImage: announcement.important ? "exclamationmark.circle.fill" : "megaphone").font(.headline)
                    Text(announcement.body)
                    Text("\(announcement.authorName) · \(announcement.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if announcement.authorID == userID || context.family?.ownerID == userID {
                        HStack {
                            Button("Edit") { editing = announcement }.buttonStyle(.bordered)
                            Button("Delete", role: .destructive) { deleting = announcement }.buttonStyle(.bordered)
                        }.disabled(!context.canWrite)
                    }
                }.padding(.vertical, 6)
            }
        }
        .navigationTitle("Announcements")
        .toolbar {
            Button("New announcement", systemImage: "plus") {
                editing = FamilyAnnouncement(authorID: userID, authorName: String((authorName.isEmpty ? "Member" : authorName).prefix(100)))
            }.disabled(!context.canWrite)
        }
        .refreshable { await context.refresh() }
        .sheet(item: $editing) { value in AnnouncementEditor(context: context, draft: value) }
        .confirmationDialog("Delete announcement?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { Task { await context.deleteAnnouncement(deleting) } }; deleting = nil }
        }
    }
}

private struct AnnouncementEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var context: HouseholdContext
    @State var draft: FamilyAnnouncement
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $draft.title)
                TextField("Message", text: $draft.body, axis: .vertical).lineLimit(4...12)
                Toggle("Important", isOn: $draft.important)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(draft.revision == nil ? "New announcement" : "Edit announcement")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            let identity = context.identity
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await context.saveAnnouncement(draft, expectedIdentity: identity); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(saving || draft.validationError != nil || !context.canWrite)
                    }
                }
        }
    }
}
