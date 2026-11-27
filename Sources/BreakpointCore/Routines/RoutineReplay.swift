import Foundation

// "1 more minute" on `move` (SPEC §3.3): the extra minute replays
// steps from the routine just done instead of a generic step.

public enum RoutineReplay {
    /// The routine's own steps: those that start within the planned length (steps appended by
    /// earlier extensions start after it).
    public static func plannedSteps(of routine: Routine, plannedLength: TimeInterval) -> [RoutineStep] {
        let planned = zip(routine.steps, routine.stepOffsets).filter { $0.1 < plannedLength }.map(\.0)
        return planned.isEmpty ? routine.steps : planned
    }

    /// `length` seconds of steps replayed from `routine`, in order, starting where the previous
    /// extension's replay stopped (the first extension starts at step 1). Whole steps while they
    /// fit; then the next step shortened to what is left, or, when less than
    /// `Timing.routineStepShortest` is left, the last step lengthened instead.
    public static func extraMinute(for routine: Routine, plannedLength: TimeInterval, extension number: Int,
                                   length: TimeInterval = Timing.extensionLength) -> [RoutineStep] {
        let planned = plannedSteps(of: routine, plannedLength: plannedLength)
        guard planned.contains(where: { $0.duration > 0 }), length > 0 else { return [] }
        let alreadyReplayed = routine.steps.count - planned.count
        var index = alreadyReplayed
        var result: [RoutineStep] = []
        var total: TimeInterval = 0
        while total < length {
            let left = length - total
            var step = planned[index % planned.count]
            if step.duration <= left {
                // Whole step.
            } else if left >= Timing.routineStepShortest || result.isEmpty {
                step.duration = left
            } else {
                result[result.count - 1].duration += left
                break
            }
            step.id = "\(step.id)-again-\(number)-\(result.count + 1)"
            result.append(step)
            total += step.duration
            index += 1
        }
        return result
    }
}
