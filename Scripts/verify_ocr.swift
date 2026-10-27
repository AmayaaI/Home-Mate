import Foundation

@main
struct VerifyOCR {
    static func main() throws {
        func expect(_ text: String, amount: Double?, merchant: String? = nil) throws {
            let result = ReceiptFieldExtractor.extract(text)
            guard result.amount == amount, merchant == nil || result.merchant == merchant else {
                throw NSError(
                    domain: "HomeMateOCRTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected \(String(describing: amount)) from \(merchant ?? "receipt"), got \(String(describing: result.amount)) and \(String(describing: result.merchant))"]
                )
            }
        }
        try expect("""
        KEELLS
        Date: 21/10/2026
        Subtotal 1200.00
        VAT 100.00
        TOTAL RS. 1,300.00
        Cash 1500.00
        Change 200.00
        """, amount: 1300, merchant: "KEELLS")
        try expect("""
        CEB
        Account No: 12345678
        Amount Due
        LKR 12,345.67
        Due Date: 30/10/2026
        """, amount: 12345.67, merchant: "CEB")
        try expect("Food City\nGrand Total 2,400\nThank you", amount: 2400, merchant: "Food City")
        try expect("Store\nTotal: 1.250,50", amount: 1250.5, merchant: "Store")
        try expect("Shop\nTOTAL\nRs 450", amount: 450, merchant: "Shop")
        try expect("Shop\nDate 21/10/2026\nMilk 120.00\nPhone 0771234567", amount: nil)
        print("PASS: OCR total extraction for receipts, utility bills, split total lines, LKR/Rs, decimal formats and missing totals")
    }
}
