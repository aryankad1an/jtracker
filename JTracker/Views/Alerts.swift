import SwiftUI

extension View {
    /// A uniform, centered modal confirmation alert for destructive actions across JTracker.
    /// Replaces unanchored and ill-pointed confirmationDialog popups with a standard alert modal.
    /// - Parameter confirmLabel: the destructive button's title, for actions that
    ///   destroy something without being called "delete" (a merge).
    func uniformDeleteAlert(
        title: String,
        message: String,
        confirmLabel: String = "Delete",
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirmLabel, role: .destructive, action: onDelete)
        } message: {
            Text(message)
        }
    }
}

extension View {
    /// The same alert, driven by the item it's about: shown while `item` is set,
    /// and `item` is cleared however it's dismissed.
    func uniformDeleteAlert<Item>(
        item: Binding<Item?>,
        title: (Item) -> String,
        message: String,
        confirmLabel: String = "Delete",
        onDelete: @escaping (Item) -> Void
    ) -> some View {
        uniformDeleteAlert(
            title: item.wrappedValue.map(title) ?? "",
            message: message,
            confirmLabel: confirmLabel,
            isPresented: Binding(get: { item.wrappedValue != nil },
                                 set: { if !$0 { item.wrappedValue = nil } })
        ) {
            if let value = item.wrappedValue { onDelete(value) }
            item.wrappedValue = nil
        }
    }
}

extension View {
    /// An OK-only alert that's up while `message` is set — a failure or a result
    /// to report. `onDismiss` clears the message.
    func messageAlert(_ title: String, message: String?, onDismiss: @escaping () -> Void) -> some View {
        alert(title, isPresented: Binding(get: { message != nil }, set: { if !$0 { onDismiss() } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }
}
