import SwiftUI

struct FamilySharingView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: FamilySharingViewModel(store: dependencies.store, account: dependencies.account)) { model in
            FamilySharingViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct FamilySharingViewScreen: View {


    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase









    @ObservedObject var viewModel: FamilySharingViewModel
    private var families: [SharedFamily] { get { viewModel.families } nonmutating set { viewModel.families = newValue } }
    private var invitations: [FamilyInvitation] { get { viewModel.invitations } nonmutating set { viewModel.invitations = newValue } }
    private var familyName: String { get { viewModel.familyName } nonmutating set { viewModel.familyName = newValue } }
    private var working: Bool { get { viewModel.working } nonmutating set { viewModel.working = newValue } }
    private var loading: Bool { get { viewModel.loading } nonmutating set { viewModel.loading = newValue } }
    private var error: String? { get { viewModel.error } nonmutating set { viewModel.error = newValue } }
    private var notice: String? { get { viewModel.notice } nonmutating set { viewModel.notice = newValue } }
    var body: some View {
        List {
            if !viewModel.accountSignedIn {
                Section {
                    Text("Sign in to create or join a family and share activities with real accounts.")
                    NavigationLink("Sign in or create account") { LoginView() }
                }
            } else {
                if !viewModel.accountEmailVerified {
                    Section("Verify your email") {
                        Text("Signed in as \(viewModel.accountEmail). Verify this email to create a family or accept invitations addressed to it.")
                        Button("Send verification email") { viewModel.sendVerification() }
                        Button("I verified my email") { viewModel.checkVerification() }
                    }
                }
                if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if loading || working { ProgressView().frame(maxWidth: .infinity) }
                Section("Your families") {
                    if families.isEmpty && !loading { Text("No shared family yet.").foregroundStyle(.secondary) }
                    ForEach(families) { family in
                        Label { VStack(alignment: .leading, spacing: 4) {
                            Text(family.name).font(.headline)
                            Text(family.ownerID == viewModel.accountUserID ? "Owner" : "Member")
                                .font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "person.2.fill").foregroundStyle(DashboardPalette.green) }
                            .accessibilityElement(children: .combine)
                    }
                }
                if viewModel.accountEmailVerified {
                    Section("Invitations for \(viewModel.accountEmail)") {
                        if invitations.isEmpty { Text("No pending invitations. Pull down to refresh.").foregroundStyle(.secondary) }
                        ForEach(invitations) { invite in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(invite.familyName).font(.headline)
                                Text("Joining shares this family’s activities and text chat with you. Your personal profile and private records stay private.").font(.footnote).foregroundStyle(.secondary)
                                Button("Accept invitation") { viewModel.accept(invite) }.buttonStyle(.borderedProminent)
                            }.padding(.vertical, 5)
                        }
                    }
                    Section("Create a family") {
                        TextField("Family name", text: $viewModel.familyName).exactTextEntry()
                        Button("Create shared family", systemImage: "person.2.badge.plus") { viewModel.create() }.disabled(!viewModel.canCreate)
                        Text("A new family starts empty. Choose Shared when adding a task, bill or other record to save it to your family. Manage members from More → Members.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("Family Hub")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .disabled(working)
            .refreshable { await viewModel.refresh() }
            .task(id: "\(viewModel.accountDataScope)-\(phase)") { await viewModel.monitor(active: phase == .active) }
    }


}

struct SharedFamilyView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var family: SharedFamily
    var body: some View {
        ViewModelHost(make: SharedFamilyViewModel(store: dependencies.store, account: dependencies.account, family: family)) { model in
            SharedFamilyViewScreen(household: dependencies.household, viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct SharedFamilyViewScreen: View {
    @ObservedObject var household: HouseholdContext

    @Environment(\.scenePhase) private var phase










    private var family: SharedFamily { viewModel.family }
    @ObservedObject var viewModel: SharedFamilyViewModel
    private var records: [HouseholdRecord] { get { viewModel.records } nonmutating set { viewModel.records = newValue } }
    private var members: [FamilyMember] { get { viewModel.members } nonmutating set { viewModel.members = newValue } }
    private var kind: RecordKind { get { viewModel.kind } nonmutating set { viewModel.kind = newValue } }
    private var selected: HouseholdRecord? { get { viewModel.selected } nonmutating set { viewModel.selected = newValue } }
    private var pendingDelete: HouseholdRecord? { get { viewModel.pendingDelete } nonmutating set { viewModel.pendingDelete = newValue } }
    private var error: String? { get { viewModel.error } nonmutating set { viewModel.error = newValue } }
    private var loading: Bool { get { viewModel.loading } nonmutating set { viewModel.loading = newValue } }
    private var writing: Bool { get { viewModel.writing } nonmutating set { viewModel.writing = newValue } }
    var body: some View {
        List {
            Section {
                Text("Shared with the accepted members of this family. Changes save to the cloud and appear on other members’ phones on refresh.").font(.footnote).foregroundStyle(.secondary)
                NavigationLink { FamilyMembersView(family: family) } label: { Label("Members & email invitations", systemImage: "person.2") }
                if household.family?.id == family.id {
                    NavigationLink { SharedFamilyChatView(family: family) } label: { Label("Family text chat", systemImage: "bubble.left.and.bubble.right") }
                }
            }
            Section {
                Picker("Activity type", selection: $viewModel.kind) { ForEach(RecordKind.allCases) { Text($0.rawValue).tag($0) } }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            if loading { ProgressView() }
            Section(kind.rawValue) {
                if viewModel.filtered.isEmpty { ContentUnavailableView("No shared \(kind.rawValue.lowercased()) yet", systemImage: kind.icon, description: Text("Tap + to add an activity for your family.")) }
                ForEach(viewModel.filtered) { record in
                    Button { selected = record } label: {
                        HStack(spacing: 12) {
                            Image(systemName: record.completed ? "checkmark.circle.fill" : record.kind.icon).foregroundStyle(DashboardPalette.green)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.title).font(.headline).foregroundStyle(.primary)
                                    .strikethrough(record.completed && record.kind != .bill)
                                Text(AssignmentDisplay.label(for: record.assignee, accountEmail: viewModel.accountEmail, localName: viewModel.profile.name, members: members, shared: true)).font(.caption).foregroundStyle(.secondary)
                                Text((ExpenseIntelligence.spendingDate(for: record) ?? record.date).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if record.amount > 0 { Text(record.amount.formatted(.currency(code: family.currency))).font(.subheadline.weight(.semibold)).foregroundStyle(.primary) }
                        }.padding(.vertical, 5)
                    }.swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = record }
                        if record.kind != .expense {
                            Button(record.completed ? "Reopen" : record.kind == .bill ? "Mark paid" : "Complete") {
                                viewModel.toggleShared(record)
                            }
                            .tint(.teal)
                        }
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(family.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Add shared activity", systemImage: "plus") { viewModel.addActivity() }.disabled(writing)
            } }
            .refreshable { await viewModel.refresh() }
            .task(id: "\(viewModel.accountDataScope)-\(phase)") { await viewModel.monitor(active: phase == .active) }
            .sheet(item: $viewModel.selected, onDismiss: { Task { await viewModel.refresh() } }) { record in
                RecordEditor(record: record, sharedMembers: members, sourceFamily: family, onSave: { updated in
                    try await viewModel.save(updated)
                })
            }
            .confirmationDialog("Delete this activity for everyone in \(family.name)?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete shared activity", role: .destructive) { viewModel.deletePending() }
            }
            .disabled(writing)
    }


}

struct FamilyMembersView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var family: SharedFamily
    var body: some View {
        ViewModelHost(make: FamilyMembersViewModel(store: dependencies.store, account: dependencies.account, family: family)) { model in
            FamilyMembersViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct FamilyMembersViewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: FamilyMembersViewModel
    @State private var showInvite = false
    @State private var showRename = false

    private var family: SharedFamily { viewModel.family }
    private var removing: FamilyMember? {
        get { viewModel.removing }
        nonmutating set { viewModel.removing = newValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionBar
                householdSummary

                if let error = viewModel.error {
                    statusMessage(error, icon: "exclamationmark.circle.fill", color: DashboardPalette.red)
                }
                if let notice = viewModel.notice {
                    statusMessage(notice, icon: "checkmark.circle.fill", color: DashboardPalette.green)
                }

                if let owner = viewModel.ownerMember {
                    sectionHeader("Household owner", trailing: "Full access")
                    memberCard(owner, isOwner: true)
                }

                sectionHeader("Household members (\(viewModel.householdMembers.count))", trailing: "Shared access")
                if viewModel.householdMembers.isEmpty {
                    emptyMembers
                } else {
                    ForEach(viewModel.householdMembers) { member in memberCard(member, isOwner: false) }
                }

                if viewModel.owner && !viewModel.invitations.isEmpty {
                    sectionHeader("Pending invitations", trailing: viewModel.pendingSummary)
                    ForEach(viewModel.invitations) { invitation in invitationCard(invitation) }
                }

                if viewModel.owner {
                    HomePrimaryButton(title: "Invite new member", icon: "person.badge.plus") { showInvite = true }
                    Text("Invite using the exact email on their verified HomeMate account. They accept it from Family & sharing. Invitations expire after 6 days.")
                        .font(.caption).foregroundStyle(DashboardPalette.muted).padding(.horizontal, 6)
                }

                privacyNote
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Household Members").navigationBarTitleDisplayMode(.inline)
        .disabled(viewModel.busy)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onChange(of: viewModel.didLeave) { _, left in if left { dismiss() } }
        .overlay {
            if viewModel.busy {
                ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(isPresented: $showInvite) { inviteSheet }
        .alert("Rename household", isPresented: $showRename) {
            TextField("Household name", text: $viewModel.nameDraft)
            Button("Save") { viewModel.rename() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes the name for every accepted member.")
        }
        .confirmationDialog("Remove access to this family?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(removing?.id == viewModel.accountUserID ? "Leave household" : "Remove family access", role: .destructive) { viewModel.removePending() }
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "house.fill")
            Text("HomeMate").fontWeight(.semibold)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DashboardPalette.muted)
            Text(family.name).lineLimit(1)
            Spacer()
            Label("Synced", systemImage: "circle.fill")
                .font(.caption2.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .font(.caption).foregroundStyle(DashboardPalette.ink)
    }

    private var householdSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR HOUSEHOLD").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(DashboardPalette.muted)
                    Text(family.name).font(.title3.weight(.bold))
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashboardPalette.surface)
                    Capsule().fill(DashboardPalette.brandFill)
                        .frame(width: proxy.size.width * min(1, CGFloat(max(viewModel.members.count, 1)) / 6))
                }
            }.frame(height: 8).accessibilityHidden(true)
            HStack {
                Label(viewModel.memberSummary, systemImage: "person.2.fill").foregroundStyle(DashboardPalette.muted)
                Spacer()
            }
            .font(.footnote.weight(.medium))
            if viewModel.owner {
                HStack(spacing: 8) {
                    Spacer()
                    Button { viewModel.prepareRename(); showRename = true } label: { Label("Rename", systemImage: "pencil") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { showInvite = true } label: { Label("Invite", systemImage: "person.badge.plus") }
                        .buttonStyle(.borderedProminent).tint(DashboardPalette.brandFill).controlSize(.small)
                }
            }
        }
        .padding(16).homeCard(cornerRadius: 12)
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(1.25)
            Spacer()
            Text(trailing).font(.caption).foregroundStyle(DashboardPalette.muted)
        }.padding(.horizontal, 2)
    }

    private func memberCard(_ member: FamilyMember, isOwner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProfileAvatar(data: member.id == viewModel.accountUserID ? viewModel.profile.personalDetails?.avatarData : nil, name: member.displayName, size: isOwner ? 56 : 48)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(isOwner ? DashboardPalette.brandFill : Color.green).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                    }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(member.displayName).font(.headline)
                        if member.id == viewModel.accountUserID {
                            Text("You").font(.caption2.weight(.bold)).foregroundStyle(DashboardPalette.green)
                        }
                    }
                    Text(member.email).font(.subheadline).foregroundStyle(DashboardPalette.muted).textSelection(.enabled)
                    Label(isOwner ? "Owner · manages members and sharing" : "Member · shared household access", systemImage: isOwner ? "key.fill" : "person.fill.checkmark")
                        .font(.caption).foregroundStyle(DashboardPalette.green)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !isOwner && (viewModel.owner || member.id == viewModel.accountUserID) {
                    Menu {
                        Button(member.id == viewModel.accountUserID ? "Leave household" : "Remove member", role: .destructive) { removing = member }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle())
                    }.accessibilityLabel("Options for \(member.displayName)")
                }
            }
            HStack(spacing: 8) {
                Label(isOwner ? "Household administration" : "Activities, bills and chat", systemImage: isOwner ? "checkmark.shield" : "house.and.flag")
                Spacer()
                Text("Active")
            }
            .font(.caption).foregroundStyle(DashboardPalette.muted)
            .padding(10).background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16).homeCard(cornerRadius: 12)
    }

    private var emptyMembers: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.badge.plus").font(.title2).foregroundStyle(DashboardPalette.green)
            Text("No other members yet").font(.headline)
            Text("Invite someone with their verified HomeMate account email to share household activities, bills and chat.")
                .font(.footnote).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(24).homeCard(cornerRadius: 12)
    }

    private func invitationCard(_ invitation: FamilyInvitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge").foregroundStyle(DashboardPalette.green)
                    .frame(width: 42, height: 42).background(DashboardPalette.surface, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(invitation.email).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                    Text("Waiting for acceptance · expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(DashboardPalette.muted)
                }
            }
            HStack {
                ShareLink("Share instructions", item: "Join \(family.name) in HomeMate. Sign in with \(invitation.email), verify that email, then open More → Members to accept the invitation.")
                Spacer()
                Button("Cancel", role: .destructive) { viewModel.cancel(invitation) }
            }.font(.caption.weight(.semibold))
        }.padding(16).homeCard(cornerRadius: 12)
    }

    private var privacyNote: some View {
        Label("Members share household activities, bills and family chat. Personal profile details and private records stay private.", systemImage: "lock.shield")
            .font(.caption).foregroundStyle(DashboardPalette.muted)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DashboardPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusMessage(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.footnote).foregroundStyle(color)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).homeCard(cornerRadius: 12)
    }

    private var inviteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enter the email used for the member’s verified HomeMate account. This creates an invitation inside HomeMate; no email is sent. Use Share instructions afterward to notify them.").font(.subheadline).foregroundStyle(DashboardPalette.muted)
                TextField("family@example.com", text: $viewModel.email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().exactTextEntry()
                    .padding(14).background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                if !viewModel.email.isEmpty && !viewModel.validEmail {
                    Text("Enter a valid email address.").font(.caption).foregroundStyle(DashboardPalette.red)
                }
                HomePrimaryButton(title: "Create invitation", icon: "person.badge.plus") {
                    viewModel.invite()
                    showInvite = false
                }.disabled(!viewModel.validEmail)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Invite member").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showInvite = false } } }
        }.presentationDetents([.medium])
    }
}

struct SharedFamilyChatView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var family: SharedFamily
    var body: some View {
        ViewModelHost(make: SharedFamilyChatViewModel(store: dependencies.store, account: dependencies.account, family: family, context: dependencies.household)) { model in
            SharedFamilyChatViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope + ":" + dependencies.household.identity + ":" + family.id)
    }
}

private struct SharedFamilyChatViewScreen: View {


    @Environment(\.scenePhase) private var phase





    private var family: SharedFamily { viewModel.family }
    @ObservedObject var viewModel: SharedFamilyChatViewModel
    private var messages: [FamilyMessage] { get { viewModel.messages } nonmutating set { viewModel.messages = newValue } }
    private var text: String { get { viewModel.text } nonmutating set { viewModel.text = newValue } }
    private var error: String? { get { viewModel.error } nonmutating set { viewModel.error = newValue } }
    private var sending: Bool { get { viewModel.sending } nonmutating set { viewModel.sending = newValue } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text("Messages are shared with accepted members of \(family.name).")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(DashboardPalette.red)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DashboardPalette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if messages.isEmpty {
                        ContentUnavailableView("Start the conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Send a message for everyone in this household."))
                            .padding(.vertical, 52)
                    }
                    if viewModel.canLoadOlder {
                        Button {
                            Task { await viewModel.loadOlder() }
                        } label: {
                            if viewModel.loadingHistory { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
                            else { Label("Load older messages", systemImage: "arrow.up") .frame(maxWidth: .infinity, minHeight: 44) }
                        }
                        .buttonStyle(.bordered)
                    }
                    ForEach(messages) { message in messageBubble(message).id(message.id) }
                    Color.clear.frame(height: 2).id("chat-bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .task { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("Family chat").navigationBarTitleDisplayMode(.inline)
            .refreshable { await viewModel.load() }
            .task(id: "\(viewModel.accountDataScope)-\(phase)") { await viewModel.monitor(active: phase == .active) }
    }

    private func messageBubble(_ message: FamilyMessage) -> some View {
        let mine = message.authorID == viewModel.accountUserID
        return HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 52) }
            if !mine { ProfileAvatar(data: nil, name: message.authorName, size: 32) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine { Text(message.authorName).font(.caption.weight(.bold)).foregroundStyle(DashboardPalette.green) }
                Text(message.text).font(.body).foregroundStyle(mine ? .white : DashboardPalette.ink).textSelection(.enabled)
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(mine ? .white.opacity(0.78) : DashboardPalette.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(mine ? DashboardPalette.brandFill : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 52) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : message.authorName), \(message.text), \(message.date.formatted(date: .omitted, time: .shortened))")
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message your family", text: $viewModel.text, axis: .vertical)
                    .lineLimit(1...5).disabled(sending)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                Button { Task { await viewModel.send() } } label: {
                    Image(systemName: sending ? "hourglass" : "arrow.up")
                        .font(.headline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(DashboardPalette.brandFill, in: Circle())
                }
                .disabled(!viewModel.canSend).accessibilityLabel(sending ? "Sending message" : "Send message")
            }
            if text.count > 4000 { Text("Use at most 4,000 characters.").font(.caption).foregroundStyle(DashboardPalette.red) }
            if viewModel.failedDraft != nil {
                Button("Retry message", systemImage: "arrow.clockwise") { Task { await viewModel.retryFailed() } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(DashboardPalette.green)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

}

struct ShareRecordWithFamilyView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var record: HouseholdRecord
    var body: some View {
        ViewModelHost(make: ShareRecordViewModel(store: dependencies.store, account: dependencies.account, record: record)) { model in
            ShareRecordWithFamilyViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct ShareRecordWithFamilyViewScreen: View {


    @Environment(\.dismiss) private var dismiss





    @ObservedObject var viewModel: ShareRecordViewModel
    private var families: [SharedFamily] { get { viewModel.families } nonmutating set { viewModel.families = newValue } }
    private var error: String? { get { viewModel.error } nonmutating set { viewModel.error = newValue } }
    private var busy: Bool { get { viewModel.busy } nonmutating set { viewModel.busy = newValue } }
    private var shared: Bool { get { viewModel.shared } nonmutating set { viewModel.shared = newValue } }
    private var chosen: SharedFamily? { get { viewModel.chosen } nonmutating set { viewModel.chosen = newValue } }
    var body: some View {
        List {
            Section { Text("Choose a family to copy this activity into its shared space. Accepted members can see and edit the copy. Your original stays private and is not linked to later changes.").font(.footnote) }
            if let error { Text(error).foregroundStyle(.red) }
            if shared { Label("Shared successfully", systemImage: "checkmark.circle.fill").foregroundStyle(DashboardPalette.green) }
            if families.isEmpty { Text("Create or join a family in Settings → Family & sharing first.").foregroundStyle(.secondary) }
            ForEach(families) { family in
                Button(family.name) { Task { await viewModel.choose(family) } }
            }.disabled(busy || shared)
            if let chosen {
                Section("Shared assignment") {
                    Picker("Assign to", selection: $viewModel.assignee) {
                        ForEach(viewModel.members) { member in
                            Text(AssignmentDisplay.label(for: member.email, accountEmail: viewModel.accountEmail, localName: viewModel.profile.name, members: viewModel.members, shared: true)).tag(member.email)
                        }
                        Text("Everyone").tag("Everyone")
                    }
                    Button("Share with \(chosen.name)") { Task { await viewModel.share() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if busy { ProgressView() }
        }.navigationTitle("Share with family").navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .alert("Shared successfully", isPresented: $viewModel.shared) {
                Button("Done") { dismiss() }
            } message: { Text("The shared copy is assigned to the selected household member.") }
    }
}
