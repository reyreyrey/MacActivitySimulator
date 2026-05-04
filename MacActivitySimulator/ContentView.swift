import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ActivityManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 顶部状态
                Text(manager.statusText)
                    .font(.title3)
                    .padding(.top, 4)

                // 启动配置
                GroupBox(label: Text("启动配置").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("模式", selection: $manager.mode) {
                            ForEach(ActivityManager.ActivityMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if manager.mode == .fixed {
                            HStack(spacing: 6) {
                                Text("预设：").foregroundColor(.secondary)
                                presetButton("低 40%", value: 40)
                                presetButton("中 65%", value: 65)
                                presetButton("高 85%", value: 85)
                                presetButton("满 100%", value: 100)
                            }
                            HStack {
                                Slider(value: $manager.globalActivityLevelDouble, in: 0...100, step: 1)
                                Text("\(manager.globalActivityLevel)%")
                                    .frame(width: 45, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        } else {
                            Picker("档案", selection: $manager.selectedProfileIndex) {
                                ForEach(Array(manager.profiles.enumerated()), id: \.offset) { idx, p in
                                    Text(p.name).tag(idx)
                                }
                            }
                            if let p = manager.currentProfile() {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let d = p.description {
                                        Text(d).font(.caption).foregroundColor(.secondary)
                                    }
                                    Text("总时长 \(p.totalMinutes) 分钟 · 平均活跃度 \(p.averageActivity)%")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Divider()

                        Toggle(isOn: $manager.enableTenMinJitter) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("10 分钟随机波动").font(.callout)
                                Text("相邻 10 分钟桶配对：一高一低（基线 ± 25~40%），整体均值仍接近设置值")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: $manager.enableRandomDistraction) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("随机分心（Telegram / Chrome / 访达）").font(.callout)
                                Text("每 15~40 分钟随机切到其中一个 App，上下滚动 8~20 秒后切回 Android Studio")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        if manager.enableRandomDistraction {
                            HStack {
                                Text(manager.nextDistractionText)
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                                Spacer()
                                Button("立即测试分心") { manager.testDistraction() }
                                    .buttonStyle(.bordered)
                                    .tint(.purple)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                // 启停按钮
                VStack(spacing: 4) {
                    HStack(spacing: 12) {
                        Button("开始") { manager.start() }
                            .frame(width: 110, height: 40)
                            .background(Color.green).foregroundColor(.white).cornerRadius(6)
                            .keyboardShortcut("s", modifiers: [.command, .option])
                        Button("结束") { manager.stop() }
                            .frame(width: 110, height: 40)
                            .background(Color.red).foregroundColor(.white).cornerRadius(6)
                            .keyboardShortcut("x", modifiers: [.command, .option])
                    }
                    Text("快捷键：⌥⌘S 开始 · ⌥⌘X 结束（全局）")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // 实时统计
                GroupBox(label: Text("实时统计").font(.headline)) {
                    VStack(spacing: 6) {
                        HStack {
                            Label(manager.elapsedTimeText, systemImage: "clock")
                                .monospacedDigit()
                            Spacer()
                            Text("当前 \(manager.effectiveActivityLevel)%")
                                .foregroundColor(.accentColor)
                                .bold()
                        }
                        Text(manager.currentSegmentInfo)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Image(systemName: "moon.stars")
                                .foregroundColor(.indigo)
                            Text(manager.eveningTriggerText)
                                .font(.caption)
                                .foregroundColor(.indigo)
                            Spacer()
                        }
                        Divider()
                        HStack(spacing: 6) {
                            StatBadge(title: "鼠标", current: manager.currentMouseCount,
                                      total: manager.totalMouseCount, color: .blue)
                            StatBadge(title: "键盘", current: manager.currentKeyCount,
                                      total: manager.totalKeyCount, color: .green)
                            StatBadge(title: "滚轮", current: manager.currentScrollCount,
                                      total: manager.totalScrollCount, color: .orange)
                        }
                        HStack {
                            Text("当前 60s 窗口").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("启动以来累计").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }

                // 坐标设置
                GroupBox(label: Text("点击坐标设置").font(.headline)) {
                    VStack(spacing: 8) {
                        if manager.isPickingPoint {
                            HStack {
                                Text("👉 请在屏幕上点击「\(manager.pickTarget?.rawValue ?? "")」目标位置")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Spacer()
                                Button("取消拾取") { manager.stopPicking() }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                        } else {
                            CoordRow(label: "12:30 暂停",
                                     point: manager.noonPauseClickPoint,
                                     pickAction: { manager.startPicking(.noonPause) },
                                     testAction: { manager.testNoonPauseClick() })
                            CoordRow(label: "13:30 恢复",
                                     point: manager.noonResumeClickPoint,
                                     pickAction: { manager.startPicking(.noonResume) },
                                     testAction: { manager.testNoonResumeClick() })
                            CoordRow(label: "晚间触发 (19:10–19:40 随机)",
                                     point: manager.eveningClickPoint,
                                     pickAction: { manager.startPicking(.evening) },
                                     testAction: { manager.testEveningClick() })
                            CoordRow(label: "Monitask 最小化按钮 (左上黄点)",
                                     point: manager.minimizeClickPoint,
                                     pickAction: { manager.startPicking(.minimize) },
                                     testAction: { manager.testMinimizeClick() })

                            Divider().padding(.vertical, 2)

                            HStack(spacing: 8) {
                                Spacer()
                                Button("模拟 13:30 全流程") { manager.simulateNoonResumeFlow() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                Button("一键全流程测试") { manager.testFullFlow() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.purple)
                                Spacer()
                            }

                            Text("提示：先打开 Monitask 把窗口摆到固定位置，再分别点「取」按钮去抓坐标。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                }

                // 日志
                LogView()
                    .frame(height: 130)
            }
            .padding()
        }
        .frame(width: 560, height: 880)
    }

    private func presetButton(_ title: String, value: Double) -> some View {
        Button(title) {
            manager.globalActivityLevelDouble = value
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct CoordRow: View {
    let label: String
    let point: CGPoint
    let pickAction: () -> Void
    let testAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("(\(Int(point.x)), \(Int(point.y)))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Spacer()
            Button("取") { pickAction() }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
            Button("测试") { testAction() }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

struct StatBadge: View {
    let title: String
    let current: Int
    let total: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text("\(current)")
                .font(.title2).bold()
                .foregroundColor(color)
                .monospacedDigit()
            Text("∑ \(total)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }
}
