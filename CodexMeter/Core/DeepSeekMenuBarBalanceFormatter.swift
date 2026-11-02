import Foundation

nonisolated enum DeepSeekMenuBarBalanceFormatter {
    static func string(remaining: Decimal, currency: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        switch currency {
        case "CNY": formatter.currencySymbol = "¥"
        case "USD": formatter.currencySymbol = "$"
        default: break
        }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: remaining))
            ?? "\(formatter.currencySymbol ?? currency)\(NSDecimalNumber(decimal: remaining).stringValue)"
    }
}
