import Foundation
import Combine

@MainActor
final class StartupViewModel: ScreenViewModel {
    @Published var loadingProfile = false
    @Published var profileSyncError: String?
    private var profileTask: Task<Void, Never>?
    private var activatedScope: String?
    private var syncRunning = false
    private var syncAgain = false
    private var lastCloudUpdateTime: String?
    private var retryNotBefore: Date?
    private var consecutiveSyncFailures = 0
    @Published var showingSplash = true
    enum Route { case loading, login, welcome, main }
    var route: Route {
        if store.scope != account.dataScope || (loadingProfile && profileSyncError == nil) { return .loading }
        if !account.signedIn && !store.guestSessionActive { return .login }
        // A cloud outage/quota error must not trap a signed-in user on startup.
        // Let them use local screens and reach More/Sign out while sync retries.
        if profileSyncError != nil { return .main }
        return store.profile.onboarded ? .main : .welcome
    }
    var scope: String { store.scope }
    func continueOffline() { store.guestSessionActive = true }
    func activateAccount() {
        let scope = account.dataScope
        guard activatedScope != scope else { return }
        activatedScope = scope
        profileTask?.cancel()
        lastCloudUpdateTime = nil
        retryNotBefore = nil
        consecutiveSyncFailures = 0
        store.activate(userID: account.signedIn ? account.userID : nil)
        profileSyncError = nil
        loadingProfile = account.signedIn
        store.onAccountSaved = { [weak self] in
            guard let self else { return }
            Task { await self.syncProfile() }
        }
        profileTask = Task { [weak self] in
            guard let self else { return }
            await self.syncProfile()
            // Check for remote edits periodically. The manifest check is one read;
            // snapshot chunks are downloaded only when its update time changes.
            while !Task.isCancelled && self.account.dataScope == scope && self.account.signedIn {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await self.syncProfile()
            }
        }
    }
    func syncProfile(force: Bool = false) async {
        guard account.signedIn, store.scope == account.dataScope else { loadingProfile = false; return }
        if !force, let retryNotBefore, Date() < retryNotBefore { return }
        if syncRunning { syncAgain = true; return }
        syncRunning = true
        defer {
            syncRunning = false
            if syncAgain {
                syncAgain = false
                Task { await self.syncProfile() }
            }
        }
        let scope = account.dataScope
        let current = { self.account.dataScope == scope && self.store.scope == scope && !Task.isCancelled }
        do {
            try store.migrateVoiceAttachments()
            let local = store.accountSnapshot
            let baseline = store.accountBaseline
            let fetchedCloud = try await account.fetchAccountSnapshot(ifUnchangedSince: lastCloudUpdateTime)
            guard current() else { return }
            // If the manifest is unchanged, the persisted baseline is the remote
            // snapshot. Still run the merge so local edits can be uploaded.
            let cloud = fetchedCloud ?? CloudAccount.AccountCloudState(snapshot: baseline, updateTime: lastCloudUpdateTime)
            var syncedUpdateTime = cloud.updateTime
            let merged = try AccountSnapshot.merge(local: local, base: baseline, remote: cloud.snapshot)
            if try cloud.updateTime == nil || merged.encoded() != cloud.snapshot.encoded() {
                let writtenUpdateTime = try await account.uploadAccountSnapshot(merged, updateTime: cloud.updateTime)
                syncedUpdateTime = writtenUpdateTime
                guard current() else { return }
            }
            try store.acceptAccountSnapshot(merged, sent: local, expectedScope: scope)
            lastCloudUpdateTime = syncedUpdateTime
            if try store.accountSnapshot.encoded() != merged.encoded() { syncAgain = true }
            guard current() else { return }
            profileSyncError = nil
            loadingProfile = false
            consecutiveSyncFailures = 0
            retryNotBefore = nil
        } catch {
            guard current() else { return }
            profileSyncError = "Your account data has not synced yet. " + error.localizedDescription
            // Never show fresh onboarding over an existing cloud profile after a failed download.
            loadingProfile = false
            consecutiveSyncFailures += 1
            let retryDelay = min(3600, 60 * pow(2, Double(min(consecutiveSyncFailures - 1, 6))))
            retryNotBefore = Date().addingTimeInterval(retryDelay)
        }
    }
    func signedInChanged(from previous: Bool, to current: Bool) {
        if previous && !current { store.guestSessionActive = false }
        activateAccount()
    }
    func start() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") { continueOffline() }
        #endif
        async let pause: Void = Task.sleep(for: .seconds(1.25))
        if !store.guestSessionActive { await account.restoreSession() }
        do { try await pause } catch { return }
        activateAccount()
        showingSplash = false
    }
}
