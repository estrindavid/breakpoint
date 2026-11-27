import BreakpointCore
import BreakpointRuntime
import Foundation

/// How a card is drawn at one moment, beyond its `CardState`.
struct PopupCardLook {
    /// The pointer is over the card: the ×, the resume card's keycap.
    var hovering = false
    /// The time rim, while the card hides itself (§3.5).
    var rim: PopupRimFrame?
    /// The resume card's dismiss shortcut, while it reaches the card ("Ctrl+Alt+Win+.").
    var dismissKey: String?
    /// The wind-down card has the keyboard (after a click into it): Done shows its Esc keycap.
    var isKey = false
    /// "15 more minutes": the fill 0…1, and whether it is held down now.
    var holdProgress: Double = 0
    var holding = false
    /// "Copy note" just copied: it says "Copied" for 1.6 s.
    var copied = false
}

/// What a card's controls do (each card uses its own).
struct PopupCardHandlers {
    /// ×, a click on a resume card, Later, Close, Done: `dismissCard`.
    var close: () -> Void = {}
    /// Undo on the away note.
    var undo: () -> Void = {}
    /// Resume on the call-pause toast.
    var resume: () -> Void = {}
    var update: () -> Void = {}
    var openPage: () -> Void = {}
    /// A click on "15 more minutes" (acts only when the hold is 0 s; the controller times holds).
    var holdClick: () -> Void = {}
    var wrapUp: () -> Void = {}
    var copyNote: () -> Void = {}
    /// The tour's coach line under its sample card (SPEC §3.12): draws at the origin and width
    /// given and returns its height (nil canvas: measure only).
    var tourCaption: ((Canvas?, Controls?, PointF, Float) -> Float)?
}

/// Every card of `state.cards` (SPEC §3.5, §3.6, §2.11), drawn the Windows way. One layout pass
/// measures (nil canvas) and draws, so a window's size always matches what it draws.
@MainActor
enum PopupCardView {
    /// The window's size for `card`.
    static func size(_ card: CardState, look: PopupCardLook, handlers: PopupCardHandlers = PopupCardHandlers()) -> SizeF {
        layout(nil, nil, card, look, handlers)
    }

    static func draw(_ canvas: Canvas, _ controls: Controls?, _ card: CardState, look: PopupCardLook, handlers: PopupCardHandlers) {
        _ = layout(canvas, controls, card, look, handlers)
    }

    /// The card itself, without the tour's caption.
    static func cardSize(_ card: CardState, look: PopupCardLook) -> SizeF {
        body(nil, nil, card, look, PopupCardHandlers())
    }

    private static func layout(_ canvas: Canvas?, _ controls: Controls?, _ card: CardState, _ look: PopupCardLook,
                               _ handlers: PopupCardHandlers) -> SizeF {
        var size = body(canvas, controls, card, look, handlers)
        if let canvas, let rim = look.rim {
            PopupRim.draw(canvas, RectF(x: 0, y: 0, width: size.width, height: size.height), radius: Theme.Radius.card, frame: rim)
        }
        if let caption = handlers.tourCaption {
            size.height += caption(canvas, controls, PointF(x: 0, y: size.height), size.width)
        }
        return SizeF(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    private static func body(_ canvas: Canvas?, _ controls: Controls?, _ card: CardState, _ look: PopupCardLook,
                             _ handlers: PopupCardHandlers) -> SizeF {
        switch card.content {
        case .resume(let content): return PopupResumeCard.layout(canvas, controls, content, look, handlers)
        case .awayNote(let note):
            return PopupCapsuleCard.layout(canvas, controls, text: note.text, badge: note.kind, action: ("Undo", handlers.undo),
                                           hint: nil, look, handlers)
        case .toast(let toast):
            let action = toast.action == .resumeFromCall ? ("Resume", handlers.resume) : nil
            return PopupCapsuleCard.layout(canvas, controls, text: toast.text, badge: nil, action: action, hint: toast.hint,
                                           look, handlers)
        case .windDown(let content): return PopupWindDownCard.layout(canvas, controls, content, look, handlers)
        case .update(let content): return PopupUpdateCard.layout(canvas, controls, content, look, handlers)
        }
    }

    /// The hover × at a card's top-left corner, inside the window.
    static func closeButton(_ canvas: Canvas?, _ controls: Controls?, visible: Bool, action: @escaping () -> Void) {
        PopupClose.draw(canvas, controls, centre: PointF(x: 11, y: 11), visible: visible, action: action)
    }
}

/// The 18 DIP round × a pop-up shows on hover at its top-left corner (`HoverCloseButton`): an
/// opaque disk, so it reads over the badge it may overlap.
@MainActor
enum PopupClose {
    static let diameter: Float = 18

    static func draw(_ canvas: Canvas?, _ controls: Controls?, centre: PointF, visible: Bool, action: @escaping () -> Void) {
        guard visible, let canvas else { return }
        let id = "close"
        let hot = controls?.isHovered(id) ?? false
        let r = diameter / 2
        canvas.circle(centre, radius: r + 1, Colour.black.opacity(0.25))
        canvas.circle(centre, radius: r, Theme.Palette.solidPopup.mixed(with: .white, hot ? 0.22 : 0.12))
        canvas.ring(centre, radius: r - 0.5, width: 1, Colour.white.opacity(Appearance.highContrast ? 0.5 : 0.18))
        let d: Float = 3.2
        let colour = Colour.white.opacity(hot ? 0.95 : 0.75)
        canvas.line(PointF(x: centre.x - d, y: centre.y - d), PointF(x: centre.x + d, y: centre.y + d), width: 1.4, colour)
        canvas.line(PointF(x: centre.x + d, y: centre.y - d), PointF(x: centre.x - d, y: centre.y + d), width: 1.4, colour)
        guard let controls else { return }
        let rect = RectF(x: centre.x - r, y: centre.y - r, width: diameter, height: diameter)
        if controls.isFocusVisible(id) { canvas.ring(centre, radius: r + 3, width: 2, Theme.Palette.mint.opacity(0.6)) }
        controls.region(id, rect.insetBy(-3, -3), focusable: true, action: action)
    }
}
