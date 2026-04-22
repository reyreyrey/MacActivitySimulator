//
//  MacActivitySimulatorApp.swift
//  MacActivitySimulator
//
//  Created by Rey on 2025/10/7.
//

import SwiftUI

@main
struct MacActivitySimulatorApp: App {

    init() {
        // 注册全局快捷键：⌥⌘S 开始 / ⌥⌘X 结束
        HotKeyManager.shared.setup(
            start: { ActivityManager.shared.start() },
            stop:  { ActivityManager.shared.stop()  }
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
