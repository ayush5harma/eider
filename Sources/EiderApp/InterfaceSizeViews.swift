import EiderKit
import SwiftUI

/// The install sheet's choice of how large the app draws.
struct InterfaceSizePicker: View {
    @Binding var selection: InterfaceScale

    var body: some View {
        Picker(selection: $selection) {
            ForEach(InterfaceScale.allCases, id: \.self) { Text($0.label).tag($0) }
        } label: {
            Text("Interface size")
            Text("Auto: the size of Apple's own apps on this display. iPad apps otherwise draw at 77%.")
        }
    }
}

/// Offered while apps installed before the setting still draw at 77%.
struct InterfaceSizeOffer: View {
    let model: AppModel

    var body: some View {
        let count = model.appsWithoutInterfaceScale.count
        HStack(spacing: 12) {
            Image(systemName: "textformat.size")
                .font(.title2).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 app draws at the iPad's 77% size" : "\(count) apps draw at the iPad's 77% size")
                    .font(.headline)
                Text("Auto makes their buttons and text the size of Apple's own apps on this display. Change any app later from its menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not Now") { model.dismissInterfaceScaleOffer() }.rowCapsule()
            Button("Use Auto") { Task { await model.useAutoInterfaceScaleForUnsetApps() } }.rowCapsule(prominent: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .cardBackground(cornerRadius: 14)
    }
}

/// What the last change will do, until closed.
struct InterfaceSizeNotice: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size")
                .font(.title2).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text).font(.callout)
            Spacer(minLength: 8)
            Button("OK", action: close).rowCapsule()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .cardBackground(cornerRadius: 14)
    }
}
