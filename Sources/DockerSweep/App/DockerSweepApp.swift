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

    Settings {
      SettingsView()
        .environmentObject(state)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
