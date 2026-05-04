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

    // MARK: - 10 分钟波动
    @Published var enableTenMinJitter: Bool = false {
        didSet {
            UserDefaults.standard.set(enableTenMinJitter, forKey: tenMinJitterKey)
            if !enableTenMinJitter {
                resetJitterState()
            }
        }
    }
    private let tenMinJitterKey = "enableTenMinJitter"
    private var currentBucketIndex: Int = -1
    private var currentBucketLevel: Int = 0
    private var pendingBucketOffset: Int? = nil

    // MARK: - 活跃分钟分布（让 Monitask 看到真实的活跃比例）
    // 每个 10 分钟桶里，按当前 level 分配 N 个活跃分钟 + (10-N) 个空闲分钟
    // 空闲分钟内一个事件都不发，让 Monitask 把这一分钟判为无活动
    private var minuteActiveFlags: [Bool] = Array(repeating: true, count: 10)
    private var minuteFlagsBucketIdx: Int = -1

    // MARK: - 随机分心（模拟人类切到 Telegram/Chrome/访达 看一会儿）
    @Published var enableRandomDistraction: Bool = false {
        didSet {
            UserDefaults.standard.set(enableRandomDistraction, forKey: distractionKey)
            if enableRandomDistraction && running {
                scheduleNextDistraction()
            } else if !enableRandomDistraction {
                distractionTimer?.invalidate()
                distractionTimer = nil
                DispatchQueue.main.async { self.nextDistractionText = "—" }
            }
        }
    }
    private let distractionKey = "enableRandomDistraction"
    private var distractionTimer: Timer?
    private var distractionInProgress = false
    @Published var nextDistractionText: String = "—"

    private let distractionAppNames = ["Telegram", "Chrome", "访达"]
    private let androidStudioPath = "/Applications/Android Studio.app"

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
        enableTenMinJitter = UserDefaults.standard.bool(forKey: tenMinJitterKey)
        enableRandomDistraction = UserDefaults.standard.bool(forKey: distractionKey)
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

        // 重置 10 分钟波动桶状态 + 活跃分钟分布
        resetJitterState()
        resetMinuteFlags()

        generateEveningTriggerTime()
        startNoonMonitor()
        startEveningMonitor()

        if enableRandomDistraction {
            scheduleNextDistraction()
        }

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

    /// 计算「基线」活跃度（不含 10 分钟波动），返回 (level, 显示信息)
    private func computeBaseActivity() -> (level: Int, info: String) {
        if isInLunchBreak() {
            let info = "🍱 午休时段 \(String(format: "%02d:%02d", lunchStartHour, lunchStartMinute))–\(String(format: "%02d:%02d", lunchEndHour, lunchEndMinute))，活跃度强制 0%"
            return (0, info)
        }

        switch mode {
        case .fixed:
            let lvl = globalActivityLevel
            return (lvl, "固定 \(lvl)%")
        case .schedule:
            guard let profile = currentProfile(), profile.totalMinutes > 0,
                  let start = startTime else {
                let lvl = globalActivityLevel
                return (lvl, "档案不可用，回落到固定 \(lvl)%")
            }
            let elapsedMin = Int(Date().timeIntervalSince(start) / 60)
            var offset = elapsedMin % profile.totalMinutes
            for (i, seg) in profile.segments.enumerated() {
                if offset < seg.minutes {
                    let lvl = seg.activity
                    let remaining = seg.minutes - offset
                    return (lvl, "\(profile.name) · 段\(i + 1)/\(profile.segments.count) · \(lvl)% · 剩 \(remaining) 分")
                }
                offset -= seg.minutes
            }
            return (globalActivityLevel, "档案越界，回落到固定 \(globalActivityLevel)%")
        }
    }

    /// 重置 10 分钟波动桶状态
    private func resetJitterState() {
        currentBucketIndex = -1
        currentBucketLevel = 0
        pendingBucketOffset = nil
    }

    /// 重置活跃分钟分布
    private func resetMinuteFlags() {
        minuteActiveFlags = Array(repeating: true, count: 10)
        minuteFlagsBucketIdx = -1
    }

    /// 进入新 10 分钟桶时根据 level 重新分配活跃/空闲分钟
    /// level=70% → 7 个活跃分钟 + 3 个空闲分钟，位置随机打散
    private func ensureMinuteFlags(forLevel level: Int) {
        guard let s = startTime else {
            // 还没拿到 startTime，全部按活跃处理
            return
        }
        let bucketIdx = Int(Date().timeIntervalSince(s) / 600)
        if bucketIdx == minuteFlagsBucketIdx { return }

        let activeCount = max(0, min(10, Int((Double(level) / 10.0).rounded())))
        var flags = Array(repeating: false, count: 10)
        for i in (0..<10).shuffled().prefix(activeCount) {
            flags[i] = true
        }
        minuteActiveFlags = flags
        minuteFlagsBucketIdx = bucketIdx
        let pattern = flags.map { $0 ? "■" : "□" }.joined()
        log("🪟 第 \(bucketIdx + 1) 个 10 分钟桶 → \(activeCount)/10 活跃分钟 [\(pattern)]（基于 \(level)%）")
    }

    /// 当前所在的「分钟槽位」（10 分钟桶内的 0..9）是否标记为活跃
    private func isCurrentMinuteActive() -> Bool {
        guard let s = startTime, !minuteActiveFlags.isEmpty else { return true }
        let inBucket = Date().timeIntervalSince(s).truncatingRemainder(dividingBy: 600)
        let idx = max(0, min(9, Int(inBucket / 60)))
        return minuteActiveFlags[idx]
    }

    /// 基于基线活跃度，按 10 分钟桶生成「一高一低配对」的实际活跃度
    /// 算法：相邻两个 10 分钟桶配对，第一桶随机决定高/低，第二桶取相反方向
    /// 高桶 = 基线 + spread，低桶 = 基线 - spread，spread 在 25..40 之间随机
    /// 这样长时间均值仍接近基线，但每个 10 分钟桶有明显起伏
    private func bucketAdjustedLevel(base: Int) -> Int {
        guard let start = startTime else { return base }
        let elapsedSec = Date().timeIntervalSince(start)
        let bucketIdx = Int(elapsedSec / 600)   // 600 秒 = 10 分钟

        if bucketIdx == currentBucketIndex {
            return currentBucketLevel
        }

        currentBucketIndex = bucketIdx

        let offsetToUse: Int
        if let pending = pendingBucketOffset {
            // 配对中的第二桶：使用上一桶预存的反向偏移
            offsetToUse = pending
            pendingBucketOffset = nil
        } else {
            // 新的一对桶：随机决定本桶是高峰还是低谷
            let spread = Int.random(in: 25...40)
            let highFirst = Bool.random()
            offsetToUse = highFirst ? spread : -spread
            pendingBucketOffset = highFirst ? -spread : spread
        }

        let raw = base + offsetToUse
        let clamped = max(8, min(100, raw))     // 至少 8% 防止被判定为完全空闲
        currentBucketLevel = clamped
        let sign = offsetToUse > 0 ? "+" : ""
        log("🎲 进入第 \(bucketIdx + 1) 个 10 分钟桶 → \(clamped)%（基线 \(base)%, 偏移 \(sign)\(offsetToUse)）")
        return clamped
    }

    private func computeActivityLevel() -> Int {
        let base = computeBaseActivity()

        // 午休强制 0%，不参与波动
        if base.level == 0 {
            DispatchQueue.main.async {
                self.effectiveActivityLevel = 0
                self.currentSegmentInfo = base.info
            }
            return 0
        }

        let finalLevel: Int
        let info: String
        if enableTenMinJitter {
            let bucketLvl = bucketAdjustedLevel(base: base.level)
            finalLevel = bucketLvl
            info = "\(base.info) · 🎲 桶 \(bucketLvl)%"
        } else {
            finalLevel = base.level
            info = base.info
        }

        DispatchQueue.main.async {
            self.effectiveActivityLevel = finalLevel
            self.currentSegmentInfo = info
        }
        return finalLevel
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
                // 仅在「这一分钟产生过事件」（也就是该分钟原本是活跃分钟）时才补齐两类
                // 空闲分钟保持完全无事件，让 Monitask 把它判为 idle
                let hadActivity = (mouseInWindow + keyInWindow + scrollInWindow) > 0
                if !isInLunchBreak() && hadActivity {
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
            ensureMinuteFlags(forLevel: level)

            if level <= 0 {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            // 空闲分钟：什么都不发，让 Monitask 真的把这一分钟当 idle
            if !isCurrentMinuteActive() {
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
        // 一次「滚动事件」其实是 2-4 个连续滚轮 tick，更接近真人滑动手感
        let src = CGEventSource(stateID: .hidSystemState)
        let direction: Int32 = Bool.random() ? 1 : -1
        let ticks = Int.random(in: 2...4)
        for _ in 0..<ticks {
            guard running else { return }
            let amount = Int32.random(in: 3...8) * direction
            if let scroll = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                    wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) {
                scroll.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0.03...0.10))
        }
        log("🖲 滚轮 \(direction > 0 ? "↑" : "↓") × \(ticks)")
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
                // 点击完成后延迟 0.8 秒最小化 Monitask
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.minimizeMonitask()
                }
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

    /// 完整复现真实 13:30 恢复流程（2s+3s 延迟、更新状态文字、点击后最小化），
    /// 但不修改任务执行标志，可反复触发
    func simulateNoonResumeFlow() {
        log(">>> 【模拟 13:30】完整复现 13:30 恢复任务（不写执行标志，可重复触发）")
        DispatchQueue.main.async { self.statusText = "🟡 模拟 13:30 恢复中..." }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: self.appPath))
            log(">>> 【模拟 13:30】打开 App: \(self.appPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.performClick(at: self.noonResumeClickPoint)
                log(">>> 【模拟 13:30】恢复点击完成")
                DispatchQueue.main.async { self.statusText = "🟢 已模拟 13:30 恢复点击" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.minimizeMonitask()
                }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.minimizeMonitask()
                }
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

    // MARK: - 随机分心调度
    /// 安排下一次随机分心：15–40 分钟后
    private func scheduleNextDistraction() {
        distractionTimer?.invalidate()
        let interval = TimeInterval.random(in: 15 * 60 ... 40 * 60)
        let target = Date().addingTimeInterval(interval)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        DispatchQueue.main.async {
            self.nextDistractionText = "下次分心：\(f.string(from: target))"
        }
        log("⏰ 下次随机分心：\(f.string(from: target))（约 \(Int(interval / 60)) 分钟后）")

        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.executeRandomDistraction()
        }
        distractionTimer = t
    }

    /// 触发一次随机分心：开 App → 上下滚动 8–20 秒 → 切回 Android Studio
    func executeRandomDistraction() {
        guard !distractionInProgress else {
            log("⚠️ 分心已在进行中，跳过本次")
            return
        }
        // 午休或当前活跃度为 0 时跳过，但仍排下一次
        let base = computeBaseActivity()
        if isInLunchBreak() || base.level == 0 {
            log("🎬 当前 0% 活跃，跳过本次分心，重新排期")
            if running && enableRandomDistraction { scheduleNextDistraction() }
            return
        }

        distractionInProgress = true
        let appName = distractionAppNames.randomElement() ?? "Chrome"
        log("🎬 随机分心 → 打开 \(appName)")
        DispatchQueue.main.async {
            self.statusText = "🎬 模拟使用 \(appName) ..."
        }
        openDistractionApp(appName)

        let browseDuration = Double.random(in: 8...20)
        // 等 1.5 秒让 App 起来，再开始滚动
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DispatchQueue.global(qos: .userInitiated).async {
                let endAt = Date().addingTimeInterval(browseDuration)
                while Date() < endAt {
                    self.simulateScrollBurst()
                    // 每段滚动后短暂「停下来读一下」
                    Thread.sleep(forTimeInterval: Double.random(in: 0.5...1.8))
                }

                // 切回 Android Studio
                DispatchQueue.main.async {
                    log("🎬 浏览 \(Int(browseDuration)) 秒结束 → 切回 Android Studio")
                    NSWorkspace.shared.open(URL(fileURLWithPath: self.androidStudioPath))
                    self.distractionInProgress = false

                    if self.running {
                        // 恢复正常状态文字
                        self.statusText = self.mode == .fixed
                            ? "🟢 运行中（固定 \(self.globalActivityLevel)%）"
                            : "🟢 运行中（档案：\(self.currentProfile()?.name ?? "—")）"
                        if self.enableRandomDistraction {
                            self.scheduleNextDistraction()
                        }
                    }
                }
            }
        }
    }

    /// 把指定名字映射到具体的打开方式
    private func openDistractionApp(_ name: String) {
        switch name {
        case "Telegram":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Telegram.app"))
        case "Chrome":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        case "访达":
            // 打开用户主目录窗口，等于把 Finder 拉到前台
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        default:
            break
        }
    }

    /// 一次「连续上下滚动」：5–12 个滚轮 tick，方向随机一致
    private func simulateScrollBurst() {
        let src = CGEventSource(stateID: .hidSystemState)
        let direction: Int32 = Bool.random() ? -1 : 1
        let ticks = Int.random(in: 5...12)
        for _ in 0..<ticks {
            let amount = Int32.random(in: 8...18) * direction
            if let scroll = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                    wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) {
                scroll.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.async {
                self.currentScrollCount += 1
                self.totalScrollCount += 1
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0.04...0.13))
        }
        log("🖲 分心滚动 \(ticks) 次（\(direction > 0 ? "↑" : "↓")）")
    }

    /// 测试按钮：立即触发一次分心流程
    func testDistraction() {
        log(">>> 【测试】立即触发随机分心")
        executeRandomDistraction()
    }

    // MARK: - 最小化 Monitask
    /// 发送 ⌘+M 将 Monitask 当前窗口最小化到 Dock。
    /// 前提：调用前 Monitask 应是前台 App（点击之后通常满足）。
    func minimizeMonitask() {
        // 兜底：先确保 Monitask 是激活状态
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == self.appPath || $0.localizedName == "Monitask"
        }) {
            app.activate()
        }

        // 稍等 0.15 秒让前台切换生效再发 ⌘+M
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .hidSystemState)
            let kVK_ANSI_M: CGKeyCode = 46
            let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_M, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_M, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            log("🗕 已发送 ⌘+M 最小化 Monitask")
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
        distractionTimer?.invalidate()
        distractionTimer = nil
        distractionInProgress = false
        DispatchQueue.main.async { self.nextDistractionText = "—" }
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
