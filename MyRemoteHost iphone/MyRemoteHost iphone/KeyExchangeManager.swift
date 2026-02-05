//
//  KeyExchangeManager.swift
//  MyRemoteHost
//
//  ECDH (Elliptic Curve Diffie-Hellman) 鍵交換マネージャー
//  Phase 1: セキュア通信基盤
//
//  Curve25519を使用した安全な鍵交換
//  - 公開鍵のみをネットワーク上で交換
//  - 秘密鍵は決してデバイスを離れない
//  - HKDF-SHA256で対称鍵を導出
//

import Foundation
import CryptoKit

/// 鍵交換エラー
enum KeyExchangeError: Error, LocalizedError {
    case keyPairNotGenerated
    case invalidPublicKey
    case keyDerivationFailed
    case alreadyExchanged
    
    var errorDescription: String? {
        switch self {
        case .keyPairNotGenerated:
            return "鍵ペアが生成されていません"
        case .invalidPublicKey:
            return "無効な公開鍵です"
        case .keyDerivationFailed:
            return "鍵導出に失敗しました"
        case .alreadyExchanged:
            return "鍵交換は既に完了しています"
        }
    }
}

/// ECDH鍵交換マネージャー
/// 
/// 使用フロー:
/// 1. generateKeyPair() で公開鍵を生成
/// 2. 公開鍵を相手に送信
/// 3. 相手の公開鍵を受信
/// 4. deriveSharedSecret() で共有シークレットを導出
/// 5. getSymmetricKey() で対称鍵を取得
class KeyExchangeManager {
    
    // MARK: - Properties
    
    /// 自分の秘密鍵
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    
    /// 自分の公開鍵
    private(set) var publicKey: Data?
    
    /// 導出された共有シークレット
    private var sharedSecret: SharedSecret?
    
    /// 導出された対称鍵
    private var symmetricKey: SymmetricKey?
    
    /// 鍵交換が完了したかどうか
    var isExchangeComplete: Bool {
        symmetricKey != nil
    }
    
    /// プロトコルバージョン（HKDF salt に使用）
    private let protocolVersion = "MyRemoteHost-v1"
    
    /// 公開鍵のサイズ（バイト）
    static let publicKeySize = 32
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// 鍵ペアを生成し、公開鍵を返す
    /// - Returns: 自分の公開鍵 (32バイト)
    func generateKeyPair() -> Data {
        // 既存の状態をクリア
        reset()
        
        // 新しい鍵ペアを生成
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKey = privateKey!.publicKey.rawRepresentation
        
        print("[KeyExchangeManager] 鍵ペア生成完了: 公開鍵 \(publicKey!.count)バイト")
        
        return publicKey!
    }
    
    /// 相手の公開鍵から共有シークレットを導出し、対称鍵を生成
    /// - Parameter peerPublicKeyData: 相手の公開鍵 (32バイト)
    /// - Returns: 導出された対称鍵 (AES-256用, 32バイト)
    func deriveSharedSecret(from peerPublicKeyData: Data) throws -> SymmetricKey {
        guard let privateKey = privateKey else {
            throw KeyExchangeError.keyPairNotGenerated
        }
        
        guard peerPublicKeyData.count == KeyExchangeManager.publicKeySize else {
            throw KeyExchangeError.invalidPublicKey
        }
        
        do {
            // 相手の公開鍵を復元
            let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerPublicKeyData
            )
            
            // ECDH共有シークレットを計算
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            
            // HKDF-SHA256で対称鍵を導出
            // - salt: プロトコルバージョン（同じプロトコル間でのみ互換性）
            // - info: 空（追加のコンテキストなし）
            // - outputByteCount: 32バイト（AES-256用）
            let derivedKey = sharedSecret!.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: protocolVersion.data(using: .utf8)!,
                sharedInfo: Data(),
                outputByteCount: 32
            )
            
            symmetricKey = derivedKey
            
            print("[KeyExchangeManager] 共有シークレット導出完了: 対称鍵生成")
            
            return derivedKey
            
        } catch let error as KeyExchangeError {
            throw error
        } catch {
            print("[KeyExchangeManager] 鍵導出エラー: \(error)")
            throw KeyExchangeError.keyDerivationFailed
        }
    }
    
    /// 導出済みの対称鍵を取得
    /// - Returns: 対称鍵（鍵交換が未完了の場合はnil）
    func getSymmetricKey() -> SymmetricKey? {
        return symmetricKey
    }
    
    /// 対称鍵をDataとしてエクスポート
    /// - Returns: 対称鍵のバイト列（32バイト）
    func exportSymmetricKey() -> Data? {
        guard let key = symmetricKey else { return nil }
        
        return key.withUnsafeBytes { Data($0) }
    }
    
    /// 状態をリセット（新しい接続のために再利用する場合）
    func reset() {
        privateKey = nil
        publicKey = nil
        sharedSecret = nil
        symmetricKey = nil
        print("[KeyExchangeManager] 状態リセット")
    }
    
    // MARK: - Debugging
    
    /// デバッグ用：公開鍵のハッシュを取得（ログ用）
    func publicKeyFingerprint() -> String? {
        guard let pubKey = publicKey else { return nil }
        
        let hash = SHA256.hash(data: pubKey)
        let prefix = hash.prefix(4)
        return prefix.map { String(format: "%02x", $0) }.joined()
    }
}
