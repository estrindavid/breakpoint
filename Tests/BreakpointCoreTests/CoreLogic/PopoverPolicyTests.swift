import Foundation
import Testing
@testable import BreakpointCore

@Suite("The popover closes when you leave it, and never hangs on by itself (SPEC §3.8)")
struct PopoverPolicyTests {
    typealias Context = PopoverPolicy.Context

    func closes(_ cause: PopoverCloseCause, _ context: Context = .init()) -> Bool {
        PopoverPolicy.closes(for: cause, context: context)
    }

    /// Every way the popover can be dressed while open: plain, with the pointer on it, carrying
    /// its first-use hint, during the tour's look at it.
    static let dressings: [Context] = [
        Context(), Context(pointerOnPopover: true), Context(showsHint: true), Context(tourStep: true),
        Context(tourStep: true, showsHint: true, pointerOnPopover: true),
    ]

    @Test("A click outside it or Esc closes it at once, whatever it shows")
    func personActsAlwaysClose() {
        for context in Self.dressings {
            for cause in [PopoverCloseCause.clickOutside, .escape] {
                #expect(closes(cause, context), "\(cause) with \(context)")
                var justOpened = context
                justOpened.secondsOpen = 0
                #expect(closes(cause, justOpened), "\(cause) right after opening")
            }
        }
    }

    @Test("Another app, a Space or a display change closes it, whatever it shows")
    func leavingClosesIt() {
        for context in Self.dressings {
            for cause in [PopoverCloseCause.otherAppActive, .spaceChanged, .displayChanged] {
                #expect(closes(cause, context), "\(cause) with \(context)")
            }
        }
    }

    @Test("…but not as the side effect of opening it (activation may switch Spaces)")
    func openingSettles() {
        for cause in [PopoverCloseCause.otherAppActive, .spaceChanged, .displayChanged] {
            #expect(!closes(cause, Context(secondsOpen: 0)))
            #expect(!closes(cause, Context(secondsOpen: Timing.popoverSettle - 0.01)))
            #expect(closes(cause, Context(secondsOpen: Timing.popoverSettle)))
        }
    }

    @Test("The menu bar sliding away closes a popover nobody is using")
    func menuBarGoneCloses() {
        #expect(closes(.menuBarHidden))
        #expect(closes(.menuBarHidden, Context(secondsOpen: 0)))
    }

    @Test("Only the pointer on it, its first-use hint and the tour's step keep it open then")
    func whatKeepsItOpen() {
        #expect(!closes(.menuBarHidden, Context(pointerOnPopover: true)))
        #expect(!closes(.menuBarHidden, Context(showsHint: true)))
        #expect(!closes(.menuBarHidden, Context(tourStep: true)))
        // The pointer leaving it while the menu bar is still away: it goes.
        #expect(closes(.menuBarHidden, Context(pointerOnPopover: false)))
    }

    @Test("The default context is a popover open a while, plain")
    func defaults() {
        let context = Context()
        #expect(!context.tourStep && !context.showsHint && !context.pointerOnPopover)
        #expect(context.secondsOpen >= Timing.popoverSettle)
    }

    @Test("Every cause has a phrase for the trace")
    func phrases() {
        #expect(Set(PopoverCloseCause.allCases.map(\.phrase)).count == PopoverCloseCause.allCases.count)
        #expect(PopoverCloseCause.clickOutside.phrase == "a click outside it")
    }
}
