import Foundation

/// Single source of truth for the simplified UK sole-trader tax estimate used throughout
/// the Finance section (Income Tax above the personal allowance + Class 4 NI). Extracted
/// from `FinanceController.estimateTax` so `MTDController` can reuse the identical formula
/// instead of re-implementing it — both must always agree on the same figure for the same
/// net income.
enum TaxEstimator {
    static func estimate(onNet net: Decimal) -> Decimal {
        let personalAllowance = Decimal(12570)
        let taxableIncome = max(Decimal(0), net - personalAllowance)
        let incomeTax = taxableIncome * Decimal(0.20)

        let lowerProfitsLimit = Decimal(12570)
        let upperProfitsLimit = Decimal(50270)
        let class4Basic = max(Decimal(0), min(net, upperProfitsLimit) - lowerProfitsLimit) * Decimal(0.06)
        let class4Upper = max(Decimal(0), net - upperProfitsLimit) * Decimal(0.02)

        return incomeTax + class4Basic + class4Upper
    }
}
