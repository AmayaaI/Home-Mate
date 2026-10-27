import SwiftUI
import EventKit
import EventKitUI

/// iOS 17+ lets the person save through this system editor without granting
/// HomeMate access to read their existing calendars or events.
struct AppleCalendarEditor: UIViewControllerRepresentable {
    let draft: CalendarEventDraft
    let onComplete: (CalendarExportOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let event = EKEvent(eventStore: context.coordinator.eventStore)
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.timeZone = .current
        event.location = draft.location
        event.notes = draft.notes
        controller.eventStore = context.coordinator.eventStore
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let eventStore = EKEventStore()
        private let onComplete: (CalendarExportOutcome) -> Void
        init(onComplete: @escaping (CalendarExportOutcome) -> Void) { self.onComplete = onComplete }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onComplete(action == .saved ? .saved : .cancelled)
        }
    }
}
