//
//  MyRemoteHostApp.swift
//  MyRemoteHost
//
//  Created by 小林央忠 on 2026/01/19.
//

import SwiftUI

@main
struct MyRemoteHostApp: App {
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
            Logger.app("🖥️ macOS: バックグラウンドに遷移")
            // macOSではキャプチャ継続（ヘッドレス運用を想定）
            
        case .active:
            if oldPhase == .background {
                Logger.app("🖥️ macOS: フォアグラウンドに復帰")
            }
            
        case .inactive:
            break
            
        @unknown default:
            break
        }
    }
}
