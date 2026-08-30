import SwiftUI

@main
struct LSMMobileWorkerApp: App {
    @UIApplicationDelegateAdaptor(LSMAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkerViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    model.startIfConfigured()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    model.handleScenePhase(newPhase)
                }
        }
    }
}
