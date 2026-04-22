import SwiftUI
import AppKit

// ---------------------------
// 悬浮窗口控制器
// ---------------------------
class FloatWindowController {
    var window: NSWindow?

    /// 显示悬浮窗口
    func show() {
        guard window == nil else { return }

        // SwiftUI 内容视图
        let content = FloatingPointView()

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 600, width: 160, height: 70),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.level = .floating               // 置顶
        window.hasShadow = true
        window.ignoresMouseEvents = false      // 不阻挡鼠标
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: content)

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 隐藏悬浮窗口
    func hide() {
        window?.close()
        window = nil
    }

    /// 是否可见
    func isVisible() -> Bool {
        return window != nil
    }
}

// ---------------------------
// SwiftUI 内容视图
// ---------------------------
struct FloatingPointView: View {
    @State private var posX: CGFloat = 0
    @State private var posY: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.7))  // 半透明背景

            VStack {
                Text("X: \(Int(posX))")
                Text("Y: \(Int(posY))")
            }
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .bold))
        }
        .frame(width: 160, height: 70)
        .onAppear {
            startTrackingMouse()
        }
    }

    /// 开始全局鼠标位置监听
    private func startTrackingMouse() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            let loc = NSEvent.mouseLocation   // 屏幕坐标，左下角为原点
            DispatchQueue.main.async {
                self.posX = loc.x
                self.posY = loc.y
            }
        }
    }
}
