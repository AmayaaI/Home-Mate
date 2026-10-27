import Foundation
import Combine

@MainActor
final class MoreViewModel: ScreenViewModel {
    @Published private(set) var family: SharedFamily?
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var familyLoading = false
    @Published private(set) var familyMessage: String?
    private let settings: SettingsViewModel

    override init(store: HouseholdStore, account: CloudAccount, context: HouseholdContext? = nil) {
        settings = SettingsViewModel(store: store, account: account)
        super.init(store: store, account: account, context: context)
    }

    var displayName: String {
        let fullName = profile.personalDetails?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fullName.isEmpty ? fullName : !name.isEmpty ? name : "Your profile"
    }
    private var activeFamily: SharedFamily? { context?.family ?? family }
    private var activeMembers: [FamilyMember] {
        context?.family == nil ? members : (context?.members ?? [])
    }
    var householdTitle: String {
        let name = activeFamily?.name ?? profile.household
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Home" : name
    }
    var householdSubtitle: String {
        activeFamily != nil ? "Shared family household" : accountSignedIn ? "Your private household" : "Offline household"
    }
    var memberNames: [String] {
        guard activeFamily != nil, !activeMembers.isEmpty else { return [displayName] }
        return activeMembers.map { $0.displayName.isEmpty ? $0.email : $0.displayName }
    }
    var memberSummary: String {
        if familyLoading { return "Loading family…" }
        if activeFamily != nil { return "\(activeMembers.count) \(activeMembers.count == 1 ? "member" : "members")" }
        return "Set up family sharing"
    }
    var ownerSummary: String {
        if let owner = activeMembers.first(where: { $0.role == "owner" }) {
            return "\(owner.displayName.isEmpty ? owner.email : owner.displayName) · Owner"
        }
        return "\(displayName) · \(accountSignedIn ? "Your account" : "Local profile")"
    }
    var familyBadge: String {
        if familyLoading { return "…" }
        if activeFamily != nil { return "\(activeMembers.count)" }
        return accountSignedIn ? "Invite" : "Sign in"
    }
    var expensesCount: Int { monthlyExpenses.count }
    var pendingMaintenanceCount: Int { activeRecords.filter { $0.kind == .maintenance && !$0.completed }.count }
    var locatedRecords: [HouseholdRecord] {
        activeRecords.filter {
            !$0.completed && $0.kind != .expense && !($0.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.date < $1.date }
    }
    var notificationsEnabled: Bool {
        get { settings.notifications }
        set { settings.notifications = newValue }
    }
    func refreshFamily() async {
        guard isActive, !familyLoading else { return }
        if let context, context.family != nil {
            familyLoading = true
            defer { familyLoading = false }
            await context.refresh()
            guard isActive else { return }
            family = context.family
            members = context.members
            familyMessage = context.error
            return
        }
        guard accountSignedIn else {
            family = nil; members = []; familyMessage = nil
            return
        }
        let scope = accountDataScope
        familyLoading = true
        defer { familyLoading = false }
        do {
            if !accountEmailVerified {
                try await account.refreshIdentity()
                guard isCurrent(scope) else { return }
            }
            guard accountEmailVerified else {
                family = nil; members = []; familyMessage = nil
                return
            }
            let api = FamilyAPI(account: account)
            let families = try await api.families()
            guard isCurrent(scope) else { return }
            guard let selected = families.first else {
                family = nil; members = []; familyMessage = nil
                return
            }
            let currentMembers = try await api.members(familyID: selected.id)
            guard isCurrent(scope) else { return }
            family = selected; members = currentMembers; familyMessage = nil
        } catch {
            guard isCurrent(scope) else { return }
            family = nil; members = []
            familyMessage = "Family information couldn't load. Open Members to check your connection and membership."
        }
    }
}

@MainActor
final class CommunicationViewModel: ScreenViewModel {
    @Published private(set) var familyMessages: [FamilyMessage] = []
    @Published private(set) var sharedRecords: [HouseholdRecord] = []
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var announcements: [FamilyAnnouncement] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private let initialFamily: SharedFamily?
    var family: SharedFamily? {
        guard let initialFamily else { return nil }
        return context?.families.first(where: { $0.id == initialFamily.id }) ?? initialFamily
    }
    init(store: HouseholdStore, account: CloudAccount, family: SharedFamily?, context: HouseholdContext?) {
        self.initialFamily = family
        super.init(store: store, account: account, context: context)
    }

    var householdTitle: String {
        family?.name ?? (profile.household.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Home" : profile.household)
    }
    var contextSubtitle: String {
        family == nil ? "Private household communication" : "Shared messages and household activity"
    }
    var latestFamilyMessage: FamilyMessage? { familyMessages.last }
    var orderedAnnouncements: [FamilyAnnouncement] {
        family == nil ? preferences.resolvedPrivateNotices : FamilyAnnouncement.ordered(announcements)
    }
    var openSharedRecords: [HouseholdRecord] { sharedRecords.filter { !$0.completed } }
    var noticeRecords: [HouseholdRecord] {
        (family == nil ? personalRecords : sharedRecords)
            .filter { !$0.completed && ($0.important || $0.date < Date()) }
            .reduce(into: [UUID: HouseholdRecord]()) { $0[$1.id] = $1 }
            .values.sorted { $0.date < $1.date }
    }
    var hasAnnouncement: Bool { !orderedAnnouncements.isEmpty }
    var noticeCount: Int { noticeRecords.count + orderedAnnouncements.count }
    var chatCount: Int { familyMessages.count + personalMessages.count }
    func assigneeLabel(_ record: HouseholdRecord) -> String {
        AssignmentDisplay.label(for: record.assignee, accountEmail: account.email, localName: profile.name, members: members, shared: family != nil)
    }

    func load() async {
        guard isActive, let family, !loading else { return }
        let scope = accountDataScope
        loading = true; defer { loading = false }
        do {
            async let messages = FamilyAPI(account: account).messages(familyID: family.id)
            async let records = FamilyAPI(account: account).records(familyID: family.id)
            async let familyMembers = FamilyAPI(account: account).members(familyID: family.id)
            async let familyAnnouncements = FamilyAPI(account: account).announcements(familyID: family.id)
            let values = try await (messages, records, familyMembers, familyAnnouncements)
            guard isCurrent(scope) else { return }
            familyMessages = values.0; sharedRecords = values.1; members = values.2; announcements = values.3; error = nil
        } catch {
            guard isCurrent(scope) else { return }
            familyMessages = []; sharedRecords = []; members = []; announcements = []; self.error = error.localizedDescription
        }
    }

    func saveAnnouncement(_ value: FamilyAnnouncement) async throws {
        guard isActive else { throw FamilyError.invalid("The household changed. Reopen Notices and try again.") }
        if let problem = value.validationError { throw FamilyError.invalid(problem) }
        if family == nil {
            var updated = store.preferences
            var values = updated.resolvedPrivateNotices
            var saved = value
            saved.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.body = value.body.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.revision = "private"
            if let index = values.firstIndex(where: { $0.id == saved.id }) { values[index] = saved }
            else { values.append(saved) }
            updated.setPrivateNotices(values)
            guard store.updatePreferences(updated) else { throw FamilyError.invalid(store.error ?? "Could not save your private notice.") }
            return
        }
        guard isActive, let family, let context, context.family?.id == family.id else {
            throw FamilyError.invalid("Refresh and reopen this household before posting.")
        }
        let identity = context.identity
        try await context.saveAnnouncement(value, expectedIdentity: identity)
        await load()
    }
    func deleteAnnouncement(_ value: FamilyAnnouncement) async {
        if isActive, family == nil {
            var updated = store.preferences
            updated.setPrivateNotices(updated.resolvedPrivateNotices.filter { $0.id != value.id })
            if !store.updatePreferences(updated) { error = store.error ?? "Could not delete your private notice." }
            return
        }
        guard isActive, let family, let context, context.family?.id == family.id else {
            error = "Refresh and reopen this household before deleting."; return
        }
        await context.deleteAnnouncement(value)
        await load()
    }
    func canManage(_ announcement: FamilyAnnouncement) -> Bool {
        family == nil || announcement.authorID == accountUserID || family?.ownerID == accountUserID
    }
}
