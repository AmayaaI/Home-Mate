import Foundation
import Combine

/// Common read-only presentation state. Repositories and services are injected, never created by Views.
@MainActor
class ScreenViewModel: ObservableObject {
    // A Published anchor lets Combine share one publisher across inherited feature state.
    @Published private var repositoryRevision = 0
    let store: HouseholdStore
    let account: CloudAccount
    let initialScope: String
    let context: HouseholdContext?
    private let initialContext: String?
    private var observations = Set<AnyCancellable>()

    init(store: HouseholdStore, account: CloudAccount, context: HouseholdContext? = nil) {
        self.store = store
        self.account = account
        initialScope = account.dataScope
        self.context = context
        initialContext = context?.identity
        observe(store)
        observe(account)
        if let context { observe(context) }
    }

    func observe<T: ObservableObject>(_ object: T) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        object.objectWillChange.sink { [weak self] _ in self?.repositoryRevision &+= 1 }.store(in: &observations)
    }

    var profile: HouseholdProfile {
        var value = store.profile
        if let family = context?.family { value.household = family.name; value.currency = family.currency; value.members = context?.members.map(\.email).joined(separator: ",") ?? "" }
        return value
    }
    var preferences: HouseholdPreferences { context?.family == nil ? store.preferences : HouseholdPreferences() }
    var activeRecords: [HouseholdRecord] { context?.family == nil ? store.records : context?.records ?? [] }
    var personalRecords: [HouseholdRecord] { store.records }
    var personalMessages: [ChatMessage] { store.messages }
    var monthlyExpenses: [HouseholdRecord] { ExpenseIntelligence.spendingRecords(activeRecords, inMonthOf: Date()) }
    var recommendedMember: String {
        guard let context, context.family != nil else { return store.recommendedMember }
        return context.members.min { a, b in
            activeRecords.filter { !$0.completed && $0.kind != .expense && $0.assignee == a.email }.count < activeRecords.filter { !$0.completed && $0.kind != .expense && $0.assignee == b.email }.count
        }?.email ?? account.email
    }
    var storageError: String? { store.error }
    var accountSignedIn: Bool { account.signedIn }
    var accountEmailVerified: Bool { account.emailVerified }
    var accountEmail: String { get { account.email } set { account.email = newValue } }
    var accountPassword: String { get { account.password } set { account.password = newValue } }
    var accountRememberSession: Bool { get { account.rememberSession } set { account.rememberSession = newValue } }
    var accountMessage: String { get { account.message } set { account.message = newValue } }
    var accountBusy: Bool { account.busy }
    var accountIsError: Bool { account.isError }
    var accountConfigured: Bool { account.configured }
    var accountDataScope: String { account.dataScope }
    var accountUserID: String { account.userID }
    func money(_ amount: Double) -> String { amount.formatted(.currency(code: profile.currency)) }
    func toggle(_ record: HouseholdRecord) {
        guard isActive else { return }
        if let context, context.family != nil { Task { await context.toggle(record) } }
        else { store.toggle(record) }
    }
    func delete(_ record: HouseholdRecord) {
        guard isActive else { return }
        if let context, context.family != nil { Task { await context.delete(record) } }
        else { store.delete(record) }
    }
    func loadExamples() { guard isActive else { return }; store.loadExamples() }
    @discardableResult func replaceMessages(_ messages: [ChatMessage]) -> Bool { isActive && store.replaceMessages(messages) }
    func signOut() { guard initialScope == account.dataScope else { return }; account.signOut() }

    /// Every async screen operation can check that it still belongs to the same account.
    var isActive: Bool { initialScope == account.dataScope && store.scope == initialScope && (context == nil || initialContext == context?.identity) }
    func isCurrent(_ scope: String) -> Bool { scope == initialScope && isActive && !Task.isCancelled }
}
