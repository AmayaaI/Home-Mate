import Foundation
import CoreLocation
import UserNotifications
import Combine

enum ErrandRegionPolicy {
    static func eligible(_ records: [HouseholdRecord], shared: Bool, email: String, localName: String) -> [HouseholdRecord] {
        records.filter {
            guard !$0.completed, [.task, .maintenance, .event].contains($0.kind), $0.latitude != nil, $0.longitude != nil, $0.validationError == nil else { return false }
            let assignee = $0.assignee.lowercased()
            return assignee == "everyone" || (shared ? assignee == email.lowercased() : ["me", localName.lowercased(), email.lowercased()].contains(assignee))
        }.sorted { $0.date < $1.date }
    }
    static func candidates(scopes: [String: [HouseholdRecord]], preferences: [String: Double], otherCount: Int) -> [(scope: String, record: HouseholdRecord)] {
        var desired: [(scope: String, record: HouseholdRecord)] = []
        for (scope, records) in scopes {
            for record in records {
                let key = scope + ":" + record.id.uuidString
                if let radius = preferences[key], validRadius(radius) {
                    desired.append((scope: scope, record: record))
                }
            }
        }
        desired.sort {
            if $0.record.date != $1.record.date { return $0.record.date < $1.record.date }
            return ($0.scope + $0.record.id.uuidString) < ($1.scope + $1.record.id.uuidString)
        }
        return Array(desired.prefix(max(0, 20 - max(0, otherCount))))
    }
    static func validRadius(_ value: Double) -> Bool { value.isFinite && (100...1000).contains(value) }
}

/// Region opt-ins are device-local and scoped to the active account/household.
/// Apple delivers region transitions; no continuous family location tracking is used.
@MainActor
final class ErrandLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var notificationStatus = ""
    @Published private(set) var monitoredCount = 0
    @Published private(set) var status = "Enable arrival reminders for saved errands."
    @Published private(set) var preferences: [String: Double]
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private var scopedRecords: [String: [HouseholdRecord]] = [:]
    private var activeIdentities: [String: String] = [:]
    var onArrivalTap: ((String, UUID) -> Void)?
    private var identity = ""
    private var activeRegions: [String: HouseholdRecord] = [:]
    private var activeRadii: [String: Double] = [:]
    private var delivered = Set<String>()
    nonisolated private static let prefix = "homemate.arrival."
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.dictionary(forKey: "errandArrivalPreferences") as? [String: Double] ?? [:]
        super.init()
        manager.delegate = self
        // CLLocationManager is created on the main actor; it delivers delegates on this run loop.
        UNUserNotificationCenter.current().delegate = self
        authorization = manager.authorizationStatus
        refreshNotificationPermission()
    }
    private func key(_ id: UUID) -> String { identity + ":" + id.uuidString }
    func radius(for record: HouseholdRecord) -> Double? { preferences[key(record.id)] }
    func setReminder(_ record: HouseholdRecord, radius: Double?) {
        if let radius, !ErrandRegionPolicy.validRadius(radius) { status = "Choose a radius between 100 and 1,000 metres."; return }
        preferences[key(record.id)] = radius
        defaults.set(preferences, forKey: "errandArrivalPreferences")
        reconcile()
    }
    func refreshNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = settings.authorizationStatus == .denied ? "Notifications are disabled. Enable notifications in Settings to receive arrival alerts." : ""
        }
    }
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        case .denied, .restricted: status = "Location access is denied. Enable Always location access in Settings for arrival reminders."
        case .authorizedAlways: reconcile()
        @unknown default: status = "Location access is unavailable."
        }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                if !allowed { notificationStatus = "Notifications are disabled. Enable them in Settings to receive arrival reminders." }
                else { notificationStatus = "" }
            } catch { status = error.localizedDescription }
        }
    }
    func update(scopes: [String: [HouseholdRecord]], identity: String, email: String, localName: String, enabled: Bool) {
        self.identity = identity
        scopedRecords = enabled ? scopes.mapValues { $0 } : [:]
        for scope in scopedRecords.keys {
            scopedRecords[scope] = ErrandRegionPolicy.eligible(scopedRecords[scope] ?? [], shared: !scope.hasSuffix(":private"), email: email, localName: localName)
        }
        reconcile()
    }
    private func reconcile() {
        let available = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        let authorised = manager.authorizationStatus == .authorizedAlways
        let otherCount = manager.monitoredRegions.filter { !$0.identifier.hasPrefix(Self.prefix) }.count
        let desired = scopedRecords.reduce(0) { count, pair in
            count + pair.value.filter { preferences[pair.key + ":" + $0.id.uuidString] != nil }.count
        }
        let candidates = available && authorised ? ErrandRegionPolicy.candidates(scopes: scopedRecords, preferences: preferences, otherCount: otherCount) : []
        var next: [String: HouseholdRecord] = [:], radii: [String: Double] = [:]
        activeIdentities = [:]
        for candidate in candidates {
            let record = candidate.record
            let key = candidate.scope + ":" + record.id.uuidString
            let id = Self.prefix + key
            next[id] = record
            activeIdentities[id] = candidate.scope
            radii[id] = min(preferences[key] ?? 200, max(100, manager.maximumRegionMonitoringDistance))
        }
        for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.prefix) {
            let record = next[region.identifier]
            let circle = region as? CLCircularRegion
            if record == nil || circle?.center.latitude != record?.latitude || circle?.center.longitude != record?.longitude || circle?.radius != radii[region.identifier] {
                manager.stopMonitoring(for: region); delivered.remove(region.identifier)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [region.identifier])
            }
        }
        activeRegions = next; activeRadii = radii
        for (id, record) in next {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            let existing = manager.monitoredRegions.first { $0.identifier == id } as? CLCircularRegion
            if existing?.center.latitude == latitude && existing?.center.longitude == longitude && existing?.radius == radii[id] { continue }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), radius: radii[id] ?? 200, identifier: id)
            region.notifyOnEntry = true; region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        monitoredCount = next.count
        if !available { status = "Region monitoring is unavailable on this device." }
        else if !authorised { status = "Arrival reminders need Always location access. If Location Services is disabled, enable it in Settings." }
        else if desired > candidates.count { status = "Monitoring \(candidates.count) upcoming errands. iOS allows up to 20 regions; later errands wait for space." }
        else { status = "\(next.count) arrival reminders configured on this device. Delivery depends on iOS location and notification permissions." }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus; reconcile()
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let record = activeRegions[region.identifier], !delivered.contains(region.identifier), manager.authorizationStatus == .authorizedAlways else { return }
        delivered.insert(region.identifier)
        let content = UNMutableNotificationContent()
        content.title = record.title
        content.body = "You are near \(record.location ?? "your saved errand location"). Open HomeMate to review this activity."
        content.sound = .default
        content.userInfo = ["recordID": record.id.uuidString, "householdContext": activeIdentities[region.identifier] ?? identity]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: region.identifier, content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.status = "Arrival reminder failed: " + error.localizedDescription } }
        }
    }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { delivered.remove(region.identifier) }
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) { status = "Could not monitor this location: " + error.localizedDescription }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.identifier.hasPrefix(Self.prefix),
           let scope = info["householdContext"] as? String,
           let raw = info["recordID"] as? String, let id = UUID(uuidString: raw) {
            Task { @MainActor [weak self] in self?.onArrivalTap?(scope, id) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
