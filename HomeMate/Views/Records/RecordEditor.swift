import SwiftUI

struct RecordEditor: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var record: HouseholdRecord
    var sharedMembers: [FamilyMember]? = nil
    var sourceFamily: SharedFamily? = nil
    var onSave: ((HouseholdRecord) async throws -> Void)? = nil
    var onSaved: (() -> Void)? = nil
    var correctedModelCategory: String? = nil
    private var isStoredPrivateRecord: Bool {
        sourceFamily == nil && onSave == nil && dependencies.store.records.contains(where: { $0.id == record.id })
    }
    private var effectiveMembers: [FamilyMember]? {
        if onSave != nil && sourceFamily == nil && sharedMembers == nil { return nil }
        if isStoredPrivateRecord { return nil }
        return sharedMembers ?? (dependencies.household.family == nil ? nil : dependencies.household.members)
    }
    private var effectiveSave: ((HouseholdRecord) async throws -> Void)? {
        if let onSave { return onSave }
        if isStoredPrivateRecord { return nil }
        guard dependencies.household.family != nil else { return nil }
        let context = dependencies.household, identity = context.identity
        return { record in try await context.save(record, expectedIdentity: identity) }
    }
    var body: some View {
        ViewModelHost(make: RecordEditorViewModel(store: dependencies.store, account: dependencies.account, record: record, sharedMembers: effectiveMembers, onSave: effectiveSave, context: onSave == nil ? dependencies.household : nil, sourceFamily: sourceFamily, correctedModelCategory: correctedModelCategory)) { model in
            RecordEditorScreen(viewModel: model, onSaved: onSaved)
        }.id(dependencies.household.identity)
    }
}

private struct RecordEditorScreen: View {
    @State private var titleWasEdited = false
    @State private var choosingPlace = false
    @State private var showingSaved = false



    @Environment(\.dismiss) var dismiss





    private var onSave: ((HouseholdRecord) async throws -> Void)? { viewModel.onSave }
    @ObservedObject var viewModel: RecordEditorViewModel
    var onSaved: (() -> Void)?
    private var cloudBusy: Bool { get { viewModel.cloudBusy } nonmutating set { viewModel.cloudBusy = newValue } }
    private var cloudMessage: String { get { viewModel.cloudMessage } nonmutating set { viewModel.cloudMessage = newValue } }
    private var record: HouseholdRecord { get { viewModel.record } nonmutating set { viewModel.record = newValue } }
    private var saving: Bool { get { viewModel.saving } nonmutating set { viewModel.saving = newValue } }
    private var saveError: String? { get { viewModel.saveError } nonmutating set { viewModel.saveError = newValue } }
    private var categoryMessage: String? { get { viewModel.categoryMessage } nonmutating set { viewModel.categoryMessage = newValue } }
    private var categoryFailed: Bool { get { viewModel.categoryFailed } nonmutating set { viewModel.categoryFailed = newValue } }
    private var reminderDate: Binding<Date> {
        Binding(
            get: { record.reminderDate ?? viewModel.defaultReminderDate ?? record.date.addingTimeInterval(-60) },
            set: { record.reminderDate = $0 }
        )
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: record.kind.icon).font(.system(size: 25)).foregroundStyle(DashboardPalette.green).frame(width: 58, height: 58).background(DashboardPalette.mint.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title.isEmpty ? "Make room for a plan." : record.title).font(.title3 .weight(.bold))
                            Text("The little details keep home running.").font(.caption).foregroundStyle(DashboardPalette.muted)
                        }
                    }.padding(.vertical, 10)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                taskVisibilitySection
                Section("Details") {
                    TextField("Title", text: $viewModel.record.title)
                        .onChange(of: viewModel.record.title) { _, _ in titleWasEdited = true }
                        .task(id: viewModel.record.title) {
                            if titleWasEdited { await viewModel.suggestAfterTitleChange() }
                        }
                    if record.kind == .bill || record.kind == .expense {
                        TextField("Amount", value: Binding<Double?>(
                            get: { viewModel.record.amount == 0 ? nil : viewModel.record.amount },
                            set: { viewModel.record.amount = $0 ?? 0 }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Amount")
                    }
                    if record.kind == .expense {
                        DatePicker("Expense date", selection: $viewModel.record.date, in: ...Date(), displayedComponents: .date)
                        Text("Choose when you paid. Past months and years are supported.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DatePicker(record.kind == .event ? "Starts" : "Due date", selection: $viewModel.record.date, in: Date()...Date.distantFuture)
                    }
                    if record.kind == .event {
                        Toggle("Add end time", isOn: Binding(get: { record.endDate != nil }, set: { record.endDate = $0 ? record.date.addingTimeInterval(3600) : nil }))
                        if record.endDate != nil {
                            DatePicker("Ends", selection: Binding(get: { max(record.endDate ?? record.date, record.date) }, set: { record.endDate = $0 }), in: max(record.date, Date())...)
                        }
                    }
                    TextField("Location (optional)", text: Binding(get: { record.location ?? "" }, set: { record.location = $0; record.latitude = nil; record.longitude = nil }))
                    if record.kind != .expense {
                        Button(record.latitude == nil ? "Choose map location" : "Change map location", systemImage: "mappin.and.ellipse") { choosingPlace = true }
                        if let latitude = record.latitude, let longitude = record.longitude {
                            Text("Saved map pin: \(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))").font(.caption).foregroundStyle(.secondary)
                            Button("Remove map pin", role: .destructive) { record.latitude = nil; record.longitude = nil }
                        }
                    }
                    if record.kind == .maintenance {
                        TextField("Technician phone (optional)", text: Binding(get: { record.contactPhone ?? "" }, set: { record.contactPhone = $0 })).keyboardType(.phonePad)
                    }
                    if record.kind != .event {
                        Picker("Category", selection: Binding(get: { viewModel.record.category }, set: { viewModel.chooseCategory($0) })) { ForEach(ExpenseIntelligence.categories, id: \.self) { Text($0) } }
                    }
                    if record.kind != .expense {
                        Toggle("Important", isOn: $viewModel.record.important)
                        Toggle(record.kind == .event ? "Event reminder" : "Deadline reminder", isOn: Binding(get: { record.reminderEnabled ?? true }, set: { record.reminderEnabled = $0 }))
                        if record.reminderEnabled != false, record.date > Date().addingTimeInterval(1) {
                            DatePicker("Remind me", selection: reminderDate, in: Date()...record.date.addingTimeInterval(-1))
                            Text("Choose the date and time before this activity when HomeMate should alert you.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Status", selection: $viewModel.record.completed) {
                            Text(record.kind == .bill ? "Unpaid" : "Pending").tag(false)
                            Text(record.kind == .bill ? "Paid" : "Completed").tag(true)
                        }
                    }
                    if record.kind == .bill {
                        TextField("Reference number (optional)", text: Binding(get: { record.referenceNumber ?? "" }, set: { record.referenceNumber = $0 }))
                            .textInputAutocapitalization(.characters)
                    }
                    TextField(record.kind == .bill ? "Notes (optional)" : "Notes / reference number", text: $viewModel.record.notes, axis: .vertical)
                }
                if let problem = viewModel.validationError {
                    Section { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                if viewModel.accountSignedIn && viewModel.taskVisibility == .privateTask && viewModel.existingTask {
                    Section("Family sharing") {
                        NavigationLink {
                            ShareRecordWithFamilyView(record: record)
                        } label: {
                            Label("Share with family", systemImage: "person.2.fill")
                        }
                        .disabled(viewModel.validationError != nil)
                        Text("A shared copy is visible to every accepted member. Your private original remains unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if record.kind == .expense || record.kind == .bill {
                    Section("On-device Core ML") {
                        Button("Suggest category") { viewModel.suggestCategory() }
                        if let categoryMessage { Text(categoryMessage).font(.caption).foregroundStyle(categoryFailed ? .red : DashboardPalette.green) }
                        Text("Demo model trained on English household expense examples. Review merchant names and unclear OCR carefully. Saved manual corrections keep only category-pair counts on this device; titles, receipt text and amounts are not recorded as feedback. The model is not retrained.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if record.kind == .event || record.kind == .task || record.kind == .maintenance {
                    Section("Apple Calendar") {
                        Button("Add to my Apple Calendar", systemImage: "calendar.badge.plus") { viewModel.prepareCalendarExport() }
                            .disabled(viewModel.validationError != nil)
                        if let message = viewModel.calendarMessage {
                            Text(message).font(.footnote).foregroundStyle(viewModel.calendarFailed ? .red : DashboardPalette.green)
                        }
                        Text("Review the item in Apple's editor, choose a calendar, then tap Add. This saves a separate personal copy; later changes are not synced.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let saveError { Section { Text(saveError).foregroundStyle(.red).font(.footnote) } }
                if saving { ProgressView("Saving…") }
                if viewModel.accountSignedIn && viewModel.taskVisibility == .privateTask && viewModel.existingTask && !viewModel.isTask {
                    Section("Firebase record") {
                        Button("Save record to cloud") { Task { await viewModel.uploadPrivateRecord() } }.disabled(cloudBusy || viewModel.validationError != nil)
                        if cloudBusy { ProgressView() }
                        if !cloudMessage.isEmpty { Text(cloudMessage).font(.caption) }
                        Text("Save in the toolbar keeps a local copy. Cloud uploads are explicit.").font(.caption)
                    }
                }
                Group {
                    Section {
                        Button(saving ? "Saving…" : viewModel.taskSaveTitle) {
                            Task {
                                if await viewModel.save() {
                                    if viewModel.savedDestination != nil { showingSaved = true }
                                    else { dismiss(); onSaved?() }
                                }
                            }
                        }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.borderedProminent).tint(Color(red: 20/255, green: 95/255, blue: 87/255))
                        .disabled(viewModel.validationError != nil || saving)
                    }.listRowBackground(Color.clear)
                }
            }.scrollContentBackground(.hidden)
                .background(HomeBackdrop())
                .navigationTitle("\(viewModel.existingTask ? "Edit" : "Add") \(viewModel.recordName)")
                .task { await viewModel.prepareEditor() }
                .task(id: "\(viewModel.taskVisibility.rawValue):\(viewModel.taskHouseholdID)") {
                    if !viewModel.taskHouseholds.isEmpty { await viewModel.loadTaskMembers() }
                }
                .sheet(isPresented: $choosingPlace) { ErrandPlacePicker(record: $viewModel.record) }
                .navigationBarTitleDisplayMode(.inline)
                .presentationCornerRadius(30)
                .interactiveDismissDisabled(saving)
                .alert("Saved successfully", isPresented: $showingSaved) {
                    if let family = viewModel.savedDestination {
                        Button("View in \(family.name)") {
                            viewModel.context?.select(family)
                            Task { await viewModel.context?.refresh() }
                            dismiss(); onSaved?()
                        }
                    }
                    Button("Done", role: .cancel) { dismiss(); onSaved?() }
                } message: {
                    Text("This record was saved to \(viewModel.savedDestination?.name ?? "your household"). Switch to that household to see it in lists, Dashboard and Calendar.")
                }
                .disabled(saving)
                .sheet(item: $viewModel.calendarDraft) { draft in
                    AppleCalendarEditor(draft: draft, onComplete: viewModel.completeCalendarExport)
                        .ignoresSafeArea()
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var taskVisibilitySection: some View {
        Section {
            Picker("Visibility", selection: Binding(get: { viewModel.taskVisibility }, set: { viewModel.changeVisibility($0) })) {
                ForEach(RecordEditorViewModel.TaskVisibility.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value).disabled(value == .shared && !viewModel.sharedAvailable)
                }
            }.pickerStyle(.segmented).disabled(viewModel.existingTask)
            if viewModel.taskVisibility == .privateTask {
                if viewModel.isTask { LabeledContent("Assigned to", value: "Me (You)") }
            } else {
                Picker("Household", selection: Binding(get: { viewModel.taskHouseholdID }, set: { viewModel.selectTaskHousehold($0) })) {
                    Text("Select household").tag("")
                    ForEach(viewModel.taskHouseholds) { Text($0.name).tag($0.id) }
                }.disabled(viewModel.existingTask || viewModel.loadingHouseholds)
                if viewModel.loadingHouseholds { ProgressView("Loading households…") }
                if !viewModel.taskHouseholdID.isEmpty && viewModel.supportsAssignment {
                    Picker("Assigned to", selection: $viewModel.record.assignee) {
                        if !viewModel.assigneeOptions.contains(where: { $0.id == record.assignee }) { Text("Select member").tag(record.assignee) }
                        ForEach(viewModel.assigneeOptions) { Text($0.title).tag($0.id) }
                    }.disabled(viewModel.loadingMembers)
                }
                if viewModel.loadingMembers { ProgressView("Loading members…") }
                if viewModel.membersError != nil || viewModel.householdsError != nil {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await viewModel.prepareEditor() } }
                }
                if viewModel.accountSignedIn && !viewModel.loadingHouseholds && viewModel.taskHouseholds.isEmpty {
                    Text("Create or join a household in More → Members to share records.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if viewModel.taskVisibility == .privateTask && viewModel.loadingHouseholds { ProgressView("Checking shared households…") }
            if viewModel.taskVisibility == .privateTask && viewModel.householdsError != nil {
                Button("Retry shared households") { Task { await viewModel.prepareEditor() } }
            }
        } header: { Text(viewModel.isTask ? "Task Visibility" : "Visibility") } footer: {
            Text(viewModel.taskVisibility == .privateTask ? (viewModel.isTask ? "Only you can see and manage this task." : "Only you can see this record.") : "Members of the selected household can see and manage this record.")
            if viewModel.existingTask { Text("Editing keeps this record in its original household.") }
        }
    }
}

struct RecordDetailView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var record: HouseholdRecord
    var presentsAsSheet = true

    @ViewBuilder
    var body: some View {
        if presentsAsSheet {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        ViewModelHost(make: RecordDetailViewModel(store: dependencies.store, account: dependencies.account, record: record, context: dependencies.household)) { model in
            RecordDetailScreen(viewModel: model, showsDoneButton: presentsAsSheet)
        }
        .id(dependencies.household.identity)
    }
}

private struct RecordDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: RecordDetailViewModel
    @State private var editing = false
    @State private var confirmDelete = false
    var showsDoneButton: Bool

    private var record: HouseholdRecord { viewModel.record }
    private var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var inset: Color { Color(uiColor: .tertiarySystemGroupedBackground) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusBadges
                titleCard
                if record.amount > 0 { amountCard }
                recommendationCard
                scheduleCard
                if !record.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notesCard }
                actions
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("\(record.kind.detailName) Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $editing) { RecordEditor(record: record) }
        .confirmationDialog("Delete \(record.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(record.kind.detailName.lowercased())", role: .destructive) {
                viewModel.remove()
                dismiss()
            }
        } message: {
            Text("This removes it from this device and cannot be undone.")
        }
    }

    private var statusBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                detailBadge(
                    viewModel.statusTitle,
                    icon: record.kind == .expense || record.completed ? "checkmark.circle.fill" : viewModel.isOverdue ? "calendar.badge.exclamationmark" : "clock.fill",
                    color: record.kind == .expense || record.completed ? DashboardPalette.green : viewModel.isOverdue ? DashboardPalette.red : .orange
                )
                if record.important { detailBadge("Important", icon: "exclamationmark", color: DashboardPalette.red) }
                if !record.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.category.caseInsensitiveCompare("Other") != .orderedSame {
                    detailBadge(record.category, icon: "tag.fill", color: DashboardPalette.muted)
                }
            }.padding(.vertical, 3)
        }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: record.kind.icon)
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(DashboardPalette.green)
                    .frame(width: 52, height: 52).background(DashboardPalette.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.kind.detailName.uppercased()).font(.caption2.weight(.bold)).tracking(1.35).foregroundStyle(DashboardPalette.muted)
                    Text(record.title).font(.title2.weight(.bold)).tracking(-0.45).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Label("Record ID", systemImage: "number")
                Spacer()
                Text(String(record.id.uuidString.prefix(8)).uppercased()).font(.caption.monospaced().weight(.semibold))
            }.font(.caption).foregroundStyle(DashboardPalette.muted)
        }
        .padding(16).background(surface, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 6, y: 2)
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.kind == .bill ? "BILL AMOUNT" : "AMOUNT")
                        .font(.caption2.weight(.bold)).tracking(1.25).foregroundStyle(DashboardPalette.muted)
                    Text(viewModel.money(record.amount)).font(.system(size: 28, weight: .bold, design: .rounded))
                }
                Spacer()
                Text(record.kind == .expense ? "Recorded" : record.completed ? (record.kind == .bill ? "Paid" : "Recorded") : "Outstanding")
                    .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(inset, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Label("Assigned to \(viewModel.assigneeLabel)", systemImage: "person.fill")
                Spacer()
                Text(record.category)
            }.font(.caption).foregroundStyle(DashboardPalette.muted)
                .padding(12).background(inset, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16).background(surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recommendationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.white)
                .frame(width: 36, height: 36).background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text("HOME RECOMMENDATION").font(.caption2.weight(.bold)).tracking(1.15).foregroundStyle(DashboardPalette.green)
                Text(viewModel.recommendation).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardPalette.green.opacity(colorScheme == .dark ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DashboardPalette.green.opacity(0.16)))
    }

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            detailRow(icon: "calendar", title: record.kind == .expense ? "Date" : record.kind == .event ? "Starts" : "Due date") {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
                    if record.kind != .expense && record.date < Date() && !record.completed { Text("Overdue").font(.caption2.weight(.bold)).foregroundStyle(DashboardPalette.red) }
                }
            }
            if record.kind == .bill, record.completed {
                Divider().padding(.leading, 58)
                detailRow(icon: "checkmark.circle", title: "Paid on") {
                    Text((record.paidAt ?? record.date).formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                }
            }
            if let reference = record.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty {
                Divider().padding(.leading, 58)
                detailRow(icon: "number", title: "Reference number") {
                    Text(reference).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                }
            }
            if let end = record.endDate {
                Divider().padding(.leading, 58)
                detailRow(icon: "clock", title: "Ends") { Text(end.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold)) }
            }
            Divider().padding(.leading, 58)
            detailRow(icon: "person.crop.circle", title: "Assigned to") {
                Text(viewModel.assigneeLabel).font(.subheadline.weight(.semibold))
            }
            if record.kind != .expense {
                Divider().padding(.leading, 58)
                detailRow(icon: "bell", title: "Reminder") {
                    Text(viewModel.reminderDescription).font(.caption).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.trailing)
                }
            }
            if let location = record.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().padding(.leading, 58)
                detailRow(icon: "mappin.and.ellipse", title: "Location") {
                    Text(location).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
                }
                if ErrandMapPolicy.hasPin(record) {
                    Divider().padding(.leading, 58)
                    detailRow(icon: "map", title: "Errand") {
                        ErrandDirectionsLink(record: record).font(.subheadline.weight(.semibold))
                    }
                }
            }
            if let phone = record.contactPhone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().padding(.leading, 58)
                detailRow(icon: "phone", title: "Contact") {
                    if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                        Link(phone, destination: url).font(.subheadline.weight(.semibold))
                    } else { Text(phone).font(.subheadline.weight(.semibold)) }
                }
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes", systemImage: "text.alignleft").font(.subheadline.weight(.semibold)).foregroundStyle(DashboardPalette.green)
            Text(record.notes).font(.subheadline).foregroundStyle(DashboardPalette.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if record.kind != .expense {
                Button { viewModel.toggleCompletion() } label: {
                    Label(viewModel.completionAction, systemImage: record.completed ? "arrow.uturn.backward" : "checkmark.circle.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(.white)
                        .background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(HomePressStyle())
            }
            HStack(spacing: 10) {
                Button { editing = true } label: {
                    Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 46)
                        .background(surface, in: RoundedRectangle(cornerRadius: 12))
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 46)
                        .background(surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }.font(.subheadline.weight(.semibold)).buttonStyle(HomePressStyle())
        }.padding(.top, 4)
    }

    private func detailBadge(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6).background(color.opacity(0.11), in: Capsule())
    }

    private func detailRow<Content: View>(icon: String, title: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(DashboardPalette.green).frame(width: 30, height: 30)
                .background(DashboardPalette.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.subheadline).foregroundStyle(DashboardPalette.muted)
            Spacer(minLength: 10)
            value()
        }.padding(14).frame(minHeight: 58)
    }
}

private extension RecordKind {
    var detailName: String {
        switch self {
        case .task: "Task"
        case .bill: "Bill"
        case .maintenance: "Maintenance"
        case .expense: "Expense"
        case .event: "Event"
        }
    }
}
