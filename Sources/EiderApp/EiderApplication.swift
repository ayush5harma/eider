import EiderKit
import SwiftUI

@main
struct EiderApplication: App {
    var body: some Scene {
        WindowGroup("Eider") {
            Text("Eider \(EiderVersion.current)")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
