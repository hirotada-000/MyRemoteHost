//
//  InputPhysics.swift
//  MyRemoteHost
//
//  入力操作の物理量（速度・加速度）を計算するヘルパー
//

import Foundation
import CoreGraphics

struct ScrollPhysicsState: Sendable {
    var velocityX: Double = 0.0  // pixels/sec
    var velocityY: Double = 0.0  // pixels/sec
    var isScrolling: Bool = false
    var lastUpdateTime: Date = Date()
}
