import SwiftUI

struct CloudRecordsView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: CloudRecordsViewModel(store: dependencies.store, account: dependencies.account)) { model in
            CloudRecordsViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct CloudRecordsViewScreen: View {





    @ObservedObject var viewModel: CloudRecordsViewModel
    private var records: [HouseholdRecord] { get { viewModel.records } nonmutating set { viewModel.records = newValue } }
    private var busy: Bool { get { viewModel.busy } nonmutating set { viewModel.busy = newValue } }
    private var message: String { get { viewModel.message } nonmutating set { viewModel.message = newValue } }
    private var selected: HouseholdRecord? { get { viewModel.selected } nonmutating set { viewModel.selected = newValue } }
    private var pendingDelete: HouseholdRecord? { get { viewModel.pendingDelete } nonmutating set { viewModel.pendingDelete = newValue } }
    var body: some View {
        List {
            Section {
                Text("Your private cloud records. Open one to edit, then choose Save record to cloud. Toolbar Save imports it locally. Snapshot backups are separate.").font(.caption)
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption) }
            }
            ForEach(records) { record in
                Button { selected = record } label: {
                    Label(record.title, systemImage: record.kind.icon)
                }.swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = record }
                }
            }
        }.homeListChrome().navigationTitle("Cloud records")
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await viewModel.load() } }.disabled(busy) }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .sheet(item: $viewModel.selected) { RecordEditor(record: $0) }
            .confirmationDialog("Delete this cloud record?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete cloud copy", role: .destructive) { Task { await viewModel.deletePending() } }
            }
    }

}
