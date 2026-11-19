import SwiftUI

/// View-local state without the `@State` macro. In the macOS 27 SDK `@State` is a macro whose plugin ships only with
/// Xcode, so a Command Line Tools build (Homebrew uses one) fails with "plugin for module 'SwiftUIMacros' not found".
/// `@StateObject` is still a plain property wrapper, so the value lives in a small observable box that SwiftUI keeps
/// for the view's lifetime, the same way it keeps `@State`.
final class LocalBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: LocalBox<Value>

    init(wrappedValue: Value) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
}
