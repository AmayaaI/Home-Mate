import Foundation
import CoreGraphics
import Vision

/// Runs Vision work off the main thread. The ViewModel owns the resulting UI state.
enum ReceiptOCRService {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let observations = (request.results ?? []).sorted {
                        let firstY = $0.boundingBox.midY
                        let secondY = $1.boundingBox.midY
                        if abs(firstY - secondY) < 0.014 { return $0.boundingBox.minX < $1.boundingBox.minX }
                        return firstY > secondY
                    }
                    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    continuation.resume(returning: text)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Turns Vision's OCR lines into editable suggestions. It never invents a price
/// when the receipt has no reliable monetary candidate.
struct ReceiptExtractedFields {
    var merchant: String?
    var amount: Double?
    var amountLine: String?
    var purchaseDate: Date?
    var dueDate: Date?
    var reference: String?
}

enum ReceiptFieldExtractor {
    private struct Candidate {
        let amount: Double
        let line: String
        let score: Int
        let index: Int
    }

    static func extract(_ text: String) -> ReceiptExtractedFields {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let merchant = lines.prefix(8).first { line in
            line.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil &&
            !matches(line, #"\b(receipt|invoice|tax invoice|cash bill|date|time|tel|phone|total|amount|reference|account|thank you)\b"#) &&
            !matches(line, #"^\s*(?:Rs\.?|LKR|USD)?\s*[\d., ]+\s*$"#)
        }
        let amountCandidate = bestAmount(in: lines)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        func detectedDate(in line: String) -> Date? {
            detector?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))?.date
        }
        let dueDate = lines.first(where: { matches($0, #"\b(due date|payment due|pay by|due on)\b"#) }).flatMap(detectedDate)
        let purchaseDate = lines.first(where: {
            matches($0, #"\b(date|purchased|paid on|transaction date)\b"#) &&
            !matches($0, #"\b(due|payment due)\b"#)
        }).flatMap(detectedDate)
        let referenceLine = lines.first { matches($0, #"\b(reference|ref no|account no|invoice no|meter no)\b"#) }
        let reference = referenceLine.flatMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return ReceiptExtractedFields(
            merchant: merchant,
            amount: amountCandidate?.amount,
            amountLine: amountCandidate?.line,
            purchaseDate: purchaseDate,
            dueDate: dueDate,
            reference: reference
        )
    }

    private static func bestAmount(in lines: [String]) -> Candidate? {
        var candidates: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let score = labelScore(line)
            guard score >= 0 else { continue }
            let found = monetaryValues(in: line)
            for value in found {
                let confidence = score + (hasCurrency(line) ? 28 : 0) +
                    (hasDecimals(line) ? 18 : 0) +
                    (index >= lines.count / 2 ? 8 : 0)
                if confidence >= 35 {
                    candidates.append(Candidate(amount: value, line: line, score: confidence, index: index))
                }
            }
            if score >= 80 && found.isEmpty {
                for next in (index + 1)..<min(index + 3, lines.count) {
                    let nextLine = lines[next]
                    guard !matches(nextLine, #"\b(subtotal|tax|vat|discount|change|cash tendered)\b"#) else { continue }
                    for value in monetaryValues(in: nextLine) {
                        candidates.append(Candidate(amount: value, line: nextLine, score: score - 8, index: next))
                    }
                }
            }
        }
        return candidates.max {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.amount != $1.amount { return $0.amount < $1.amount }
            return $0.index < $1.index
        }
    }

    private static func labelScore(_ line: String) -> Int {
        if matches(line, #"\b(subtotal|sub total|discount|saving|change|cash|tender|vat|tax|quantity|qty|unit price|phone|tel|invoice no|account no|reference)\b"#) &&
            !matches(line, #"\b(grand total|net total|amount due|balance due|total payable|amount payable)\b"#) {
            return -1
        }
        if matches(line, #"\b(grand total|net total|amount due|balance due|total payable|amount payable|total due)\b"#) { return 130 }
        if matches(line, #"\b(total|amount paid|bill amount|payment amount)\b"#) { return 105 }
        if matches(line, #"\b(amount|payable|balance)\b"#) { return 70 }
        if matches(line, #"\b(date|time|card|auth|transaction|order|receipt|invoice|meter)\b"#) { return -1 }
        return 0
    }

    private static func monetaryValues(in line: String) -> [Double] {
        let pattern = #"(?<![A-Za-z0-9])(?:\d{1,3}(?:[ ,.]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return parseMoney(String(line[range]))
        }
    }

    private static func parseMoney(_ raw: String) -> Double? {
        var value = raw.replacingOccurrences(of: " ", with: "")
        let lastDot = value.lastIndex(of: ".")
        let lastComma = value.lastIndex(of: ",")
        if let lastDot, let lastComma {
            let decimalSeparator: Character = lastDot > lastComma ? "." : ","
            value = String(value.filter { $0.isNumber || $0 == decimalSeparator })
            if decimalSeparator == "," { value = value.replacingOccurrences(of: ",", with: ".") }
        } else if let comma = lastComma {
            let digitsAfter = value.distance(from: value.index(after: comma), to: value.endIndex)
            value = digitsAfter <= 2 ? value.replacingOccurrences(of: ",", with: ".") : value.replacingOccurrences(of: ",", with: "")
        } else if let dot = lastDot {
            let digitsAfter = value.distance(from: value.index(after: dot), to: value.endIndex)
            if digitsAfter == 3 { value = value.replacingOccurrences(of: ".", with: "") }
        }
        guard let amount = Double(value), amount > 0, amount <= 1_000_000_000 else { return nil }
        return amount
    }

    private static func hasCurrency(_ line: String) -> Bool {
        matches(line, #"(?:\bLKR\b|\bRs\.?\b|\bUSD\b|[$₹])"#)
    }
    private static func hasDecimals(_ line: String) -> Bool {
        matches(line, #"\d[.,]\d{2}\b"#)
    }
    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
