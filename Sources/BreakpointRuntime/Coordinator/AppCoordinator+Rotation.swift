import Foundation
import BreakpointCore

// Routine and copy rotation (SPEC §2.2): the coordinator owns `rotation` and saves it in
// `rotation.json` whenever a real break starts, so rotation survives a relaunch.

extension AppCoordinator {
    /// The copy variant (and, for `move`, the routine) for a break starting now. A real break
    /// advances the rotation and saves it; a Settings preview shows what comes next and changes
    /// nothing.
    func drawRotation(_ kind: BreakKind, isPreview: Bool) -> (copy: Int, routine: Routine?) {
        var next = rotation
        let draw = CopyRotation.draw(kind, count: BreakCopyLibrary.copy(for: kind).variants.count, state: next)
        next = draw.state
        var routine: Routine?
        if kind == .move {
            let chosen = RoutineRotation.next(for: settings, state: next)
            next = RoutineRotation.started(chosen.id, in: next)
            routine = chosen
        }
        if !isPreview {
            rotation = next
            saveRotation()
        }
        return (draw.index, routine)
    }

    /// The routine the next stretch break will use (`debug state`).
    var nextRoutineID: String { RoutineRotation.next(for: settings, state: rotation).id }

    func saveRotation() {
        do {
            try RotationState.file(paths).write(rotation)
        } catch {
            log.error("Could not save rotation.json: \(String(describing: error), privacy: .public)")
        }
    }
}
