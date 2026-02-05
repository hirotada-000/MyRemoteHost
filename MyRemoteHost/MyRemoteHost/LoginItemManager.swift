//
//  LoginItemManager.swift
//  MyRemoteHost
//
//  ログイン時自動起動を管理
//  Phase 4: SMAppServiceによるログイン項目管理
//

import Foundation
import Combine
import ServiceManagement

/// ログイン項目（自動起動）を管理するクラス
class LoginItemManager: ObservableObject {
    
    /// ログイン時に起動が有効か
    @Published var isEnabled: Bool = false
    
    init() {
        // 現在の状態を取得
        updateStatus()
    }
    
    /// ログイン項目の有効/無効を切り替え
    func setEnabled(_ enabled: Bool) {
        // ★ 現在値と同じならスキップ（重複呼び出し防止）
        guard isEnabled != enabled else { return }
        
        do {
            if enabled {
                try SMAppService.mainApp.register()
                print("[LoginItemManager] ✅ ログイン項目に登録")
            } else {
                try SMAppService.mainApp.unregister()
                print("[LoginItemManager] ❌ ログイン項目から解除")
            }
            updateStatus()
        } catch {
            print("[LoginItemManager] エラー: \(error.localizedDescription)")
        }
    }
    
    /// 状態を更新
    private func updateStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
