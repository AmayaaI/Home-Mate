import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: CalendarViewModel(store: dependencies.store, account: dependencies.account, context: dependencies.household)) { model in
            CalendarViewScreen(viewModel: model)
        }.id(dependencies.household.identity)
    }
}

private struct CalendarViewScreen: View {

    @Environment(\.homeContentWidth) private var contentWidth
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var filterHeight: CGFloat = 44
    @State private var allHouseholds = false
    @State private var accessibleRecords: [HouseholdRecord] = []





    private let calendar = Calendar.current

    private var dayCellSize: CGFloat {
        let horizontalInsets: CGFloat = contentWidth >= 760 ? 104 : 64
        return min(42, max(30, (contentWidth - horizontalInsets) / 7))
    }



    @ObservedObject var viewModel: CalendarViewModel
    private var selectedDate: Date { get { viewModel.selectedDate } nonmutating set { viewModel.selectedDate = newValue } }
    private var visibleMonth: Date { get { viewModel.visibleMonth } nonmutating set { viewModel.visibleMonth = newValue } }
    private var filter: RecordKind? { get { viewModel.filter } nonmutating set { viewModel.filter = newValue } }
    private var editing: HouseholdRecord? { get { viewModel.editing } nonmutating set { viewModel.editing = newValue } }
    private var choosingDate: Bool { get { viewModel.choosingDate } nonmutating set { viewModel.choosingDate = newValue } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HomePageHeader(eyebrow: "Your household, at a glance", title: "Calendar", symbol: "calendar")
                        .padding(.bottom, 2)
                    Picker("Viewing", selection: $allHouseholds) {
                        Text(viewModel.context?.family?.name ?? "Private").tag(false)
                        Text("All Households").tag(true)
                    }.pickerStyle(.segmented)
                    VStack(spacing: 14) {
                        monthSwitcher
                        monthGrid
                    }
                    .padding(contentWidth >= 760 ? 24 : 16)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(DashboardPalette.green.opacity(colorScheme == .dark ? 0.16 : 0.08)))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.045), radius: 16, y: 7)
                    filters
                    agenda
                }.padding(.horizontal, contentWidth >= 760 ? 28 : 16).padding(.top, 18).padding(.bottom, 28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }.background(HomeBackdrop()).foregroundStyle(DashboardPalette.ink)
                .toolbar(.hidden, for: .navigationBar)
                .onChange(of: selectedDate) { _, date in
                    if !calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) { visibleMonth = date }
                }
                .sheet(item: $viewModel.editing) { record in
                    if record.title.isEmpty { RecordEditor(record: record) } else { RecordDetailView(record: record) }
                }
                .sheet(isPresented: $viewModel.choosingDate) {
                    NavigationStack {
                        DatePicker("Jump to date", selection: $viewModel.selectedDate, displayedComponents: .date).datePickerStyle(.graphical).padding()
                            .navigationTitle("Choose a date").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") { visibleMonth = selectedDate; choosingDate = false } }
                    }.presentationDetents([.medium, .large])
                }
        }
    }
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 16) {
            if allHouseholds {
                AccessibleRecordsList(kind: filter, date: selectedDate, onRecords: { accessibleRecords = $0 })
            } else {
            activityHeader
            if viewModel.activities.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 30)).foregroundStyle(DashboardPalette.green)
                    Text("A little breathing room").font(.body .weight(.semibold))
                    Text(filter == nil ? "Nothing scheduled for this day." : "No \(filter!.rawValue.lowercased()) on this day. Try another filter or add an activity.").font(.footnote).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity).homeCard()
            }
            ForEach(viewModel.activities) { record in activityCard(record) }
            }
        }
    }
    private var monthSwitcher: some View {
        HStack(spacing: 4) {
            Button { viewModel.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 40) }.accessibilityLabel("Previous month")
            Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                .font(.body.weight(.semibold))
                .foregroundStyle(DashboardPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Button { viewModel.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 40) }.accessibilityLabel("Next month")
            Spacer(minLength: 0)
            Button { viewModel.addActivity() } label: { Image(systemName: "plus").font(.headline .weight(.semibold)).frame(width: 40, height: 40).foregroundStyle(.white).background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 10)) }.accessibilityLabel("Add event or task")
        }.padding(.horizontal, 2)
    }
    private var filters: some View {
        Group {
            if contentWidth < 550 || dynamicTypeSize.isAccessibilitySize {
                let columns = dynamicTypeSize.isAccessibilitySize ? 1 : (contentWidth < 360 || dynamicTypeSize >= .xxLarge ? 2 : 3)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    filterPill("All activities", kind: nil, expands: true)
                    ForEach([RecordKind.task, .bill, .maintenance, .event, .expense]) { kind in
                        filterPill(kind == .event ? "Family events" : kind.rawValue, kind: kind, expands: true)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill("All activities", kind: nil)
                        ForEach([RecordKind.task, .bill, .maintenance, .event, .expense]) { kind in filterPill(kind == .event ? "Family events" : kind.rawValue, kind: kind) }
                    }.padding(.vertical, 2)
                }
            }
        }
    }
    private func filterPill(_ title: String, kind: RecordKind?, expands: Bool = false) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { filter = kind } } label: {
            HStack(spacing: 6) {
                Circle().fill(kind.map(color) ?? DashboardPalette.mint).frame(width: 8, height: 8)
                Text(title).font(.caption .weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                    .multilineTextAlignment(.center)
            }.padding(.horizontal, expands ? 8 : 12).padding(.vertical, 7)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: filterHeight)
                .foregroundStyle(filter == kind ? .white : DashboardPalette.muted)
                .background(filter == kind ? DashboardPalette.brandFill : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().stroke(filter == kind ? .clear : Color.gray.opacity(0.1)))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == kind ? .isSelected : [])
    }
    private var monthGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(viewModel.weekdayNames.enumerated()), id: \.offset) { _, day in Text(day.uppercased()).font(.caption2 .weight(.semibold)).foregroundStyle(DashboardPalette.muted).frame(maxWidth: .infinity) }
            }.padding(.bottom, 5)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(viewModel.month.days, id: \.self) { date in dayCell(date) }
            }
        }.padding(.top, 4)
    }
    private func dayCell(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let inMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let kinds = allHouseholds ? RecordKind.allCases.filter { kind in
            (filter == nil || filter == kind) && accessibleRecords.contains { $0.kind == kind && calendar.isDate($0.date, inSameDayAs: date) }
        } : viewModel.activityKinds(on: date)
        let count = allHouseholds ? accessibleRecords.filter { calendar.isDate($0.date, inSameDayAs: date) && (filter == nil || $0.kind == filter) }.count : viewModel.activityCount(on: date)
        return Button {
            selectedDate = date
            if !inMonth { visibleMonth = date }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))").font(.system(size: 13, weight: selected || calendar.isDateInToday(date) ? .bold : .medium))
                HStack(spacing: 2) { ForEach(kinds.prefix(3)) { kind in Circle().fill(selected ? .white : color(kind)).frame(width: 4, height: 4) } }.frame(height: 4)
            }.frame(width: dayCellSize, height: dayCellSize).foregroundStyle(selected ? .white : inMonth ? DashboardPalette.ink : Color.gray.opacity(0.45))
                .background(selected ? DashboardPalette.brandFill : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(calendar.isDateInToday(date) && !selected ? DashboardPalette.green.opacity(0.45) : .clear, lineWidth: 1.5))
                .frame(maxWidth: .infinity).frame(height: dayCellSize + 8)
        }.buttonStyle(.plain).accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(count) activities").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var activityHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduled Activities").font(.headline .weight(.semibold))
                Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.caption).foregroundStyle(DashboardPalette.muted)
            }
            Spacer()
            Text("\(viewModel.activities.count) \(viewModel.activities.count == 1 ? "activity" : "activities")").font(.caption2 .weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6).background(DashboardPalette.green.opacity(0.07), in: Capsule()).foregroundStyle(DashboardPalette.green)
        }.padding(.top, 4)
    }
    private func activityCard(_ record: HouseholdRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(viewModel.context?.family?.name ?? "Private", systemImage: viewModel.context?.family == nil ? "lock" : "person.2")
                .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.green)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(viewModel.timeLabel(record), systemImage: "clock").font(.caption).foregroundStyle(DashboardPalette.muted)
                    Text(record.title).font(.body .weight(.semibold)).strikethrough(record.completed)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(record.kind == .event ? "Family event" : record.kind.rawValue).font(.caption2 .weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(color(record.kind)).background(color(record.kind).opacity(0.12), in: Capsule())
            }
            HStack(spacing: 6) {
                ProfileAvatar(data: viewModel.assigneeLabel(record) == "Me" ? viewModel.profile.personalDetails?.avatarData : nil, name: viewModel.assigneeLabel(record), size: 24)
                Text(viewModel.assigneeLabel(record)).font(.caption .weight(.medium)).foregroundStyle(DashboardPalette.muted)
                Spacer()
                if record.amount > 0 { Text(viewModel.money(record.amount)).font(.system(size: 16, weight: .semibold)) }
                if record.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(DashboardPalette.green) }
            }
            if let location = record.location, !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(DashboardPalette.muted) }
            if !record.notes.isEmpty { Text(record.notes).font(.footnote).lineSpacing(3).foregroundStyle(DashboardPalette.muted).fixedSize(horizontal: false, vertical: true) }
            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1)
            HStack(spacing: 10) {
                if record.kind == .maintenance, let url = viewModel.phoneURL(record.contactPhone) {
                    Link(destination: url) { Label("Call technician", systemImage: "phone").font(.caption .weight(.semibold)) }.foregroundStyle(color(record.kind))
                } else if record.kind != .expense {
                    Button { viewModel.toggle(record) } label: { Label(record.completed ? "Reopen" : record.kind == .bill ? "Mark paid" : "Complete", systemImage: record.completed ? "arrow.uturn.backward" : "checkmark.circle").font(.caption .weight(.semibold)) }.foregroundStyle(color(record.kind))
                }
                Spacer()
                Button { editing = record } label: { Label("View details", systemImage: "arrow.up.right").font(.caption .weight(.semibold)) }.foregroundStyle(DashboardPalette.green)
            }
        }.padding(16).padding(.leading, 4).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(color(record.kind).opacity(colorScheme == .dark ? 0.10 : 0.055))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(color(record.kind).opacity(0.14)))
            .overlay(alignment: .leading) {
                Capsule().fill(color(record.kind).opacity(0.68)).frame(width: 4).padding(.vertical, 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: color(record.kind).opacity(colorScheme == .dark ? 0.04 : 0.07), radius: 10, y: 4)
    }
    private func color(_ kind: RecordKind) -> Color {
        switch kind {
        case .task: DashboardPalette.green
        case .bill: Color(red: 245/255, green: 158/255, blue: 11/255)
        case .maintenance: Color(red: 14/255, green: 165/255, blue: 233/255)
        case .event: Color(red: 168/255, green: 85/255, blue: 247/255)
        case .expense: Color(red: 217/255, green: 119/255, blue: 6/255)
        }
    }




}
