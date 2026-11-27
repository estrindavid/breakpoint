import Foundation

// All break copy lives here (SPEC §2.2, §3.11): second person, present
// tense, titles 2–5 words, instructions ≤ 12 words, no "should", no "!", no medical claims, never
// "look away".

/// The rotating overlay title/instruction variants for each kind (SPEC §3.4).
public enum BreakCopyLibrary {
    /// Token replaced by the agent's display name in `walk` instructions.
    public static let agentToken = "{agent}"

    /// Each gives a tiny task at a distance, so the twenty seconds have something in them.
    public static let eyes = BreakCopy(kind: .eyes, variants: [
        .init(title: "Find something green far away",
              instruction: "A plant, a sign, a roof. Rest your eyes on it."),
        .init(title: "Count the windows in view",
              instruction: "Across the room or outside, as far as you can see."),
        .init(title: "Trace the far horizon line",
              instruction: "Or the top edge of the farthest wall, slowly."),
        .init(title: "Find three distant colours",
              instruction: "Name each one to yourself, then let your eyes rest."),
        .init(title: "Pick the smallest far-off thing",
              instruction: "Across the room or out a window. Keep it in focus."),
        .init(title: "Watch something far away",
              instruction: "Let your focus go soft until the timer ends."),
    ])

    /// `move` shows the current step's title and instruction; these are used before the routine
    /// starts (VoiceOver announcement, previews) and as a fallback.
    public static let move = BreakCopy(kind: .move, variants: [
        .init(title: "Time to stretch", instruction: "Two minutes, a few easy moves."),
        .init(title: "Loosen up", instruction: "Follow the steps at your own pace."),
        .init(title: "A two-minute stretch", instruction: "Slow and controlled, resting as needed."),
        .init(title: "Move a little", instruction: "A few short moves, one after another."),
        .init(title: "Step through a few moves", instruction: "One at a time, at your own pace."),
    ])

    /// `{agent}` is replaced by the agent's display name; without an agent the instruction is
    /// `walkInstructionNoAgent`.
    public static let walk = BreakCopy(kind: .walk, variants: [
        .init(title: "Take a walk", instruction: "We'll chime when {agent} needs you."),
        .init(title: "Stretch your legs", instruction: "Walk a lap. We'll chime when {agent} needs you."),
        .init(title: "Go for a short walk", instruction: "{agent} keeps working. We'll chime if it needs you."),
        .init(title: "Fetch some water", instruction: "Take the long way. We'll chime when {agent} needs you."),
        .init(title: "Step out for a while", instruction: "We'll chime when {agent} needs you."),
    ])
    public static let walkInstructionNoAgent = "Come back whenever you're ready."

    public static let breathe = BreakCopy(kind: .breathe, variants: [
        .init(title: "Breathe with the ring", instruction: "In as it grows, out as it shrinks."),
        .init(title: "Slow it down", instruction: "Breathe in as the ring grows, out as it shrinks."),
        .init(title: "One slow minute", instruction: "Follow the ring with your breath."),
        .init(title: "Breathe and settle", instruction: "In as it grows, out as it shrinks."),
    ])

    public static func copy(for kind: BreakKind) -> BreakCopy {
        switch kind {
        case .eyes: return eyes
        case .move: return move
        case .walk: return walk
        case .breathe: return breathe
        }
    }

    /// The variant for `kind` at `rotation`, with the agent token filled in.
    public static func variant(for kind: BreakKind, rotation: Int, agentName: String?) -> BreakCopy.Variant {
        var variant = copy(for: kind).variant(rotation: rotation)
        if kind == .walk {
            if let agentName {
                variant.instruction = variant.instruction.replacingOccurrences(of: agentToken, with: agentName)
            } else {
                variant.instruction = walkInstructionNoAgent
            }
        }
        return variant
    }

    /// "General wellness, not medical advice." (SPEC principle 4): About and the `move` screen.
    public static let wellnessDisclaimer = "General wellness, not medical advice."
}
