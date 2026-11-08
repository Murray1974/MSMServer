import Vapor
import Fluent
import Leaf

/// The public marketing website (murrayschoolofmotoring.co.uk) — separate from the
/// digital business card (/card) and the JSON API. Pages are static content (reviews,
/// FAQ, areas covered) plus a few live fields pulled from InstructorSettings, same as
/// /card. Leaf templates live in Resources/Views/.
struct WebsiteController {

    // MARK: - Shared fields every page needs (for base.leaf's header/footer/JSON-LD)

    private struct SiteBasics {
        let instructorName: String
        let rate: String
        let contactPhone: String
        let currentYear: String
    }

    private func siteBasics(on db: Database) async throws -> SiteBasics {
        let settings = try await InstructorSettings.current(on: db)
        let instructorUser = try await User.query(on: db)
            .filter(\.$role == "instructor")
            .first()
        let year = Calendar.current.component(.year, from: Date())
        return SiteBasics(
            instructorName: instructorUser?.displayName ?? "Your Instructor",
            rate: String(format: "£%.2f/hr", Double(settings.currentHourlyRatePence) / 100),
            contactPhone: settings.contactPhone ?? "",
            currentYear: String(year)
        )
    }

    // MARK: - Home

    private struct HomeContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
        let testimonials: [Testimonial]
    }

    func home(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = HomeContext(
            title: "Driving Lessons in Exeter, Crediton & Tiverton",
            description: "Calm, patient driving lessons with Murray School of Motoring, covering Exeter, Crediton, Copplestone, Bow, Tiverton and surrounding areas.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear,
            testimonials: Array(Self.testimonials.prefix(2))
        )
        return try await req.view.render("home", context)
    }

    // MARK: - Lessons & Pricing

    private struct PricingContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
    }

    func lessonsPricing(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = PricingContext(
            title: "Lessons & Pricing",
            description: "Current driving lesson rates with Murray School of Motoring — \(basics.rate).",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear
        )
        return try await req.view.render("pricing", context)
    }

    // MARK: - About

    private struct AboutContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
    }

    func about(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = AboutContext(
            title: "About Mike",
            description: "Meet Mike, your driving instructor at Murray School of Motoring.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear
        )
        return try await req.view.render("about", context)
    }

    // MARK: - Areas Covered

    private struct AreasContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
        let areas: [String]
    }

    func areasCovered(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = AreasContext(
            title: "Areas Covered",
            description: "Driving lessons covering Exeter, Crediton, Copplestone, Bow, Tiverton and surrounding areas.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear,
            areas: ["Exeter", "Crediton", "Copplestone", "Bow", "Tiverton"]
        )
        return try await req.view.render("areas", context)
    }

    // MARK: - Reviews

    struct Testimonial: Encodable {
        let quote: String
        let name: String
    }

    static let testimonials: [Testimonial] = [
        .init(quote: "Mike is amazing! After having a driving instructor who definitely didn't suit me, Mike built up my confidence completely in the short time we had before my test. I felt so calm every lesson as did he. Couldn't recommend a better instructor. Very considerate and such a great teacher, so knowledgeable.", name: "Ella-May Jevons"),
        .init(quote: "I've recently passed my test first time after completing a week's intensive with Mike! The level of training and standard of lesson were great! I've had lessons in the past but none matched the quality Mike provided! One happy man now — thanks so much mate!!", name: "Jason Williams"),
        .init(quote: "Having spent many years believing I would never be able to drive, I was lucky enough to find Mike. He immediately put me at ease, teaching me at my pace and reassuring me at every opportunity. With Mike's knowledge, patience and belief I was able to pass my test. Mike is a really nice guy and an excellent instructor and I would thoroughly recommend him.", name: "Sarah Langrish"),
        .init(quote: "Mike is a great instructor. I went with him after not getting on with my first one. I was very nervous to begin with and he automatically put me at ease. He has taught me the knowledge to not only pass my test but the skills to become a better and more confident driver. I would highly recommend him to anybody learning to drive!", name: "Chloe Robbins"),
        .init(quote: "Mike was an amazing instructor. I went to him after not getting on with my previous instructor and he was so patient with me. I may have passed fourth time but he didn't give up on me. He was lovely to get on with and I would gladly recommend him to anyone.", name: "Tamsin Harvey"),
        .init(quote: "Passed first time with Mike's help! Really friendly guy, made me feel at ease as I was very nervous to begin with. Teaches you skills not only to help you pass but to use for the rest of your life.", name: "Lauren Brant"),
    ]

    private struct ReviewsContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
        let testimonials: [Testimonial]
    }

    func reviews(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = ReviewsContext(
            title: "Reviews",
            description: "What pupils say about learning to drive with Murray School of Motoring.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear,
            testimonials: Self.testimonials
        )
        return try await req.view.render("reviews", context)
    }

    // MARK: - FAQ

    struct FAQItem: Encodable {
        let question: String
        let answer: String
    }

    private struct FAQContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
        let faqs: [FAQItem]
    }

    func faq(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let faqs: [FAQItem] = [
            .init(question: "What do I need for my first lesson?", answer: "Just your provisional driving licence (both the photo card and, if you still have it, the paper counterpart), and glasses or contact lenses if you need them to drive. Wear flat, comfortable shoes."),
            .init(question: "Do you offer intensive courses?", answer: "Yes — if you're working towards a test date or just want to make faster progress, intensive blocks of lessons can be arranged alongside regular weekly lessons."),
            .init(question: "I had a bad experience with another instructor — will that affect my lessons with you?", answer: "Not at all. A good number of my pupils come to me after not getting on with a previous instructor, and lessons are built around putting you at ease and rebuilding your confidence at your own pace."),
            .init(question: "Is the driving test taken in your car?", answer: "Yes, in the dual-control instructor car you've trained in, insured and ready for test use."),
            .init(question: "What areas do you cover?", answer: "Exeter, Crediton, Copplestone, Bow, Tiverton and the surrounding areas — see the Areas Covered page for more."),
            .init(question: "How do I pay for lessons?", answer: "Through the MSM Student app, or by other arrangement — just ask."),
        ]
        let context = FAQContext(
            title: "FAQ",
            description: "Frequently asked questions about driving lessons with Murray School of Motoring.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear,
            faqs: faqs
        )
        return try await req.view.render("faq", context)
    }

    // MARK: - Book a Lesson
    //
    // Points to the student app rather than a direct enquiry form for now — simpler,
    // and sidesteps the SendGrid dependency entirely. Revisit the enquiry-form approach
    // later if wanted; WebsiteController+Enquiry.swift.disabled-ish isn't kept around,
    // just removed outright since it's trivial to rebuild from this commit if needed.

    private struct BookContext: Encodable {
        let title, description: String
        let instructorName, rate, contactPhone, currentYear: String
    }

    func bookShow(_ req: Request) async throws -> View {
        let basics = try await siteBasics(on: req.db)
        let context = BookContext(
            title: "Book a Lesson",
            description: "Download the MSM Student app to book driving lessons with Murray School of Motoring.",
            instructorName: basics.instructorName, rate: basics.rate,
            contactPhone: basics.contactPhone, currentYear: basics.currentYear
        )
        return try await req.view.render("book", context)
    }
}
