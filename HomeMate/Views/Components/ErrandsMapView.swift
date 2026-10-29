import SwiftUI
import MapKit

struct ErrandsMapView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil
    @State private var selected: UUID?
    @State private var editing: HouseholdRecord?
    @State private var includeCompleted = false
    private var records: [HouseholdRecord] {
        (dependencies.household.family == nil ? dependencies.store.records : dependencies.household.records)
            .filter { ErrandMapPolicy.isVisible($0, includeCompleted: includeCompleted) }
            .sorted { $0.date < $1.date }
    }
    private var initialMapPosition: MapCameraPosition {
        let latitudes = records.filter(ErrandMapPolicy.hasPin).compactMap(\.latitude)
        let longitudes = records.filter(ErrandMapPolicy.hasPin).compactMap(\.longitude)
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else { return .automatic }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(180, max(0.01, (north - south) * 1.4)),
                                   longitudeDelta: min(360, max(0.01, (east - west) * 1.4)))))
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searching = false
    @State private var draft = HouseholdRecord(kind: .task, title: "")
    @State private var position: MapCameraPosition = .automatic
    private var selectedRecord: HouseholdRecord? { records.first { $0.id == selected } }
    private func addErrand() {
        editing = HouseholdRecord(kind: .task, title: "", assignee: dependencies.household.family == nil ? "Me" : dependencies.account.email)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Household", selection: Binding(get: { dependencies.household.family?.id ?? "private" }, set: { id in
                        selected = nil
                        dependencies.household.select(dependencies.household.families.first { $0.id == id })
                    })) {
                        Text("Private household").tag("private")
                        ForEach(dependencies.household.families) { family in Text(family.name).tag(family.id) }
                    }.pickerStyle(.menu)
                    Toggle("Include completed errands", isOn: $includeCompleted).font(.subheadline)
                    Text("Showing \(records.count) errands in this household. Only places with a saved map pin appear on the map.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        draft = HouseholdRecord(kind: .task, title: "", assignee: dependencies.household.family == nil ? "Me" : dependencies.account.email)
                        searching = true
                    } label: {
                        Label("Search Places", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }.accessibilityHint("Choose a place for a new errand")
                    errandsMap
                    if let record = selectedRecord {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(record.title, systemImage: record.kind.icon).font(.headline)
                            Text(record.location ?? "Saved place").foregroundStyle(.secondary)
                            Text(record.date, style: .date).font(.subheadline)
                            HStack {
                                Button("View errand") { editing = record }.buttonStyle(.bordered)
                                directions(record).buttonStyle(.borderedProminent)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())) {
                        Text("Saved errands").font(.title3.bold())
                        Spacer()
                        Button("Add Errand", systemImage: "plus", action: addErrand)
                            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 12))
                    }
                    if records.isEmpty {
                        Label("Your next stop starts here. Search for a place or add an errand, then choose its map location.", systemImage: "mappin.and.ellipse")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                selected = record.id
                                if let lat = record.latitude, let lon = record.longitude {
                                    position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(record.title, systemImage: record.kind.icon).font(.headline)
                                    Text(record.location ?? "Saved place").font(.subheadline)
                                    Text(record.completed ? "Completed" : record.date < Date() ? "Overdue · Pending" : "Upcoming · Pending").font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.foregroundStyle(.primary)
                            if ErrandMapPolicy.hasPin(record) { directions(record).font(.subheadline) }
                            else {
                                Button("Choose map location", systemImage: "mappin.and.ellipse") { editing = record }
                                Text("This address has no saved map pin yet.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    DisclosureGroup {
                        ArrivalPermissionView(service: dependencies.locations)
                    } label: { Label("Arrival reminders", systemImage: "location.circle") }
                    .padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Errands Map").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            if let onClose { onClose() } else { dismiss() }
                        } label: {
                            if onClose == nil { Text("Done") }
                            else { Label("Back", systemImage: "chevron.left") }
                        }
                    }
                }
                .tint(DashboardPalette.green)
                .onAppear { position = initialMapPosition }
                .refreshable { await dependencies.household.refresh() }
                .onChange(of: records.map(\.id)) { _, _ in position = initialMapPosition }
                .sheet(isPresented: $searching, onDismiss: {
                    if draft.latitude != nil { editing = draft }
                }) { ErrandPlacePicker(record: $draft) }
                .sheet(item: $editing) { record in
                    if !records.contains(where: { $0.id == record.id }) || !ErrandMapPolicy.hasPin(record) { RecordEditor(record: record) }
                    else { ErrandDetailView(record: record, service: dependencies.locations) }
                }
        }
    }
    private var errandsMap: some View {
                    Map(position: $position, selection: $selected) {
                        ForEach(records.filter(ErrandMapPolicy.hasPin)) { record in
                            if let latitude = record.latitude, let longitude = record.longitude {
                                Marker(record.title, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                                    .tint(DashboardPalette.green).tag(record.id)
                            }
                        }
                    }.mapControls { MapCompass(); MapScaleView() }
                        .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("Errands map. Saved places are also available in the list below.")
    }
    private func directions(_ record: HouseholdRecord) -> some View {
        ErrandDirectionsLink(record: record)
    }
}

enum ErrandMapPolicy {
    static func hasPin(_ record: HouseholdRecord) -> Bool {
        guard let lat = record.latitude, let lon = record.longitude else { return false }
        return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }
    static func isVisible(_ record: HouseholdRecord, includeCompleted: Bool) -> Bool {
        record.kind != .expense && (includeCompleted || !record.completed)
            && (hasPin(record) || !(record.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    static func directionsURL(_ record: HouseholdRecord, google: Bool) -> URL? {
        guard hasPin(record), let lat = record.latitude, let lon = record.longitude else { return nil }
        var url = URLComponents(string: google ? "https://www.google.com/maps/dir/" : "https://maps.apple.com/")
        url?.queryItems = google
            ? [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: "\(lat),\(lon)")]
            : [URLQueryItem(name: "daddr", value: "\(lat),\(lon)")]
        return url?.url
    }
}

struct ErrandDirectionsLink: View {
    let record: HouseholdRecord
    var body: some View {
        if let url = ErrandMapPolicy.directionsURL(record, google: false) {
            Link(destination: url) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .accessibilityLabel("Directions to \(record.title) in Apple Maps")
        }
    }
}

private struct ErrandDetailView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    var record: HouseholdRecord
    @ObservedObject var service: ErrandLocationService
    @State private var radius = 200.0
    private var eligible: Bool {
        !ErrandRegionPolicy.eligible([record], shared: dependencies.household.family != nil, email: dependencies.account.email, localName: dependencies.store.profile.name).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(record.title).font(.headline)
                    Text(record.location ?? "Saved location")
                    NavigationLink("View activity") { RecordDetailView(record: record, presentsAsSheet: false) }
                    NavigationLink("Edit activity") { RecordEditor(record: record) }
                    if ErrandMapPolicy.hasPin(record) { ErrandDirectionsLink(record: record) }
                }
                Section("Arrival reminder") {
                    Picker("Radius", selection: $radius) {
                        ForEach([100.0, 200.0, 500.0, 1000.0], id: \.self) { Text("\(Int($0)) metres").tag($0) }
                    }.onChange(of: radius) { _, value in if service.radius(for: record) != nil { service.setReminder(record, radius: value) } }
                    Toggle("Remind me when I arrive", isOn: Binding(get: { service.radius(for: record) != nil }, set: { service.setReminder(record, radius: $0 ? radius : nil) }))
                        .disabled(!eligible)
                    if !eligible { Text("Arrival reminders are available for incomplete errands assigned to you or Everyone.").font(.caption) }
                    ArrivalPermissionView(service: service)
                    Text("This preference is for this device only. No family member's location is shared. Arrival reminders may be delayed by iOS.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Errand")
                .toolbar { Button("Done") { dismiss() } }
                .onAppear { radius = service.radius(for: record) ?? 200 }
        }
    }
}

private struct ArrivalPermissionView: View {
    @ObservedObject var service: ErrandLocationService
    var body: some View {
        Text("Browse and search without location access. Background arrival reminders need Always location access and notifications.").font(.footnote)
        Text(service.status).font(.footnote).foregroundStyle(.secondary)
        if !service.notificationStatus.isEmpty { Text(service.notificationStatus).font(.footnote).foregroundStyle(.secondary) }
        Button(service.authorization == .authorizedWhenInUse ? "Allow background arrival reminders" : "Set up arrival permissions") { service.requestPermission() }
        if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open app settings", destination: url).task { service.refreshNotificationPermission() } }
    }
}

struct ErrandPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var record: HouseholdRecord
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search: MKLocalSearch?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Place, shop or address", text: $query).submitLabel(.search).onSubmit { findPlaces() }
                    Button("Search places", systemImage: "magnifyingglass") { findPlaces() }.disabled(loading || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    if loading { ProgressView("Searching…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Choose a result") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button {
                            record.latitude = item.placemark.coordinate.latitude
                            record.longitude = item.placemark.coordinate.longitude
                            record.location = item.name ?? item.placemark.title ?? query
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name ?? "Place").font(.headline)
                                Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section { Text("Place search uses Apple Maps and requires an internet connection. Your device location is not required to search.").font(.caption) }
            }.navigationTitle("Choose location")
                .toolbar { Button("Cancel") { search?.cancel(); dismiss() } }
                .onDisappear { search?.cancel() }
        }
    }
    private func findPlaces() {
        search?.cancel(); loading = true; error = nil
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        let operation = MKLocalSearch(request: request); search = operation
        Task { @MainActor in
            defer { if search === operation { loading = false } }
            do {
                let response = try await operation.start()
                guard search === operation else { return }
                results = response.mapItems
                if results.isEmpty { error = "No places found. Try a more specific address." }
            } catch { if search === operation { results = []; self.error = error.localizedDescription } }
        }
    }
}
