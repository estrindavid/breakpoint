import BreakpointCore
import BreakpointRuntime
import Foundation

extension SnapshotCatalogue {
    /// The tour's coach in every state, into `directory`/tour.
    static func tourSnapshots(_ directory: URL) throws -> Int {
        let folder = directory.appendingPathComponent("tour")
        var count = 0
        let handlers = TourCoachHandlers()

        // The coach cards, as each step shows them.
        let cards: [(String, TourPresentation, TourPointer)] = [
            ("1-offer", .at(.offer), .down(x: 290)),
            ("2-mark", .at(.mark), .down(x: 290)),
            ("2-mark-top-taskbar", .at(.mark), .up(x: 290)),
            ("3b-not-now", .at(.declined), .none),
            ("7-farewell", .at(.farewell), .down(x: 290)),
            ("7-farewell-no-icon", .at(.farewell, agent: "Codex"), .none),
        ]
        for (name, tour, pointer) in cards {
            let width = TourCoachView.width
            let height = TourCoachView.card(nil, nil, tour: tour, width: width, pointer: pointer, handlers: handlers)
            try Snapshot.write(folder.appendingPathComponent("\(name).png"), size: SizeF(width: width, height: height)) { canvas, controls in
                TourCoachView.card(canvas, controls, tour: tour, width: width, pointer: pointer, handlers: handlers)
            }
            count += 1
        }
        // The keyboard focus on a card.
        let offer = TourPresentation.at(.offer)
        let offerHeight = TourCoachView.card(nil, nil, tour: offer, pointer: .down(x: 290), handlers: handlers)
        try Snapshot.write(folder.appendingPathComponent("1-offer-focus.png"), size: SizeF(width: TourCoachView.width, height: offerHeight),
                           focused: "tour.primary") { canvas, controls in
            controls.debugShowFocus()
            TourCoachView.card(canvas, controls, tour: offer, pointer: .down(x: 290), handlers: handlers)
        }
        count += 1

        // The coach line under the sample nudge (410 wide) and the sample resume card (360), as
        // drawn into those pop-ups' windows below a stand-in for the card itself.
        let attached: [(String, TourPresentation, Float)] = [
            ("3-nudge", .at(.nudge), Theme.Size.nudgeSize.width),
            ("3-nudge-hotkeys-off", .at(.nudge, hotkeys: false), Theme.Size.nudgeSize.width),
            ("5-resume", .at(.resumeCard), Theme.Size.resumeCardWidth),
        ]
        for (name, tour, width) in attached {
            let cardHeight: Float = 60
            let height = cardHeight + TourCoachView.attached(nil, nil, tour: tour, at: PointF(x: 0, y: cardHeight), width: width,
                                                             handlers: handlers)
            try Snapshot.write(folder.appendingPathComponent("\(name).png"), size: SizeF(width: width, height: height)) { canvas, controls in
                canvas.text("(the pop-up's own card)", in: RectF(x: 0, y: 0, width: width, height: cardHeight),
                            style: TextStyle(size: 12, align: .center), Colour.white.opacity(0.35))
                _ = TourCoachView.attached(canvas, controls, tour: tour, at: PointF(x: 0, y: cardHeight), width: width, handlers: handlers)
            }
            count += 1
        }

        // The popover step: the flyout with the strip, for each part it names.
        for part in TourPopoverPart.allCases {
            let state = AppState.preview(.agentWorking)
            state.tour = .at(.popover, part: part)
            var flyoutHandlers = FlyoutView.Handlers()
            flyoutHandlers.tourStrip = { canvas, controls, origin, width in
                guard let tour = state.tour else { return 0 }
                return TourCoachView.strip(canvas, controls, tour: tour, at: origin, width: width, handlers: handlers)
            }
            let height = FlyoutView.height(state, handlers: flyoutHandlers)
            try Snapshot.write(folder.appendingPathComponent("6-popover-\(part.rawValue + 1)-\(part).png"),
                               size: SizeF(width: FlyoutView.width, height: height)) { canvas, controls in
                FlyoutView.draw(canvas, controls, state, handlers: flyoutHandlers)
            }
            count += 1
        }

        // The legend's marks, enlarged.
        try Snapshot.write(folder.appendingPathComponent("mark-legend.png"), size: SizeF(width: 320, height: 60), scale: 4) { canvas, _ in
            _ = TourCoachView.markLegend(canvas, at: PointF(x: 4, y: 4), width: 312)
        }
        return count + 1
    }
}
