import SwiftUI
import Cocoa

class ActivityManager: ObservableObject {
    static let shared = ActivityManager()

    // MARK: - 模式与档案
    enum ActivityMode: String, CaseIterable, Identifiable {
        case fixed = "固定活跃度"
        case schedule = "日程档案"
        var id: String { rawValue }
    }

    struct ActivityProfile: Codable, Identifiable {
        let name: String
        let description: String?
        let segments: [Segment]
        var id: String { name }

        struct Segment: Codable {
            let minutes: Int
            let activity: Int
        }

        var totalMinutes: Int { segments.reduce(0) { $0 + $1.minutes } }
        var averageActivity: Int {
            let total = totalMinutes
            guard total > 0 else { return 0 }
            let weighted = segments.reduce(0) { $0 + $1.minutes * $1.activity }
            return weighted / total
        }
    }

    private struct ProfileConfig: Codable {
        let profiles: [ActivityProfile]
    }

    @Published var mode: ActivityMode = .fixed
    @Published private(set) var profiles: [ActivityProfile] = []
    @Published var selectedProfileIndex: Int = 0

    // MARK: - 状态与统计
    @Published var statusText: String = "🔴 已停止"
    @Published var globalActivityLevelDouble: Double = 80.0
    var globalActivityLevel: Int { Int(globalActivityLevelDouble) }

    // 统计
    @Published var currentMouseCount: Int = 0
    @Published var currentKeyCount: Int = 0
    @Published var currentScrollCount: Int = 0
    @Published var totalMouseCount: Int = 0
    @Published var totalKeyCount: Int = 0
    @Published var totalScrollCount: Int = 0
    @Published var startTime: Date?
    @Published var elapsedTimeText: String = "00:00:00"
    @Published var effectiveActivityLevel: Int = 0
    @Published var currentSegmentInfo: String = "—"

    // MARK: - 三个点击坐标（UserDefaults 持久化）
    @Published var noonPauseClickPoint: CGPoint = CGPoint(x: 400, y: 300)
    @Published var noonResumeClickPoint: CGPoint = CGPoint(x: 400, y: 400)
    @Published var eveningClickPoint: CGPoint = CGPoint(x: 680, y: 477)

    private let noonPauseXKey  = "noonPauseClickPoint.x"
    private let noonPauseYKey  = "noonPauseClickPoint.y"
    private let noonResumeXKey = "noonResumeClickPoint.x"
    private let noonResumeYKey = "noonResumeClickPoint.y"
    private let eveningXKey    = "eveningClickPoint.x"
    private let eveningYKey    = "eveningClickPoint.y"

    // MARK: - 拾取状态
    enum PickTarget: String {
        case noonPause  = "12:30 暂停"
        case noonResume = "13:30 恢复"
        case evening    = "晚间触发"
    }
    @Published var pickTarget: PickTarget? = nil
    var isPickingPoint: Bool { pickTarget != nil }
    private var pickMonitor: Any?

    // MARK: - 任务执行标志
    @Published var noonPauseTaskExecuted = false
    @Published var noonResumeTaskExecuted = false
    @Published var eveningTaskExecuted = false

    // MARK: - 晚间随机触发时间（19:10–19:40）
    @Published var eveningTriggerTime: Date?
    @Published var eveningTriggerText: String = "—"

    private var elapsedTimer: Timer?
    private var running = false
    private var workThread: Thread?
    private var timers: [Timer] = []

    private let appPath = "/Applications/Monitask.app"

    // 午休时段（强制 0% 活跃度）
    private let lunchStartHour = 12
    private let lunchStartMinute = 30
    private let lunchEndHour = 13
    private let lunchEndMinute = 30

    // 晚间随机窗口
    private let eveningStartHour = 19
    private let eveningStartMinute = 10
    private let eveningEndHour = 19
    private let eveningEndMinute = 40

    private init() {
        loadProfiles()
        loadClickPoints()
    }

    // MARK: - 午休判断
    private func isInLunchBreak(_ date: Date = Date()) -> Bool {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let cur = h * 60 + m
        let start = lunchStartHour * 60 + lunchStartMinute
        let end = lunchEndHour * 60 + lunchEndMinute
        return cur >= start && cur < end
    }

    // MARK: - 加载档案
    private func loadProfiles() {
        guard let url = Bundle.main.url(forResource: "activity_config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            log("⚠️ 未找到 activity_config.json，使用内置默认档案")
            profiles = defaultProfiles()
            return
        }
        do {
            let wrapped = try JSONDecoder().decode(ProfileConfig.self, from: data)
            profiles = wrapped.profiles
            log("✅ 已加载 \(profiles.count) 个活跃度档案")
        } catch {
            log("⚠️ 配置文件解析失败：\(error.localizedDescription)，使用内置默认档案")
            profiles = defaultProfiles()
        }
    }

    private func defaultProfiles() -> [ActivityProfile] {
        return [
            ActivityProfile(name: "稳定 80%", description: "恒定 80% 活跃度", segments: [
                .init(minutes: 480, activity: 80)
            ])
        ]
    }

    // MARK: - 加载/保存坐标
    private func loadClickPoints() {
        if let x = UserDefaults.standard.object(forKey: noonPauseXKey) as? Double,
           let y = UserDefaults.standard.object(forKey: noonPauseYKey) as? Double {
            noonPauseClickPoint = CGPoint(x: x, y: y)
        }
        if let x = UserDefaults.standard.object(forKey: noonResumeXKey) as? Double,
           let y = UserDefaults.standard.object(forKey: noonResumeYKey) as? Double {
            noonResumeClickPoint = CGPoint(x: x, y: y)
        }
        if let x = UserDefaults.standard.object(forKey: eveningXKey) as? Double,
           let y = UserDefaults.standard.object(forKey: eveningYKey) as? Double {
            eveningClickPoint = CGPoint(x: x, y: y)
        }
        log("📂 坐标加载：午暂停=(\(Int(noonPauseClickPoint.x)),\(Int(noonPauseClickPoint.y))) · 午恢复=(\(Int(noonResumeClickPoint.x)),\(Int(noonResumeClickPoint.y))) · 晚间=(\(Int(eveningClickPoint.x)),\(Int(eveningClickPoint.y)))")
    }

    private func savePoint(_ target: PickTarget, _ p: CGPoint) {
        switch target {
        case .noonPause:
            noonPauseClickPoint = p
            UserDefaults.standard.set(Double(p.x), forKey: noonPauseXKey)
            UserDefaults.standard.set(Double(p.y), forKey: noonPauseYKey)
        case .noonResume:
            noonResumeClickPoint = p
            UserDefaults.standard.set(Double(p.x), forKey: noonResumeXKey)
            UserDefaults.standard.set(Double(p.y), forKey: noonResumeYKey)
        case .evening:
            eveningClickPoint = p
            UserDefaults.standard.set(Double(p.x), forKey: eveningXKey)
            UserDefaults.standard.set(Double(p.y), forKey: eveningYKey)
        }
        log("💾 保存 \(target.rawValue) 坐标：(\(Int(p.x)), \(Int(p.y)))")
    }

    // MARK: - 坐标拾取
    func startPicking(_ target: PickTarget) {
        stopPicking()
        DispatchQueue.main.async {
            self.pickTarget = target
            self.statusText = "📍 请点击「\(target.rawValue)」目标位置..."
        }
        log("📍 开始拾取「\(target.rawValue)」坐标（点屏幕任意位置完成）")

        pickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let p = CGEvent(source: nil)?.location ?? .zero
            DispatchQueue.main.async {
                self.savePoint(target, p)
                self.statusText = "✅ \(target.rawValue) 已保存：(\(Int(p.x)), \(Int(p.y)))"
                self.stopPicking()
            }
        }
    }

    func stopPicking() {
        if let m = pickMonitor {
            NSEvent.removeMonitor(m)
            pickMonitor = nil
        }
        DispatchQueue.main.async {
            self.pickTarget = nil
        }
    }

    // MARK: - 启停
    func start() {
        guard !running else { return }
        running = true
        statusText = mode == .fixed
            ? "🟢 运行中（固定 \(globalActivityLevel)%）"
            : "🟢 运行中（档案：\(currentProfile()?.name ?? "—")）"
        log(">>> 开始模拟活跃度  模式=\(mode.rawValue)")

        // 重置统计 + 重算晚间随机触发时间
        DispatchQueue.main.async {
            self.startTime = Date()
            self.currentMouseCount = 0
            self.currentKeyCount = 0
            self.currentScrollCount = 0
            self.totalMouseCount = 0
            self.totalKeyCount = 0
            self.totalScrollCount = 0
            self.elapsedTimeText = "00:00:00"

            self.elapsedTimer?.invalidate()
            self.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateElapsedText()
            }
        }

        // 重置任务执行标志（支持当天 stop+start 后重新触发）
        noonPauseTaskExecuted = false
        noonResumeTaskExecuted = false
        eveningTaskExecuted = false

        generateEveningTriggerTime()
        startNoonMonitor()
        startEveningMonitor()

        workThread = Thread {
            self.simulateWorkLoop()
        }
        workThread?.start()
    }

    func stop() {
        running = false
        stopAllTasks()
        DispatchQueue.main.async {
            self.statusText = "🔴 已停止"
            self.elapsedTimer?.invalidate()
            self.elapsedTimer = nil
        }
        log(">>> 停止所有任务")
    }

    private func updateElapsedText() {
        guard let s = startTime else {
            elapsedTimeText = "00:00:00"
            return
        }
        let sec = Int(Date().timeIntervalSince(s))
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let ss = sec % 60
        elapsedTimeText = String(format: "%02d:%02d:%02d", h, m, ss)
    }

    // MARK: - 晚间随机时间生成（19:10–19:40 之间）
    private func generateEveningTriggerTime() {
        let cal = Calendar.current
        let now = Date()
        var comp = cal.dateComponents([.year, .month, .day], from: now)
        comp.hour = eveningStartHour
        comp.minute = eveningStartMinute
        comp.second = 0
        guard let startBound = cal.date(from: comp) else { return }
        comp.hour = eveningEndHour
        comp.minute = eveningEndMinute
        guard let endBound = cal.date(from: comp) else { return }

        let interval = endBound.timeIntervalSince(startBound)
        let offset = Double.random(in: 0...interval)
        let target = startBound.addingTimeInterval(offset)

        if target < now {
            // 已经过了 19:40，今日跳过
            DispatchQueue.main.async {
                self.eveningTriggerTime = nil
                self.eveningTriggerText = "今日已过 19:40，跳过"
            }
            eveningTaskExecuted = true
            log("⏭ 已过 \(eveningEndHour):\(eveningEndMinute)，今日不再触发晚间任务")
        } else {
            DispatchQueue.main.async {
                self.eveningTriggerTime = target
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                self.eveningTriggerText = "今日触发：\(f.string(from: target))"
            }
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            log("⏰ 今日晚间触发时间：\(f.string(from: target))（窗口 19:10–19:40）")
        }
    }

    // MARK: - 当前档案/活跃度
    func currentProfile() -> ActivityProfile? {
        guard selectedProfileIndex >= 0 && selectedProfileIndex < profiles.count else {
            return profiles.first
        }
        return profiles[selectedProfileIndex]
    }

    private func computeActivityLevel() -> Int {
        if isInLunchBreak() {
            DispatchQueue.main.async {
                self.effectiveActivityLevel = 0
                self.currentSegmentInfo = "🍱 午休时段 \(String(format: "%02d:%02d", self.lunchStartHour, self.lunchStartMinute))–\(String(format: "%02d:%02d", self.lunchEndHour, self.lunchEndMinute))，活跃度强制 0%"
            }
            return 0
        }

        switch mode {
        case .fixed:
            let lvl = globalActivityLevel
            DispatchQueue.main.async {
                self.effectiveActivityLevel = lvl
                self.currentSegmentInfo = "固定 \(lvl)%"
            }
            return lvl
        case .schedule:
            guard let profile = currentProfile(), profile.totalMinutes > 0,
                  let start = startTime else {
                let lvl = globalActivityLevel
                DispatchQueue.main.async {
                    self.effectiveActivityLevel = lvl
                    self.currentSegmentInfo = "档案不可用，回落到固定 \(lvl)%"
                }
                return lvl
            }
            let elapsedMin = Int(Date().timeIntervalSince(start) / 60)
            var offset = elapsedMin % profile.totalMinutes
            for (i, seg) in profile.segments.enumerated() {
                if offset < seg.minutes {
                    let lvl = seg.activity
                    let remaining = seg.minutes - offset
                    DispatchQueue.main.async {
                        self.effectiveActivityLevel = lvl
                        self.currentSegmentInfo = "\(profile.name) · 段\(i + 1)/\(profile.segments.count) · \(lvl)% · 剩 \(remaining) 分"
                    }
                    return lvl
                }
                offset -= seg.minutes
            }
            return globalActivityLevel
        }
    }

    // MARK: - 主循环
    private func simulateWorkLoop() {
        var windowStart = Date()
        var mouseInWindow = 0
        var keyInWindow = 0
        var scrollInWindow = 0

        DispatchQueue.main.async {
            self.currentMouseCount = 0
            self.currentKeyCount = 0
            self.currentScrollCount = 0
        }

        while running {
            let now = Date()
            let elapsed = now.timeIntervalSince(windowStart)

            if elapsed >= 60 {
                if !isInLunchBreak() {
                    if mouseInWindow == 0 {
                        log(">>> 窗口收尾补齐：鼠标")
                        simulateMouseMoveSmooth()
                        incrementMouseCount()
                    }
                    if keyInWindow == 0 {
                        log(">>> 窗口收尾补齐：键盘")
                        simulateKeyPress()
                        incrementKeyCount()
                    }
                }
                windowStart = now
                mouseInWindow = 0
                keyInWindow = 0
                scrollInWindow = 0
                DispatchQueue.main.async {
                    self.currentMouseCount = 0
                    self.currentKeyCount = 0
                    self.currentScrollCount = 0
                }
                continue
            }

            let level = computeActivityLevel()

            if level <= 0 {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            let baseEventsPerMinute = 30
            let targetEvents = max(2, Int(Double(baseEventsPerMinute) * Double(level) / 100.0))
            let totalDone = mouseInWindow + keyInWindow + scrollInWindow

            if mouseInWindow > 0 && keyInWindow > 0 && Bool.random(probability: 0.05) {
                let idle = Double.random(in: 10...20)
                log("🟡 发呆 \(Int(idle)) 秒")
                Thread.sleep(forTimeInterval: idle)
                continue
            }

            if mouseInWindow == 0 {
                simulateMouseMoveSmooth(); mouseInWindow += 1; incrementMouseCount()
            } else if keyInWindow == 0 {
                simulateKeyPress(); keyInWindow += 1; incrementKeyCount()
            } else if totalDone < targetEvents {
                let r = Double.random(in: 0...1)
                if r < 0.55 {
                    simulateMouseMoveSmooth(); mouseInWindow += 1; incrementMouseCount()
                } else if r < 0.85 {
                    simulateKeyPress(); keyInWindow += 1; incrementKeyCount()
                } else {
                    simulateScroll(); scrollInWindow += 1; incrementScrollCount()
                }
            }

            let remainingTime = max(1.0, 60 - elapsed)
            let totalAfter = mouseInWindow + keyInWindow + scrollInWindow
            let remainingEvents = max(1, targetEvents - totalAfter)
            let interval = remainingTime / Double(remainingEvents)
            let actualInterval = interval * Double.random(in: 0.7...1.3)

            Thread.sleep(forTimeInterval: actualInterval)
        }
    }

    private func incrementMouseCount() {
        DispatchQueue.main.async { self.currentMouseCount += 1; self.totalMouseCount += 1 }
    }
    private func incrementKeyCount() {
        DispatchQueue.main.async { self.currentKeyCount += 1; self.totalKeyCount += 1 }
    }
    private func incrementScrollCount() {
        DispatchQueue.main.async { self.currentScrollCount += 1; self.totalScrollCount += 1 }
    }

    // MARK: - 平滑鼠标移动
    private func simulateMouseMoveSmooth() {
        guard running else { return }
        guard let screen = NSScreen.main else { return }

        let from = CGEvent(source: nil)?.location
                   ?? CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        let screenW = screen.frame.width
        let screenH = screen.frame.height
        let to = CGPoint(
            x: CGFloat.random(in: 50...(screenW - 50)),
            y: CGFloat.random(in: 50...(screenH - 50))
        )

        let midX = (from.x + to.x) / 2 + CGFloat.random(in: -120...120)
        let midY = (from.y + to.y) / 2 + CGFloat.random(in: -120...120)
        let control = CGPoint(x: midX, y: midY)

        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = sqrt(dx * dx + dy * dy)
        let steps = max(20, min(80, Int(distance / 15)))

        let src = CGEventSource(stateID: .hidSystemState)
        for i in 1...steps {
            guard running else { return }
            let t = Double(i) / Double(steps)
            let oneMinusT = 1 - t
            let x = oneMinusT * oneMinusT * Double(from.x)
                  + 2 * oneMinusT * t * Double(control.x)
                  + t * t * Double(to.x)
            let y = oneMinusT * oneMinusT * Double(from.y)
                  + 2 * oneMinusT * t * Double(control.y)
                  + t * t * Double(to.y)

            let pt = CGPoint(x: x, y: y)
            let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                               mouseCursorPosition: pt, mouseButton: .left)
            move?.post(tap: .cgSessionEventTap)
            Thread.sleep(forTimeInterval: Double.random(in: 0.005...0.015))
        }

        log("🖱 平滑移动 → (\(Int(to.x)),\(Int(to.y)))，\(steps) 步")
    }

    private func simulateKeyPress() {
        guard running else { return }
        let keyCode: CGKeyCode = 113
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Double.random(in: 0.05...0.15))
        up?.post(tap: .cghidEventTap)
        log("⌨️ 按键 F15")
    }

    private func simulateScroll() {
        guard running else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let direction: Int32 = Bool.random() ? 1 : -1
        let amount = Int32.random(in: 1...3) * direction
        if let scroll = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) {
            scroll.post(tap: .cghidEventTap)
        }
        log("🖲 滚轮 \(amount)")
    }

    // MARK: - 午间任务监控（12:30 暂停 / 13:30 恢复）
    private func startNoonMonitor() {
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkNoonTasks()
        }
        timers.append(t)
    }

    private func checkNoonTasks() {
        guard running else { return }
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        let m = cal.component(.minute, from: Date())

        if h == 12 && m == 30 && !noonPauseTaskExecuted {
            executeNoonPauseTask()
        }
        if h == 13 && m == 30 && !noonResumeTaskExecuted {
            executeNoonResumeTask()
        }
    }

    private func executeNoonPauseTask() {
        noonPauseTaskExecuted = true
        log(">>> 12:30 暂停任务触发 → 点击 (\(Int(noonPauseClickPoint.x)), \(Int(noonPauseClickPoint.y)))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            log(">>> 打开 App: \(self.appPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.performClick(at: self.noonPauseClickPoint)
                log(">>> 12:30 暂停点击完成")
                DispatchQueue.main.async { self.statusText = "🟡 午间暂停（12:30 已点击）" }
            }
        }
    }

    private func executeNoonResumeTask() {
        noonResumeTaskExecuted = true
        noonPauseTaskExecuted = false
        log(">>> 13:30 恢复任务触发 → 点击 (\(Int(noonResumeClickPoint.x)), \(Int(noonResumeClickPoint.y)))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            log(">>> 打开 App: \(self.appPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.performClick(at: self.noonResumeClickPoint)
                log(">>> 13:30 恢复点击完成")
                DispatchQueue.main.async { self.statusText = "🟢 午间恢复（13:30 已点击）" }
            }
        }
    }

    // MARK: - 晚间任务（19:10–19:40 随机时间触发一次）
    func startEveningMonitor() {
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkEveningWindow()
        }
        timers.append(t)
    }

    private func checkEveningWindow() {
        guard running, !eveningTaskExecuted, let target = eveningTriggerTime else { return }
        if Date() >= target {
            executeEveningTask()
        }
    }

    private func executeEveningTask() {
        eveningTaskExecuted = true
        log(">>> 晚间任务触发，停止全部后台任务 → 点击 (\(Int(eveningClickPoint.x)), \(Int(eveningClickPoint.y)))")
        stopAllTasks()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            log(">>> 打开 App: \(self.appPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.performClick(at: self.eveningClickPoint)
                log(">>> 晚间点击完成")
            }
        }
    }

    // MARK: - 测试按钮：分别测试三个点击
    func testNoonPauseClick() {
        log(">>> 【测试】12:30 暂停点击")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.performClick(at: self.noonPauseClickPoint)
                log(">>> 【测试】12:30 暂停点击完成")
            }
        }
    }

    func testNoonResumeClick() {
        log(">>> 【测试】13:30 恢复点击")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.performClick(at: self.noonResumeClickPoint)
                log(">>> 【测试】13:30 恢复点击完成")
            }
        }
    }

    func testEveningClick() {
        log(">>> 【测试】晚间点击")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.performClick(at: self.eveningClickPoint)
                log(">>> 【测试】晚间点击完成")
            }
        }
    }

    /// 测试整套流程：依次执行 12:30 → 13:30 → 晚间，每个间隔 8 秒
    func testFullFlow() {
        log(">>> 【测试】全流程：12:30 → 13:30 → 晚间")
        testNoonPauseClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.testNoonResumeClick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.testEveningClick()
            }
        }
    }

    // MARK: - 基础点击
    func performClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        log("🖱 点击 (\(Int(point.x)), \(Int(point.y)))")
    }

    func stopAllTasks() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        running = false
        workThread?.cancel()
        workThread = nil
    }
}

extension Bool {
    static func random(probability: Double) -> Bool {
        Double.random(in: 0...1) < probability
    }
}
