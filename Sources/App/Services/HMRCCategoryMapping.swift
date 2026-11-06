import Foundation

/// Maps this app's free-form `ExpenseEntry.category` slugs (defined client-side in
/// `allExpenseCategories`, `Instructor-server-side-app/.../Finance/ExpenseEntrySheet.swift`)
/// to HMRC's standard self-employment expense categories, for the Making Tax Digital
/// quarterly export. Any category not explicitly listed falls back to "Other business
/// expenses" rather than being silently dropped from the export.
enum HMRCCategoryMapping {
    private static let mapping: [String: String] = [
        // Professional
        "adi_registration": "Other business expenses",
        "professional_insurance": "Rent, rates, power and insurance costs",
        "association_membership": "Other business expenses",
        "dbs_check": "Other business expenses",
        // Vehicle
        "car_insurance": "Car, van and travel expenses",
        "road_tax": "Car, van and travel expenses",
        "mot": "Car, van and travel expenses",
        "servicing": "Car, van and travel expenses",
        "tyres": "Car, van and travel expenses",
        "breakdown_cover": "Car, van and travel expenses",
        "valeting": "Car, van and travel expenses",
        "vehicle_finance": "Interest on bank and other loans",
        "capital_allowance": "Capital allowances (claimed separately — not a standard expense box)",
        "insurance_excess": "Car, van and travel expenses",
        // Equipment
        "dual_controls": "Repairs and renewals of property and equipment",
        "l_plates": "Repairs and renewals of property and equipment",
        "sat_nav": "Repairs and renewals of property and equipment",
        "dashcam": "Repairs and renewals of property and equipment",
        // Marketing
        "website": "Advertising or marketing",
        "signage": "Advertising or marketing",
        "advertising": "Advertising or marketing",
        "print": "Advertising or marketing",
        // Teaching
        "theory_materials": "Phone, fax, stationery and other office costs",
        "stationery": "Phone, fax, stationery and other office costs",
        "equipment": "Repairs and renewals of property and equipment",
        // Admin
        "phone": "Phone, fax, stationery and other office costs",
        "accountant": "Accountancy, legal and other professional fees",
        "software": "Phone, fax, stationery and other office costs",
        "postage": "Phone, fax, stationery and other office costs",
        "bank_charges": "Bank, credit card and other financial charges",
        // Training
        "cpd_course": "Other business expenses",
        "first_aid": "Other business expenses",
        "standards_check": "Other business expenses",
        // Other
        "other": "Other business expenses"
    ]

    static func hmrcCategory(for appCategory: String) -> String {
        mapping[appCategory.lowercased()] ?? "Other business expenses"
    }
}
