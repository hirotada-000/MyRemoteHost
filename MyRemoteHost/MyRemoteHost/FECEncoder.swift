//
//  FECEncoder.swift
//  MyRemoteHost
//
//  前方誤り訂正 (Forward Error Correction) エンコーダー
//  Phase 2: UDPパケットロス対策
//
//  XORベースのシンプルなFEC実装
//  - データブロックからパリティブロックを生成
//  - パケットロス時にパリティから復元可能
//

import Foundation

/// FECエンコードされたデータ
struct FECEncodedData {
    /// 元データブロック
    let dataBlocks: [Data]
    /// パリティブロック
    let parityBlocks: [Data]
    /// ブロックサイズ
    let blockSize: Int
    /// 元データの総サイズ
    let originalSize: Int
}

/// FECエンコーダー
class FECEncoder {
    
    // MARK: - Properties
    
    /// データブロック数に対するパリティブロック数の比率
    /// 0.1 = 10% の冗長データ (10ブロックごとに1パリティ)
    var redundancyRatio: Double = 0.1
    
    /// 最小ブロックサイズ
    private let minBlockSize = 1024
    
    /// 最大ブロックサイズ (MTU考慮)
    private let maxBlockSize = 1300
    
    // MARK: - Public Methods
    
    /// データをFECエンコードする
    /// - Parameters:
    ///   - data: 元データ
    ///   - blockSize: 1ブロックのサイズ（省略時は自動計算）
    /// - Returns: FECエンコードされたデータ
    func encode(_ data: Data, blockSize: Int? = nil) -> FECEncodedData {
        let effectiveBlockSize = blockSize ?? calculateOptimalBlockSize(for: data)
        
        // データをブロック分割
        var dataBlocks: [Data] = []
        var offset = 0
        
        while offset < data.count {
            let end = min(offset + effectiveBlockSize, data.count)
            var block = data.subdata(in: offset..<end)
            
            // 最後のブロックはパディング
            if block.count < effectiveBlockSize {
                block.append(Data(repeating: 0, count: effectiveBlockSize - block.count))
            }
            
            dataBlocks.append(block)
            offset += effectiveBlockSize
        }
        
        // パリティブロック生成
        let parityBlocks = generateParityBlocks(from: dataBlocks, blockSize: effectiveBlockSize)
        
        return FECEncodedData(
            dataBlocks: dataBlocks,
            parityBlocks: parityBlocks,
            blockSize: effectiveBlockSize,
            originalSize: data.count
        )
    }
    
    /// シンプルなFEC: データに冗長データを付加
    /// - Parameters:
    ///   - data: 元データ
    /// - Returns: FECデータ付きのData (元データ + パリティ + メタデータ)
    func encodeSimple(_ data: Data) -> Data {
        // パリティサイズ (元データの10%)
        let paritySize = max(32, data.count / 10)
        
        // XORパリティ生成
        let parity = generateXORParity(data: data, size: paritySize)
        
        // パケット形式: [4バイト: 元データサイズ] [元データ] [パリティ]
        var result = Data()
        
        // 元データサイズ (4バイト、ビッグエンディアン)
        var originalSize = UInt32(data.count).bigEndian
        result.append(Data(bytes: &originalSize, count: 4))
        
        // 元データ
        result.append(data)
        
        // パリティ
        result.append(parity)
        
        return result
    }
    
    // MARK: - Private Methods
    
    /// 最適なブロックサイズを計算
    private func calculateOptimalBlockSize(for data: Data) -> Int {
        // データサイズに応じてブロックサイズを調整
        if data.count < 10_000 {
            return minBlockSize
        } else if data.count < 100_000 {
            return 1200
        } else {
            return maxBlockSize
        }
    }
    
    /// パリティブロックを生成
    private func generateParityBlocks(from dataBlocks: [Data], blockSize: Int) -> [Data] {
        guard !dataBlocks.isEmpty else { return [] }
        
        // パリティブロック数を計算
        let parityCount = max(1, Int(ceil(Double(dataBlocks.count) * redundancyRatio)))
        
        var parityBlocks: [Data] = []
        
        for parityIndex in 0..<parityCount {
            var parity = Data(repeating: 0, count: blockSize)
            
            // このパリティが担当するデータブロックを XOR
            // インターリーブパターン: parityIndex, parityIndex + parityCount, ...
            var blockIndex = parityIndex
            while blockIndex < dataBlocks.count {
                let block = dataBlocks[blockIndex]
                parity = xor(parity, block)
                blockIndex += parityCount
            }
            
            parityBlocks.append(parity)
        }
        
        return parityBlocks
    }
    
    /// XORパリティを生成 (シンプル版)
    private func generateXORParity(data: Data, size: Int) -> Data {
        var parity = Data(repeating: 0, count: size)
        
        for i in 0..<data.count {
            let parityIndex = i % size
            parity[parityIndex] ^= data[i]
        }
        
        return parity
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
