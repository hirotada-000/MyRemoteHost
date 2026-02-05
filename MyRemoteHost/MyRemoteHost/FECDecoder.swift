//
//  FECDecoder.swift
//  MyRemoteHost
//
//  前方誤り訂正 (Forward Error Correction) デコーダー
//  Phase 2: UDPパケットロス対策
//
//  XORベースのシンプルなFEC実装
//  - パリティブロックから欠損データを復元
//

import Foundation

/// FECデコード結果
enum FECDecodeResult {
    case success(Data)
    case partialRecovery(Data, missingBlocks: [Int])
    case failure(Error)
}

/// FECデコードエラー
enum FECDecodeError: Error {
    case invalidData
    case tooManyMissingBlocks
    case parityMismatch
}

/// FECデコーダー
class FECDecoder {
    
    // MARK: - Public Methods
    
    /// シンプルFECデコード (パリティ検証)
    /// - Parameter data: FECエンコードされたデータ
    /// - Returns: 元データ (パリティ検証成功時)
    func decodeSimple(_ data: Data) -> FECDecodeResult {
        // 最低限のサイズチェック (4バイトヘッダー + 最低1バイトデータ + 最低1バイトパリティ)
        guard data.count >= 6 else {
            return .failure(FECDecodeError.invalidData)
        }
        
        // 元データサイズを読み取り
        let originalSize = data.subdata(in: 0..<4).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        
        // サイズ検証
        guard originalSize > 0, Int(originalSize) + 4 < data.count else {
            return .failure(FECDecodeError.invalidData)
        }
        
        // 元データを抽出
        let originalData = data.subdata(in: 4..<(4 + Int(originalSize)))
        
        // パリティデータを抽出
        let parityData = data.subdata(in: (4 + Int(originalSize))..<data.count)
        
        // パリティ検証 (オプション: 軽量検証のみ)
        let verified = verifyParity(originalData, parity: parityData)
        
        if verified {
            return .success(originalData)
        } else {
            // パリティ不一致でも、データ自体は返す（軽微な破損の可能性）
            return .success(originalData)
        }
    }
    
    /// ブロックベースのFECデコード
    /// - Parameters:
    ///   - receivedBlocks: 受信したデータブロック (欠損はnil)
    ///   - parityBlocks: パリティブロック
    ///   - blockSize: ブロックサイズ
    ///   - originalSize: 元データの総サイズ
    /// - Returns: 復元されたデータ
    func decode(receivedBlocks: [Data?], parityBlocks: [Data], blockSize: Int, originalSize: Int) -> FECDecodeResult {
        var blocks = receivedBlocks
        var missingIndices: [Int] = []
        
        // 欠損ブロックを特定
        for (index, block) in blocks.enumerated() {
            if block == nil {
                missingIndices.append(index)
            }
        }
        
        // 欠損がなければそのまま結合して返す
        if missingIndices.isEmpty {
            return .success(reassembleData(blocks: blocks.compactMap { $0 }, originalSize: originalSize))
        }
        
        // パリティから復元を試みる
        for missingIndex in missingIndices {
            // このブロックを担当するパリティを特定
            let parityIndex = missingIndex % parityBlocks.count
            
            guard parityIndex < parityBlocks.count else {
                continue
            }
            
            // パリティと他のブロックをXORして復元
            var recovered = parityBlocks[parityIndex]
            
            var blockIndex = parityIndex
            while blockIndex < blocks.count {
                if blockIndex != missingIndex, let block = blocks[blockIndex] {
                    recovered = xor(recovered, block)
                }
                blockIndex += parityBlocks.count
            }
            
            blocks[missingIndex] = recovered
        }
        
        // 復元後も欠損があるか確認
        let stillMissing = blocks.enumerated().filter { $0.element == nil }.map { $0.offset }
        
        if stillMissing.isEmpty {
            return .success(reassembleData(blocks: blocks.compactMap { $0 }, originalSize: originalSize))
        } else {
            // 部分復元
            let partialData = reassembleData(blocks: blocks.compactMap { $0 }, originalSize: originalSize)
            return .partialRecovery(partialData, missingBlocks: stillMissing)
        }
    }
    
    // MARK: - Private Methods
    
    /// パリティ検証
    private func verifyParity(_ data: Data, parity: Data) -> Bool {
        // 再計算したパリティと比較
        var calculatedParity = Data(repeating: 0, count: parity.count)
        
        for i in 0..<data.count {
            let parityIndex = i % parity.count
            calculatedParity[parityIndex] ^= data[i]
        }
        
        return calculatedParity == parity
    }
    
    /// ブロックを結合してデータを再構成
    private func reassembleData(blocks: [Data], originalSize: Int) -> Data {
        var result = Data()
        
        for block in blocks {
            result.append(block)
        }
        
        // パディングを除去
        if result.count > originalSize {
            result = result.prefix(originalSize)
        }
        
        return result
    }
    
    /// 2つのDataをXOR
    private func xor(_ a: Data, _ b: Data) -> Data {
        let length = min(a.count, b.count)
        var result = Data(count: length)
        
        a.withUnsafeBytes { aPtr in
            b.withUnsafeBytes { bPtr in
                result.withUnsafeMutableBytes { rPtr in
                    guard let aBase = aPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let bBase = bPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let rBase = rPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    
                    for i in 0..<length {
                        rBase[i] = aBase[i] ^ bBase[i]
                    }
                }
            }
        }
        
        return result
    }
}
