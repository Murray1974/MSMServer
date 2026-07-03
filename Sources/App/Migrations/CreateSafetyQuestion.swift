import Fluent

struct CreateSafetyQuestion: AsyncMigration {

    static let questions: [(text: String, answer: String, type: String, order: Int)] = [
        // ── Tell Me (7) ─────────────────────────────────────────────────────────
        (
            "Tell me how you would check that the brakes are working before starting a journey.",
            "Brakes should not feel spongy or slack. Test the brakes as you set off — the vehicle should not pull to one side.",
            "tell_me", 1
        ),
        (
            "Tell me where you would find the information for the recommended tyre pressures for this car and how tyre pressures should be checked.",
            "Manufacturer's guide. Use a reliable pressure gauge, check and adjust pressures when tyres are cold, don't forget the spare tyre, refit valve caps afterwards.",
            "tell_me", 2
        ),
        (
            "Tell me how you would check that the tyres have sufficient tread depth and that their general condition is safe to use on the road.",
            "No cuts or bulges, 1.6mm of tread depth across the central three-quarters of the breadth of the tyre and around the entire outer circumference.",
            "tell_me", 3
        ),
        (
            "Tell me how you would check that the headlights and tail lights are working. You don't need to exit the vehicle.",
            "Operate the switch (turn on ignition if necessary), then walk round the vehicle, or use reflections in a window or garage door.",
            "tell_me", 4
        ),
        (
            "Tell me how you would know if there was a problem with your anti-lock braking system.",
            "A warning light will illuminate on the dashboard if there is a fault with the anti-lock braking system.",
            "tell_me", 5
        ),
        (
            "Tell me how you would check the power-assisted steering is working before starting a journey.",
            "If the steering becomes heavy the system may not be functioning correctly. Before starting a journey, gently move the steering — it should feel light and responsive.",
            "tell_me", 6
        ),
        (
            "Tell me how the head restraint should be correctly adjusted to give you the best protection in the event of a crash.",
            "The rigid part of the head restraint should be at least as high as the eye or top of the ears, and as close to the back of the head as is comfortable.",
            "tell_me", 7
        ),
        // ── Show Me (7) ─────────────────────────────────────────────────────────
        (
            "When it's safe to do so, show me how you would wash and clear the rear windscreen.",
            "Operate the rear wash/wipe control (turn on ignition if necessary).",
            "show_me", 8
        ),
        (
            "When it's safe to do so, show me how you would switch on the rear fog light(s) and explain when you would use them.",
            "Operate the rear fog light switch (turn on dipped headlights and ignition if necessary). Use when visibility drops seriously below 100 metres — roughly the length of a football pitch.",
            "show_me", 9
        ),
        (
            "When it's safe to do so, show me how you would dip your headlights.",
            "Operate the headlight switch to the dipped position (turn on ignition if necessary).",
            "show_me", 10
        ),
        (
            "When it's safe to do so, show me how you would use the windscreen demister to clear all the windows effectively.",
            "Set the fans and heating controls to clear the windscreen and side windows. Use the air-conditioning if fitted to help remove moisture quickly.",
            "show_me", 11
        ),
        (
            "When it's safe to do so, show me how you would operate the windscreen washers and wipers.",
            "Operate the windscreen washer and wiper controls.",
            "show_me", 12
        ),
        (
            "Show me how you would check that the horn is working (off road only).",
            "Press the horn (turn on ignition if necessary).",
            "show_me", 13
        ),
        (
            "Show me how you would check the parking brake for excessive wear; make sure you keep safe control of the vehicle.",
            "Apply the parking brake — if it comes up more than a few notches it may need adjustment or inspection. Release it fully to ensure the vehicle moves freely.",
            "show_me", 14
        ),
    ]

    func prepare(on database: Database) async throws {
        try await database.schema("safety_questions")
            .id()
            .field("question_text",  .string, .required)
            .field("answer_text",    .string, .required)
            .field("type",           .string, .required)
            .field("display_order",  .int,    .required)
            .unique(on: "display_order")
            .create()

        for q in Self.questions {
            let row = SafetyQuestion(
                questionText: q.text,
                answerText:   q.answer,
                type:         q.type,
                displayOrder: q.order
            )
            try await row.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("safety_questions").delete()
    }
}
