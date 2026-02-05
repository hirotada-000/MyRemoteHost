//
//  CryptoManager.swift
//  MyRemoteHost
//
//  AES-256 E2E暗号化マネージャー
//  Phase 3: セキュア通信の実装
//
//  CryptoKitを使用したAES-256-GCM暗号化
//  - ECDH鍵交換（P-256）
//  - 対称鍵生成
//  - データ暗号化/復号
//  - Keychain保存
//

import Foundation
import CryptoKit
import Security

/// 暗号化エラー
enum CryptoError: Error {
    case noKey
    case encryptionFailed
    case decryptionFailed
    case invalidData
    case keyExchangeFailed
    case ecdhFailed
    case keychainError(OSStatus)
}

/// 暗号化マネージャー
class CryptoManager {
    
    // MARK: - Properties
    
    /// 対称鍵 (AES-256)
    private var symmetricKey: SymmetricKey?
    
    /// 暗号化有効フラグ
    var isEnabled: Bool = true
    
    /// 鍵が設定されているかどうか
    var hasKey: Bool {
        symmetricKey != nil
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Key Management
    
    /// 新しい対称鍵を生成
    func generateKey() {
        symmetricKey = SymmetricKey(size: .bits256)
        print("[CryptoManager] 新しいAES-256鍵を生成")
    }
    
    /// 鍵をエクスポート (鍵交換用)
    func exportKey() -> Data? {
        guard let key = symmetricKey else { return nil }
        
        return key.withUnsafeBytes { Data($0) }
    }
    
    /// 鍵をインポート
    func importKey(_ keyData: Data) throws {
        guard keyData.count == 32 else {  // 256 bits = 32 bytes
            throw CryptoError.keyExchangeFailed
        }
        
        symmetricKey = SymmetricKey(data: keyData)
        print("[CryptoManager] 鍵をインポート")
    }
    
    /// 鍵をクリア
    func clearKey() {
        symmetricKey = nil
        print("[CryptoManager] 鍵をクリア")
    }
    
    // MARK: - Encryption
    
    /// データを暗号化
    /// - Parameter data: 平文データ
    /// - Returns: 暗号化データ (Nonce + CipherText + Tag)
    func encrypt(_ data: Data) throws -> Data {
        guard let key = symmetricKey else {
            throw CryptoError.noKey
        }
        
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            
            // Combined形式: Nonce (12 bytes) + CipherText + Tag (16 bytes)
            guard let combined = sealedBox.combined else {
                throw CryptoError.encryptionFailed
            }
            
            return combined
        } catch {
            throw CryptoError.encryptionFailed
        }
    }
    
    /// データを復号
    /// - Parameter data: 暗号化データ (Combined形式)
    /// - Returns: 平文データ
    func decrypt(_ data: Data) throws -> Data {
        guard let key = symmetricKey else {
            throw CryptoError.noKey
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return decryptedData
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
    
    // MARK: - Convenience Methods
    
    /// 暗号化が必要かどうか判定し、必要ならば暗号化
    func encryptIfEnabled(_ data: Data) -> Data {
        guard isEnabled, hasKey else {
            return data
        }
        
        do {
            return try encrypt(data)
        } catch {
            print("[CryptoManager] 暗号化エラー: \(error)")
            return data  // 暗号化失敗時は平文で送信
        }
    }
    
    /// 復号が必要かどうか判定し、必要ならば復号
    func decryptIfEnabled(_ data: Data) -> Data {
        guard isEnabled, hasKey else {
            return data
        }
        
        do {
            return try decrypt(data)
        } catch {
            print("[CryptoManager] 復号エラー: \(error)")
            return data  // 復号失敗時はそのまま返す
        }
    }
    
    // MARK: - Key Exchange Helpers
    
    /// 鍵交換パケットを生成
    /// フォーマット: [0xAB] [32バイト: 鍵]
    func generateKeyExchangePacket() -> Data? {
        guard let keyData = exportKey() else { return nil }
        
        var packet = Data([0xAB])  // 鍵交換パケットマーカー
        packet.append(keyData)
        
        return packet
    }
    
    /// 鍵交換パケットを処理
    func processKeyExchangePacket(_ data: Data) throws {
        guard data.count == 33, data[0] == 0xAB else {
            throw CryptoError.keyExchangeFailed
        }
        
        let keyData = data.subdata(in: 1..<33)
        try importKey(keyData)
    }
    
    // MARK: - Phase 3: ECDH鍵交換
    
    /// ECDHプライベート鍵
    private var ecdhPrivateKey: P256.KeyAgreement.PrivateKey?
    
    /// ECDH鍵ペアを生成
    func generateECDHKeyPair() -> Data {
        let privateKey = P256.KeyAgreement.PrivateKey()
        ecdhPrivateKey = privateKey
        
        // 公開鍵をエクスポート（圧縮形式）
        let publicKey = privateKey.publicKey
        let publicKeyData = publicKey.compressedRepresentation
        
        print("[CryptoManager] ECDH鍵ペア生成")
        return publicKeyData
    }
    
    /// 相手の公開鍵を受け取り、共有秘密から対称鍵を導出
    func deriveSharedKey(peerPublicKeyData: Data) throws {
        guard let privateKey = ecdhPrivateKey else {
            throw CryptoError.ecdhFailed
        }
        
        do {
            let peerPublicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: peerPublicKeyData)
            
            // 共有秘密を計算
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            
            // HKDF-SHA256で256ビット鍵を導出
            let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("MyRemoteHost".utf8),
                sharedInfo: Data("AES-256-GCM".utf8),
                outputByteCount: 32
            )
            
            symmetricKey = derivedKey
            ecdhPrivateKey = nil  // 使用済みプライベート鍵を破棄
            
            print("[CryptoManager] ✅ ECDH共有鍵導出成功")
        } catch {
            throw CryptoError.ecdhFailed
        }
    }
    
    /// ECDHハンドシェイクパケット生成
    /// フォーマット: [0xEC] [33バイト: 圧縮公開鍵]
    func generateECDHHandshakePacket() -> Data {
        let publicKeyData = generateECDHKeyPair()
        
        var packet = Data([0xEC])  // ECDHハンドシェイクマーカー
        packet.append(publicKeyData)
        
        return packet
    }
    
    /// ECDHハンドシェイクを処理
    func processECDHHandshake(_ data: Data) throws {
        guard data.count >= 34, data[0] == 0xEC else {
            throw CryptoError.ecdhFailed
        }
        
        let peerPublicKeyData = data.subdata(in: 1..<34)
        try deriveSharedKey(peerPublicKeyData: peerPublicKeyData)
    }
    
    // MARK: - Keychain Storage
    
    private let keychainService = "com.myremotehost.encryption"
    private let keychainAccount = "session-key"
    
    /// 鍵をKeychainに保存
    func saveKeyToKeychain() throws {
        guard let keyData = exportKey() else {
            throw CryptoError.noKey
        }
        
        // 既存の鍵を削除
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 新しい鍵を保存
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychainError(status)
        }
        
        print("[CryptoManager] 🔐 鍵をKeychainに保存")
    }
    
    /// Keychainから鍵を読み込み
    func loadKeyFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let keyData = result as? Data else {
            throw CryptoError.keychainError(status)
        }
        
        try importKey(keyData)
        print("[CryptoManager] 🔐 Keychainから鍵を読み込み")
    }
    
    /// Keychainから鍵を削除
    func deleteKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        print("[CryptoManager] 🔐 Keychainから鍵を削除")
    }
}
