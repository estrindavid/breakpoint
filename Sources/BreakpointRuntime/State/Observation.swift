import Foundation

// `AppState` is an `ObservableObject` with `@Published` fields. On Apple platforms those are
// Combine's (SwiftUI observes them). Windows has no Combine, so this file gives the same three
// names a minimal meaning there: every write to a `@Published` field of an `ObservableObject`
// first fires its `objectWillChange`, which the coordinator subscribes to with `sink`, exactly as
// it does with Combine. The coordinator's code is the same on both platforms.

#if canImport(Combine)
import Combine

/// What `objectWillChange.sink` returns.
public typealias StateSubscription = AnyCancellable
#else

/// A will-change signal with Combine's `sink` spelling.
public final class ObjectWillChangePublisher: @unchecked Sendable {
    private var subscribers: [UUID: () -> Void] = [:]

    public init() {}

    /// Calls `receive` before every change until the returned subscription is released.
    public func sink(_ receive: @escaping (()) -> Void) -> StateSubscription {
        let id = UUID()
        subscribers[id] = { receive(()) }
        return StateSubscription { [weak self] in self?.subscribers[id] = nil }
    }

    public func send() {
        for subscriber in subscribers.values { subscriber() }
    }
}

/// Ends a `sink` when released (Combine's `AnyCancellable`).
public final class StateSubscription: @unchecked Sendable {
    private var cancel: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    public func cancelSubscription() { cancel?(); cancel = nil }
    deinit { cancel?() }
}

/// A class whose `@Published` fields announce their changes.
public protocol ObservableObject: AnyObject {
    var objectWillChange: ObjectWillChangePublisher { get }
}

/// A field whose writes fire its owner's `objectWillChange` first.
@propertyWrapper
public struct Published<Value> {
    private var value: Value

    public init(wrappedValue: Value) { value = wrappedValue }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public static subscript<Owner: ObservableObject>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Published<Value>>
    ) -> Value {
        get { owner[keyPath: storageKeyPath].value }
        set {
            owner.objectWillChange.send()
            owner[keyPath: storageKeyPath].value = newValue
        }
    }
}
#endif
