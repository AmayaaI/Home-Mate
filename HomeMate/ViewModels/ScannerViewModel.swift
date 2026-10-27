import Foundation
import Combine
import PhotosUI
import SwiftUI
import Vision

@MainActor
final class ScannerViewModel: ScreenViewModel {
    @Published var photo: PhotosPickerItem?
    @Published var text = ""
    @Published var busy = false
    @Published var error: String?
    @Published var draft: HouseholdRecord?
    @Published var recordKind: RecordKind
    @Published var scannedImage: UIImage?
    @Published var provider = ""
    @Published var amountText = ""
    @Published var amountSourceLine: String?
    @Published var dueDate = Date()
    @Published var purchaseDate = Date()
    @Published var reference = ""
    @Published var category = "Other"
    private(set) var modelSuggestedCategory: String?
    @Published private(set) var categoryWasEdited = false
    @Published private(set) var categorySuggestionMessage = "Review the suggested category."
    func selectCategory(_ value: String) {
        category = value; categoryWasEdited = true
        categorySuggestionMessage = "Your category selection is preserved when OCR text is corrected."
    }
    @Published var notifyFamily = false
    @Published var savedRecord: HouseholdRecord?
    @Published var saving = false

    init(store: HouseholdStore, account: CloudAccount, initialKind: RecordKind, context: HouseholdContext? = nil) {
        recordKind = initialKind == .expense ? .expense : .bill
        super.init(store: store, account: account, context: context)
    }

    var splitMembers: [String] { profile.memberNames }
    var currency: String { profile.currency }
    var scanValidationError: String? {
        guard !text.isEmpty else { return "Scan or choose a receipt or bill first." }
        guard !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter the provider name." }
        guard let amount = parsedAmount, amount > 0 else { return "Enter a valid amount." }
        let record = scannedRecord(amount: amount)
        return record.validationError ?? record.expenseDateError()
    }
    var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var splitAmount: Double? {
        guard let amount = parsedAmount, !splitMembers.isEmpty else { return nil }
        return amount / Double(splitMembers.count)
    }

    private var scanGeneration = UUID()
    func recognize(_ image: UIImage) {
        guard let cgImage = image.cgImage else { error = "Unsupported image."; return }
        categoryWasEdited = false
        modelSuggestedCategory = nil
        scannedImage = image
        let generation = UUID(); scanGeneration = generation
        busy = true; error = nil
        Task {
            do {
                let result = try await ReceiptOCRService.recognize(cgImage)
                guard generation == scanGeneration, !Task.isCancelled else { return }
                text = result; busy = false
                if !result.isEmpty { populateBillFields(from: result) }
                if result.isEmpty { error = "No text found. Try a clearer photo." }
            } catch {
                guard generation == scanGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription; busy = false
            }
        }
    }
    private func populateBillFields(from value: String) {
        let fields = ReceiptFieldExtractor.extract(value)
        provider = fields.merchant ?? ""
        amountText = fields.amount.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
        amountSourceLine = fields.amountLine
        let defaultDueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        dueDate = max(fields.dueDate ?? defaultDueDate, Date())
        purchaseDate = fields.purchaseDate ?? Date()
        reference = fields.reference ?? ""
        if !categoryWasEdited {
            do {
                category = try ExpenseIntelligence.suggestCategory(value)
                modelSuggestedCategory = category
                categorySuggestionMessage = "Core ML suggestion · review and correct if needed."
            } catch {
                category = "Other"
                modelSuggestedCategory = nil
                categorySuggestionMessage = "Category model unavailable. Choose a category manually."
            }
        }
    }
    func applyEditedText(_ value: String) {
        let updated = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.isEmpty, updated.count <= 10_000 else {
            error = "Scanned text must be between 1 and 10,000 characters."
            return
        }
        text = updated
        populateBillFields(from: updated)
        savedRecord = nil
        error = nil
    }
    private func scannedRecord(amount: Double) -> HouseholdRecord {
        HouseholdRecord(kind: recordKind, title: provider.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount, date: recordKind == .expense ? purchaseDate : dueDate, category: category, referenceNumber: reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reference, notes: text)
    }
    func reviewVisibility() {
        guard isActive, scanValidationError == nil, let amount = parsedAmount else { return }
        draft = scannedRecord(amount: amount)
    }
    @discardableResult func saveScannedRecord() async -> Bool {
        guard isActive, !saving, scanValidationError == nil, let amount = parsedAmount else { return false }
        saving = true; defer { saving = false }
        let record = scannedRecord(amount: amount)
        if let context, context.family != nil {
            do { try await context.save(record, expectedIdentity: context.identity); guard isActive else { return false }; savedRecord = record; return true }
            catch { self.error = error.localizedDescription; return false }
        }
        guard store.upsert(record) else { error = store.error ?? "Could not save the record."; return false }
        savedRecord = record
        return true
    }
    func makeDraft(_ kind: RecordKind) {
        let lines = text.components(separatedBy: .newlines)
        let totals = lines.filter { $0.lowercased().contains("total") && !$0.lowercased().contains("subtotal") }
        let pattern = #"\d[\d,]*\.\d{2}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let candidate = totals.last ?? ""
        let range = NSRange(candidate.startIndex..., in: candidate)
        let matches = regex?.matches(in: candidate, range: range) ?? []
        let amount = matches.last.flatMap { Range($0.range, in: candidate) }.flatMap { Double(candidate[$0].replacingOccurrences(of: ",", with: "")) } ?? 0
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let date = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date ?? Date()
        draft = HouseholdRecord(kind: kind, title: lines.first ?? "Scanned receipt", amount: amount, date: date, category: categoryWasEdited ? category : ExpenseIntelligence.categorize(text), notes: text)
    }

    func loadPhoto(_ item: PhotosPickerItem?) async {
        do {
            guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { error = "Could not read that photo. Try another image."; return }
            recognize(image)
        } catch { self.error = error.localizedDescription }
    }
    var categoryModelReady: Bool { ExpenseIntelligence.categoryModelReady }
    var sharedHousehold: Bool { context?.family != nil }

}
