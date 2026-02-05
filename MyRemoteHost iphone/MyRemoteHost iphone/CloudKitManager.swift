//
//  CloudKitManager.swift
//  MyRemoteHost iphone
//
//  CloudKit経由でuserRecordIDを取得し、同じApple IDかどうかを判定
//  Phase 3: Apple ID認証
//

import Foundation
import CloudKit

/// CloudKit経由でApple ID判定を行うマネージャー
actor CloudKitManager {
    
    static let shared = CloudKitManager()
    
    // MARK: - Properties
    
    /// キャッシュされたuserRecordID
    private var cachedUserRecordID: String?
    
    /// CloudKit Container ID（両プラットフォームで同じIDを使用）
    private let containerID = "iCloud.com.myremotehost.shared"
    
    // MARK: - Public Methods
    
    /// 現在のユーザーのuserRecordIDを取得
    /// - Returns: userRecordID（ハッシュ化されたApple ID識別子）
    func fetchUserRecordID() async throws -> String {
        // キャッシュがあれば返す
        if let cached = cachedUserRecordID {
            return cached
        }
        
        let container = CKContainer(identifier: containerID)
        
        // iCloudログイン状態を確認
        let status = try await container.accountStatus()
        guard status == .available else {
            throw CloudKitError.notLoggedIn
        }
        
        // userRecordIDを取得
        let recordID = try await container.userRecordID()
        let userID = recordID.recordName
        
        // キャッシュに保存
        cachedUserRecordID = userID
        print("[CloudKitManager] userRecordID取得成功: \(userID.prefix(20))...")
        
        return userID
    }
    
    /// キャッシュをクリア
    func clearCache() {
        cachedUserRecordID = nil
    }
    
    // MARK: - Errors
    
    enum CloudKitError: Error, LocalizedError {
        case notLoggedIn
        case fetchFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "iCloudにログインしていません"
            case .fetchFailed(let error):
                return "userRecordID取得失敗: \(error.localizedDescription)"
            }
        }
    }
}
