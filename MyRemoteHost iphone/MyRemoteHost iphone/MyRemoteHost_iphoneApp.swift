//
//  MyRemoteHost_iphoneApp.swift
//  MyRemoteHost iphone
//
//  Created by 小林央忠 on 2026/01/19.
//

import SwiftUI

@main
struct MyRemoteHost_iphoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }
    
    // MARK: - Lifecycle Management
    
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            Logger.app("📱 バックグラウンドに遷移 — リソース解放開始")
            NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
            
        case .active:
            if oldPhase == .background {
                Logger.app("📱 フォアグラウンドに復帰 — 再接続開始")
                NotificationCenter.default.post(name: .appDidBecomeActive, object: nil)
            }
            
        case .inactive:
            break
            
        @unknown default:
            break
        }
    }
}

// MARK: - App Lifecycle Notifications

extension Notification.Name {
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
    static let appDidBecomeActive = Notification.Name("appDidBecomeActive")
}
