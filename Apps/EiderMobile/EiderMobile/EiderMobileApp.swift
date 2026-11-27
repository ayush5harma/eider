import SwiftUI

@main
struct EiderMobileApp: App {
    @State private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.start()
                    #if DEBUG
                    await ScreenshotDriver.run(model)
                    #endif
                }
                // eider:// links, and IPAs opened from Files or the share sheet.
                .onOpenURL { url in
                    Task { await model.handle(url) }
                }
        }
    }
}
