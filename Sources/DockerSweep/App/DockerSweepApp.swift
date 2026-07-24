import AppKit
import SwiftUI

@main
struct DockerSweepApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var state = AppState()

  var body: some Scene {
    MenuBarExtra {
      DashboardView()
        .environmentObject(state)
        .frame(width: 440, height: 610)
        .task { state.start() }
    } label: {
      MenuBarLabel(state: state)
        .task { state.start() }
    }
    .menuBarExtraStyle(.window)

    Window("Cleanup History", id: "cleanup-history") {
      HistoryView()
        .environmentObject(state)
    }
    .defaultSize(width: 440, height: 420)

    Window("Cleanup Preview", id: "cleanup-preview") {
      CleanupPreviewView()
        .environmentObject(state)
    }
    .defaultSize(width: 420, height: 420)

    Window("DockerSweep Settings", id: "settings") {
      SettingsView()
        .environmentObject(state)
    }
    .defaultSize(width: 500, height: 650)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
