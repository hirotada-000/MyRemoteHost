//
//  AuthenticationManager.swift
//  MyRemoteHost
//
//  クライアント接続認証を管理するマネージャ
//  - CloudKitによる同一Apple ID判定
//  - LocalAuthenticationによるシステム認証
//  - 認証ロックアウト機能
//

import Foundation
import LocalAuthentication
import Combine

/// 認証待ちクライアント情報
struct PendingClient: Identifiable {
    let id = UUID()
    let host: String
    let port: UInt16
    let requestTime: Date
}

@MainActor
class AuthenticationManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 認証が必要かどうか（設定）
    @Published var requireAuthentication: Bool = true
    
    /// 認証待ちのクライアント情報
    @Published var pendingAuthClient: PendingClient? = nil
    
    /// 認証失敗回数
    @Published var authFailureCount: Int = 0
    
    /// 認証ロック中
    @Published var isAuthLocked: Bool = false
    
    // MARK: - Callbacks
    
    /// 認証許可時のコールバック
    var onApprove: ((String, UInt16) -> Void)?
    
    /// 認証拒否時のコールバック
    var onDeny: ((String, UInt16) -> Void)?
    
    // MARK: - Logic
    
    /// 接続リクエストを処理
    func handleAuthRequest(host: String, port: UInt16, userRecordID: String?) {
        // ★ 最優先: 同じApple IDなら全ての認証をスキップして即許可
        if let clientUserRecordID = userRecordID {
            Task {
                let isSameAppleID = await CloudKitManager.shared.isSameAppleID(as: clientUserRecordID)
                
                if isSameAppleID {
                    approve(host: host, port: port)
                    print("[AuthenticationManager] ✅ 同一Apple ID - 認証スキップで即許可")
                    return
                }
                
                // 異なるApple ID
                await requireAuthForDifferentAppleID(host: host, port: port)
            }
            return
        }
        
        // userRecordIDがない場合
        processUnknownDeviceAuth(host: host, port: port)
    }
    
    private func requireAuthForDifferentAppleID(host: String, port: UInt16) {
        guard !isAuthLocked else {
            deny(host: host, port: port)
            return
        }
        
        pendingAuthClient = PendingClient(host: host, port: port, requestTime: Date())
        print("[AuthenticationManager] ⚠️ 異なるApple ID - 認証が必要")
    }
    
    private func processUnknownDeviceAuth(host: String, port: UInt16) {
        // 認証不要設定の場合は即許可
        guard requireAuthentication else {
            approve(host: host, port: port)
            return
        }
        
        guard !isAuthLocked else {
            deny(host: host, port: port)
            return
        }
        
        pendingAuthClient = PendingClient(host: host, port: port, requestTime: Date())
        print("[AuthenticationManager] 認証リクエスト受信（Apple ID不明）")
    }
    
    /// システム認証（Touch ID/パスワード）を実行して許可
    func approveWithSystemAuth() {
        guard let client = pendingAuthClient else { return }
        
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "リモート接続を許可") { [weak self] success, _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    if success {
                        self.approve(host: client.host, port: client.port)
                        self.pendingAuthClient = nil
                        self.authFailureCount = 0
                    } else {
                        self.handleAuthFailure(client: client)
                    }
                }
            }
        } else {
            print("[AuthenticationManager] ⚠️ システム認証利用不可")
        }
    }
    
    func denyConnection() {
        guard let client = pendingAuthClient else { return }
        deny(host: client.host, port: client.port)
        pendingAuthClient = nil
    }
    
    private func approve(host: String, port: UInt16) {
        onApprove?(host, port)
    }
    
    private func deny(host: String, port: UInt16) {
        onDeny?(host, port)
    }
    
    private func handleAuthFailure(client: PendingClient) {
        authFailureCount += 1
        if authFailureCount >= 3 {
            isAuthLocked = true
            deny(host: client.host, port: client.port)
            pendingAuthClient = nil
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                isAuthLocked = false
                authFailureCount = 0
            }
        }
    }
}
