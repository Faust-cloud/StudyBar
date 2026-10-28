// StudyBar（学习计时本）· Mac 菜单栏学习计时器
// 需要 macOS 13 及以上。把整个文件内容替换 Xcode 新项目里的 xxxApp.swift，
// 并删除自动生成的 ContentView.swift。
// 新加的字段都是可选的，旧版本存下的数据可以直接读出来。

import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - 数据模型

struct Subject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var hidden: Bool?        // 删除的科目只隐藏，历史记录里的名字还在
}

struct Plan: Codable, Identifiable {
    var id = UUID()
    var day: String
    var text: String
    var subjectID: UUID
    var targetMin: Int
    var done = false
}

struct Session: Codable, Identifiable {
    var id = UUID()
    var subjectID: UUID
    var planID: UUID?
    var begin: Date
    var end: Date
    var duration: TimeInterval
    var pomodoro: Bool?      // 完整完成的番茄
    var manual: Bool?        // 手动补的记录
}

struct Running: Codable {
    var subjectID: UUID
    var planID: UUID?
    var begin: Date          // 第一次开始的时间，用于记录
    var start: Date          // 本段（暂停后继续）开始的时间
    var accumulated: TimeInterval = 0
    var paused = false
    var lastSeen: Date?      // 每分钟记一次，用来判断应用是什么时候被关掉的
    var pausedAt: Date?      // 最近一次暂停的时刻
    var pomodoro: Bool?      // 这一次是不是番茄钟
}

struct DayStat: Identifiable {
    let id: Int
    let label: String
    let parts: [(UUID, TimeInterval)]
    let total: TimeInterval
}

let palette: [Color] = [
    Color(red: 0.85, green: 0.28, blue: 0.17),
    Color(red: 0.18, green: 0.43, blue: 0.71),
    Color(red: 0.24, green: 0.55, blue: 0.35),
    Color(red: 0.77, green: 0.54, blue: 0.07),
    Color(red: 0.48, green: 0.30, blue: 0.69),
    Color(red: 0.12, green: 0.54, blue: 0.54),
    Color(red: 0.71, green: 0.27, blue: 0.47),
]

enum Fmt {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
    static func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func short(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m)分" }
        return m % 60 == 0 ? "\(m / 60)时" : "\(m / 60)时\(m % 60)分"
    }
}

// MARK: - 存储

final class Store: ObservableObject {
    @Published var subjects: [Subject] = []
    @Published var plans: [Plan] = []
    @Published var sessions: [Session] = [] { didSet { rebuildCache() } }
    @Published var running: Running?
    @Published var now = Date()
    @Published var notice: String?

    // 设置
    @Published var dailyGoalMin = 120
    @Published var pomodoroMode = false
    @Published var focusMin = 25
    @Published var breakMin = 5

    // 番茄钟休息
    @Published var breakEnd: Date?
    @Published var lastSubjectID: UUID?
    @Published var lastPlanID: UUID?

    static let idleLimit: TimeInterval = 10 * 60      // 10 分钟没动电脑，回来时问一下这段算不算
    static let longSession: TimeInterval = 2 * 3600   // 连续计时 2 小时提醒一次

    private let key = "study-timer-v1"
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastDay = ""
    private var remindedBegin: Date?
    private var lastHeartbeat = Date.distantPast
    private var awaySince: Date?
    private var asking = false
    private var goalNotifiedDay = ""

    // 统计缓存：只在记录变化时重算，不用每秒把全部历史算一遍
    private var dayTotalsCache: [String: [UUID: TimeInterval]] = [:]
    private var daySessionsCache: [String: [Session]] = [:]
    private var planSpentCache: [UUID: TimeInterval] = [:]

    private struct Snapshot: Codable {
        var subjects: [Subject]
        var plans: [Plan]
        var sessions: [Session]
        var running: Running?
        var dailyGoalMin: Int?
        var pomodoroMode: Bool?
        var focusMin: Int?
        var breakMin: Int?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            if let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                subjects = snap.subjects
                plans = snap.plans
                sessions = snap.sessions
                running = snap.running
                dailyGoalMin = snap.dailyGoalMin ?? 120
                pomodoroMode = snap.pomodoroMode ?? false
                focusMin = snap.focusMin ?? 25
                breakMin = snap.breakMin ?? 5
            } else {
                // 读不出来时先把原始数据另存一份，避免被空数据覆盖
                let backupKey = key + "-backup-" + String(Int(Date().timeIntervalSince1970))
                UserDefaults.standard.set(data, forKey: backupKey)
                notice = "旧数据读取失败，已另存备份（\(backupKey)），先别删应用"
            }
        }
        if subjects.isEmpty {
            subjects = [Subject(name: "英语", colorIndex: 0), Subject(name: "数学", colorIndex: 1)]
        }
        rebuildCache()
        lastDay = Fmt.day(Date())
        rollOverPlans()
        if total(for: today) >= goalSeconds { goalNotifiedDay = today }

        // 上次关掉应用时还在计时：从最后一次“我还在”的时间点暂停，关掉的那段不算
        if let r = running, !r.paused {
            let last = r.lastSeen ?? Date()
            pause(at: last, reason: "上次退出时还在计时，已从 \(Fmt.hm.string(from: last)) 自动暂停")
        }

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // 合上电脑：记下离开的时间，回来再问
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let r = self.running, !r.paused, self.awaySince == nil else { return }
            self.awaySince = Date()
        })
        // 正常退出应用时先暂停
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pause(at: Date(), reason: "上次退出时还在计时，已自动暂停")
        })

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func save() {
        let snap = Snapshot(subjects: subjects, plans: plans, sessions: sessions, running: running,
                            dailyGoalMin: dailyGoalMin, pomodoroMode: pomodoroMode,
                            focusMin: focusMin, breakMin: breakMin)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func rebuildCache() {
        var totals: [String: [UUID: TimeInterval]] = [:]
        var byDay: [String: [Session]] = [:]
        var byPlan: [UUID: TimeInterval] = [:]
        for s in sessions {
            let d = Fmt.day(s.begin)
            totals[d, default: [:]][s.subjectID, default: 0] += s.duration
            byDay[d, default: []].append(s)
            if let p = s.planID { byPlan[p, default: 0] += s.duration }
        }
        dayTotalsCache = totals
        daySessionsCache = byDay
        planSpentCache = byPlan
    }

    // MARK: 每秒

    private func tick() {
        now = Date()
        if asking { return }
        if today != lastDay {
            lastDay = today
            rollOverPlans()
        }
        if let be = breakEnd, now >= be {
            breakEnd = nil
            notice = "休息结束，点「再来一个」继续"
            notify("休息结束", "开始下一个番茄吧")
        }
        guard let r = running, !r.paused else { return }

        if now.timeIntervalSince(lastHeartbeat) >= 60 {
            lastHeartbeat = now
            running?.lastSeen = now
            save()
        }

        // 长时间没动电脑：先记下来，等你回来再问
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if awaySince == nil && idle >= Store.idleLimit {
            awaySince = now.addingTimeInterval(-idle)
        } else if let since = awaySince, idle < 5 {
            askAboutAway(since: since, back: now.addingTimeInterval(-idle))
            return
        }

        if r.pomodoro == true {
            if elapsed >= TimeInterval(focusMin * 60) { completePomodoro() }
            return
        }

        if elapsed >= Store.longSession && remindedBegin != r.begin {
            remindedBegin = r.begin
            notify("还在学吗？", "\(name(r.subjectID))已经连续计时 2 小时了，记得起来活动一下。")
        }
        checkGoal()
    }

    private func checkGoal() {
        guard goalNotifiedDay != today, total(for: today) >= goalSeconds else { return }
        goalNotifiedDay = today
        notify("🎉 今日目标完成", "今天已经学了 \(Fmt.short(total(for: today)))，连续 \(streak) 天达标！")
    }

    private func askAboutAway(since: Date, back: Date) {
        awaySince = nil
        let away = back.timeIntervalSince(since)
        guard away >= 60 else { return }
        asking = true
        let alert = NSAlert()
        alert.messageText = "你离开了 \(Int(away / 60)) 分钟"
        alert.informativeText = "\(Fmt.hm.string(from: since))–\(Fmt.hm.string(from: back)) 这段时间没有操作电脑。如果你在纸上做题或者看书，就算学习时间。"
        alert.addButton(withTitle: "算学习时间")
        alert.addButton(withTitle: "不算，扣掉")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if result == .alertSecondButtonReturn, var r = running {
            let n = Date()
            now = n
            let newElapsed = max(0, elapsed - away)
            r.accumulated = r.paused ? newElapsed : newElapsed - n.timeIntervalSince(r.start)
            running = r
            notice = "已扣掉离开的 \(Int(away / 60)) 分钟"
            save()
        }
        asking = false
    }

    private func pause(at moment: Date, reason: String) {
        guard var r = running, !r.paused else { return }
        r.accumulated += max(0, moment.timeIntervalSince(r.start))
        r.paused = true
        r.pausedAt = max(moment, r.start)
        running = r
        notice = reason
        awaySince = nil
        now = Date()
        save()
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: 查询

    var today: String { Fmt.day(now) }
    var goalSeconds: TimeInterval { TimeInterval(dailyGoalMin * 60) }

    func subject(_ id: UUID) -> Subject? { subjects.first { $0.id == id } }
    func color(_ id: UUID) -> Color { palette[(subject(id)?.colorIndex ?? 0) % palette.count] }
    func name(_ id: UUID) -> String { subject(id)?.name ?? "未知" }
    var visibleSubjects: [Subject] { subjects.filter { $0.hidden != true } }

    var elapsed: TimeInterval {
        guard let r = running else { return 0 }
        return r.accumulated + (r.paused ? 0 : now.timeIntervalSince(r.start))
    }

    var pomodoroRemaining: TimeInterval { TimeInterval(focusMin * 60) - elapsed }

    // MARK: 计时

    func start(_ subjectID: UUID, plan: UUID? = nil) {
        notice = nil
        breakEnd = nil
        if let r = running {
            if r.subjectID == subjectID && r.planID == plan {
                if r.paused { togglePause() }
                return
            }
            stop()
        }
        let n = Date()
        running = Running(subjectID: subjectID, planID: plan, begin: n, start: n,
                          pomodoro: pomodoroMode ? true : nil)
        lastSubjectID = subjectID
        lastPlanID = plan
        now = n
        save()
    }

    func startAgain() {
        guard let s = lastSubjectID, subject(s)?.hidden != true else { return }
        let p = plans.first { $0.id == lastPlanID && !$0.done }?.id
        start(s, plan: p)
    }

    func skipBreak() {
        breakEnd = nil
    }

    func togglePause() {
        guard var r = running else { return }
        let n = Date()
        if r.paused { r.start = n; r.paused = false; notice = nil }
        else { r.accumulated += n.timeIntervalSince(r.start); r.paused = true; r.pausedAt = n }
        running = r
        awaySince = nil
        now = n
        save()
    }

    func stop(completedPomodoro: Bool = false) {
        guard let r = running else { return }
        now = Date()
        let d = completedPomodoro ? TimeInterval(focusMin * 60) : elapsed
        if d >= 10 {   // 少于 10 秒不记录
            // 结束时间：暂停中结束就算到暂停那一刻，否则就是现在
            let end = r.paused ? (r.pausedAt ?? now) : now
            sessions.append(Session(subjectID: r.subjectID, planID: r.planID, begin: r.begin,
                                    end: max(end, r.begin.addingTimeInterval(d)), duration: d,
                                    pomodoro: completedPomodoro ? true : nil))
        }
        running = nil
        notice = nil
        awaySince = nil
        save()
        checkGoal()
    }

    private func completePomodoro() {
        stop(completedPomodoro: true)
        breakEnd = Date().addingTimeInterval(TimeInterval(breakMin * 60))
        notify("🍅 完成一个番茄", "休息 \(breakMin) 分钟吧，今天第 \(todayPomodoros) 个。")
    }

    // MARK: 设置

    func setPomodoroMode(_ on: Bool) { pomodoroMode = on; save() }
    func setFocusMin(_ m: Int) { focusMin = m; save() }
    func setBreakMin(_ m: Int) { breakMin = m; save() }
    func setDailyGoal(_ m: Int) {
        dailyGoalMin = m
        goalNotifiedDay = total(for: today) >= goalSeconds ? today : ""
        save()
    }

    // MARK: 科目

    func addSubject(_ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(10))
        guard !n.isEmpty else { return }
        if let i = subjects.firstIndex(where: { $0.name == n }) {
            subjects[i].hidden = nil   // 同名的旧科目直接恢复
        } else {
            subjects.append(Subject(name: n, colorIndex: subjects.count))
        }
        save()
    }

    func deleteSubject(_ id: UUID) {
        if running?.subjectID == id { stop() }
        if let i = subjects.firstIndex(where: { $0.id == id }) { subjects[i].hidden = true }
        save()
    }

    // MARK: 计划

    var todayPlans: [Plan] { plans.filter { $0.day == today } }

    // 之前没完成的计划挪到今天
    private func rollOverPlans() {
        let t = Fmt.day(Date())
        var changed = false
        for i in plans.indices where !plans[i].done && plans[i].day < t {
            plans[i].day = t
            changed = true
        }
        if changed { save() }
    }

    func addPlan(_ text: String, subject: UUID, minutes: Int) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        plans.append(Plan(day: today, text: t, subjectID: subject, targetMin: minutes))
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[i].done.toggle()
        if plans[i].done && running?.planID == id { stop() }
        save()
    }

    func deletePlan(_ id: UUID) {
        if running?.planID == id { running?.planID = nil }
        plans.removeAll { $0.id == id }
        save()
    }

    func setPlanTarget(_ id: UUID, minutes: Int) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[i].targetMin = minutes
        save()
    }

    func spent(on plan: Plan) -> TimeInterval {
        (planSpentCache[plan.id] ?? 0) + (running?.planID == plan.id ? elapsed : 0)
    }

    // MARK: 记录

    var todaySessions: [Session] {
        (daySessionsCache[today] ?? []).sorted { $0.begin > $1.begin }
    }

    var todayPomodoros: Int {
        (daySessionsCache[today] ?? []).filter { $0.pomodoro == true }.count
    }

    func addManualSession(subject: UUID, begin: Date, minutes: Int) {
        guard minutes > 0 else { return }
        let d = TimeInterval(minutes * 60)
        sessions.append(Session(subjectID: subject, planID: nil, begin: begin,
                                end: begin.addingTimeInterval(d), duration: d, manual: true))
        save()
        checkGoal()
    }

    func updateSession(_ id: UUID, minutes: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), minutes > 0 else { return }
        sessions[i].duration = TimeInterval(minutes * 60)
        sessions[i].end = sessions[i].begin.addingTimeInterval(sessions[i].duration)
        save()
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    // 复制成表格，可以直接粘贴到 Excel 或 Numbers
    func copyAllAsTable() {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["日期,开始,结束,科目,计划,分钟,类型"]
        for s in sessions.sorted(by: { $0.begin < $1.begin }) {
            let plan = plans.first { $0.id == s.planID }?.text ?? ""
            let kind = s.pomodoro == true ? "番茄" : (s.manual == true ? "补记" : "计时")
            lines.append([Fmt.day(s.begin), Fmt.hm.string(from: s.begin), Fmt.hm.string(from: s.end),
                          cell(name(s.subjectID)), cell(plan),
                          String(Int((s.duration / 60).rounded())), kind].joined(separator: ","))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        notice = "已复制 \(sessions.count) 条记录，可以粘贴到 Excel 或 Numbers"
    }

    // MARK: 统计

    func total(for day: String) -> TimeInterval {
        (dayTotalsCache[day]?.values.reduce(0, +) ?? 0) + (day == today ? elapsed : 0)
    }

    private func totals(for day: String) -> [(UUID, TimeInterval)] {
        var m = dayTotalsCache[day] ?? [:]
        if day == today, let r = running { m[r.subjectID, default: 0] += elapsed }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var todayTotals: [(UUID, TimeInterval)] { totals(for: today) }

    // 连续达标天数：今天还没达标的话，从昨天往前数
    var streak: Int {
        let cal = Calendar.current
        var d = now
        if total(for: Fmt.day(d)) < goalSeconds {
            d = cal.date(byAdding: .day, value: -1, to: d) ?? d
        }
        var n = 0
        while n < 3650, total(for: Fmt.day(d)) >= goalSeconds {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d) ?? d
        }
        return n
    }

    var week: [DayStat] {
        let cal = Calendar.current
        let names = Array("日一二三四五六")
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: now) ?? now
            let parts = totals(for: Fmt.day(d))
            let label = i == 6 ? "今天" : String(names[cal.component(.weekday, from: d) - 1])
            return DayStat(id: i, label: label, parts: parts, total: parts.reduce(0) { $0 + $1.1 })
        }
    }
}

// MARK: - App 入口

@main
struct StudyBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            if let be = store.breakEnd {
                Text("☕ 休息 \(Fmt.mmss(be.timeIntervalSince(store.now)))").monospacedDigit()
            } else if let r = store.running {
                if r.pomodoro == true {
                    Text("\(r.paused ? "⏸" : "🍅") \(store.name(r.subjectID)) \(Fmt.mmss(store.pomodoroRemaining))")
                        .monospacedDigit()
                } else {
                    Text("\(r.paused ? "⏸" : "📖") \(store.name(r.subjectID)) \(Fmt.clock(store.elapsed))")
                        .monospacedDigit()
                }
            } else {
                // 用书本图标，避免和系统的计时器图标搞混
                Image(systemName: "book.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 界面

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showMore = false
    @State private var newSubject = ""
    @State private var addingSubject = false
    @State private var planText = ""
    @State private var planSubject: UUID?
    @State private var editingSession: UUID?
    @State private var editMinutes = ""
    @State private var addingManual = false
    @State private var manualSubject: UUID?
    @State private var manualStart = Date()
    @State private var manualMinutes = "60"
    @State private var contentHeight: CGFloat = 300

    // 面板最高不超过屏幕高度减去菜单栏和计时区
    private var maxScrollHeight: CGFloat {
        max(260, (NSScreen.main?.visibleFrame.height ?? 800) - 240)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            timerSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showMore { morePage } else { mainPage }
                }
                .padding(.trailing, 4)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(contentHeight, maxScrollHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        }
        .padding(16)
        .frame(width: 320)
    }

    // 只在没被删的科目里选；之前选的被删了就退回第一个
    private func pick(_ id: UUID?) -> UUID? {
        if let id, store.visibleSubjects.contains(where: { $0.id == id }) { return id }
        return store.visibleSubjects.first?.id
    }

    private func subjectPicker(_ selection: Binding<UUID?>) -> some View {
        Picker("", selection: Binding(get: { pick(selection.wrappedValue) }, set: { selection.wrappedValue = $0 })) {
            ForEach(store.visibleSubjects) { s in Text(s.name).tag(Optional(s.id)) }
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - 计时区（两页都显示）

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let be = store.breakEnd {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("☕ 休息一下").font(.callout).foregroundStyle(.secondary)
                        bigClock(Fmt.mmss(be.timeIntervalSince(store.now)), color: palette[2])
                    }
                    Spacer()
                    Button("跳过") { store.skipBreak() }
                    Button("再来一个") { store.startAgain() }.buttonStyle(.borderedProminent)
                }
            } else if let r = store.running {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(store.color(r.subjectID)).frame(width: 8, height: 8)
                            Text(currentTitle(r)).lineLimit(1)
                            if r.paused { Text("已暂停").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                        bigClock(r.pomodoro == true ? Fmt.mmss(store.pomodoroRemaining) : Fmt.clock(store.elapsed),
                                 color: r.paused ? Color.primary : palette[0])
                    }
                    Spacer()
                    Button(r.paused ? "继续" : "暂停") { store.togglePause() }
                    Button("结束") { store.stop() }.tint(palette[0]).buttonStyle(.borderedProminent)
                }
            } else {
                Text(store.pomodoroMode ? "🍅 点一个科目，开始 \(store.focusMin) 分钟番茄" : "点一个科目开始计时")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let n = store.notice {
                Text(n)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func currentTitle(_ r: Running) -> String {
        if let p = store.plans.first(where: { $0.id == r.planID }) { return p.text }
        return store.name(r.subjectID)
    }

    private func bigClock(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    // MARK: - 主页：科目、计划、一行今日进度

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            subjectGrid
            planSection
            summaryRow
        }
    }

    private var subjectGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(store.visibleSubjects) { s in
                    let active = store.running?.subjectID == s.id && store.running?.planID == nil
                    Button { store.start(s.id) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(palette[s.colorIndex % palette.count]).frame(width: 8, height: 8)
                            Text(s.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? palette[s.colorIndex % palette.count] : nil)
                    .contextMenu { Button("删除科目…", role: .destructive) { confirmDelete(s) } }
                }
                Button { addingSubject.toggle() } label: {
                    Image(systemName: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .help("新科目")
            }
            if addingSubject {
                TextField("新科目名称，回车添加", text: $newSubject)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.addSubject(newSubject)
                        newSubject = ""
                        addingSubject = false
                    }
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let plans = store.todayPlans
            Text("今日计划").font(.headline)
            ForEach(plans) { p in planRow(p) }
            HStack(spacing: 6) {
                TextField("＋ 添加计划，回车确认", text: $planText)
                    .textFieldStyle(.plain)
                    .onSubmit(addPlan)
                subjectPicker($planSubject)
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }

    private func addPlan() {
        guard let sid = pick(planSubject) else { return }
        store.addPlan(planText, subject: sid, minutes: 30)
        planText = ""
    }

    private func planRow(_ p: Plan) -> some View {
        let spent = store.spent(on: p)
        let isRunning = store.running?.planID == p.id
        let reached = spent >= Double(p.targetMin * 60)
        return HStack(spacing: 8) {
            Button { store.toggleDone(p.id) } label: {
                Image(systemName: p.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(p.done ? palette[2] : Color.secondary)
            }
            .buttonStyle(.borderless)
            Text(p.text)
                .strikethrough(p.done)
                .foregroundStyle(p.done ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Text("\(Int(spent / 60))/\(p.targetMin)分")
                .font(.caption.monospacedDigit())
                .foregroundStyle(reached ? palette[2] : Color.secondary)
            if !p.done {
                Button {
                    if isRunning { store.togglePause() } else { store.start(p.subjectID, plan: p.id) }
                } label: {
                    Image(systemName: isRunning && store.running?.paused == false ? "pause.fill" : "play.fill")
                        .foregroundStyle(store.color(p.subjectID))
                }
                .buttonStyle(.borderless)
            }
        }
        .contextMenu {
            Menu("目标时长") {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button("\(m) 分钟") { store.setPlanTarget(p.id, minutes: m) }
                }
            }
            Button("删除计划", role: .destructive) { store.deletePlan(p.id) }
        }
    }

    private var summaryRow: some View {
        let todayTotal = store.total(for: store.today)
        let goal = store.goalSeconds
        let done = todayTotal >= goal
        let streak = store.streak
        return Button { showMore = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("今天 \(Fmt.short(todayTotal)) / \(Fmt.short(goal))")
                        .fontWeight(.medium)
                        .foregroundStyle(done ? palette[2] : Color.primary)
                    if streak > 0 { Text("🔥\(streak)天") }
                    if store.todayPomodoros > 0 { Text("🍅\(store.todayPomodoros)") }
                    Spacer()
                    Text("统计与设置 ›").foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, todayTotal / max(goal, 1)))
                    .tint(done ? palette[2] : palette[0])
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 更多页：统计、记录、设置

    private var morePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { showMore = false } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            todayBreakdown
            weekSection
            recordSection
            settingsSection

            HStack {
                Button("复制全部记录") { store.copyAllAsTable() }
                Spacer()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var todayBreakdown: some View {
        let totals = store.todayTotals
        let maxV = max(totals.first?.1 ?? 1, 1)
        let streak = store.streak
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天").font(.headline)
                Spacer()
                Text(streak > 0 ? "🔥 连续 \(streak) 天达标" : "今天达标就开始连续打卡")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if totals.isEmpty {
                Text("还没有记录").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(totals, id: \.0) { item in
                let (id, v) = item
                HStack(spacing: 8) {
                    Text(store.name(id)).font(.caption).frame(width: 44, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(store.color(id)).frame(width: max(4, g.size.width * v / maxV))
                    }
                    .frame(height: 8)
                    Text(Fmt.short(v)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var weekSection: some View {
        let week = store.week
        let goal = store.goalSeconds
        let maxT = max(week.map(\.total).max() ?? 0, goal, 3600)
        let barH: CGFloat = 70
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近 7 天").font(.headline)
                Spacer()
                Text("共 \(Fmt.short(week.reduce(0) { $0 + $1.total }))").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(week) { d in
                    VStack(spacing: 3) {
                        Text(d.total > 0 ? Fmt.short(d.total) : " ")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        VStack(spacing: 0) {
                            ForEach(Array(d.parts.enumerated()), id: \.offset) { item in
                                Rectangle()
                                    .fill(store.color(item.element.0))
                                    .frame(height: barH * CGFloat(item.element.1 / maxT))
                            }
                        }
                        .frame(width: 20)
                        .frame(minHeight: 3)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(d.total >= goal ? "✓" : d.label)
                            .font(.caption2)
                            .fontWeight(d.id == 6 ? .semibold : .regular)
                            .foregroundStyle(d.total >= goal ? palette[2] : (d.id == 6 ? Color.primary : Color.secondary))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var recordSection: some View {
        let sessions = store.todaySessions
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日记录").font(.headline)
                Spacer()
                Button {
                    if !addingManual {
                        manualStart = Date().addingTimeInterval(-3600)
                        manualMinutes = "60"
                    }
                    addingManual.toggle()
                } label: { Label("补记录", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if addingManual { manualForm }
            if sessions.isEmpty {
                Text("还没有记录").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { s in sessionRow(s) }
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                subjectPicker($manualSubject)
                TextField("分钟", text: $manualMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("分钟")
                Spacer()
            }
            DatePicker("开始于", selection: $manualStart, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            HStack {
                Spacer()
                Button("取消") { addingManual = false }.buttonStyle(.borderless)
                Button("添加") {
                    if let sid = pick(manualSubject),
                       let m = Int(manualMinutes.trimmingCharacters(in: .whitespaces)) {
                        store.addManualSession(subject: sid, begin: manualStart, minutes: m)
                    }
                    addingManual = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption)
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sessionRow(_ s: Session) -> some View {
        HStack {
            Circle().fill(store.color(s.subjectID)).frame(width: 6, height: 6)
            Text(store.name(s.subjectID))
            if s.pomodoro == true { Text("🍅") }
            if s.manual == true { Text("补").foregroundStyle(.secondary) }
            Spacer()
            if editingSession == s.id {
                TextField("分钟", text: $editMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .onSubmit { commitEdit(s.id) }
                Text("分钟")
                Button("保存") { commitEdit(s.id) }.buttonStyle(.borderless)
            } else {
                Text("\(Fmt.hm.string(from: s.begin))–\(Fmt.hm.string(from: s.end)) · \(Fmt.short(s.duration))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.caption)
        .contextMenu {
            Button("修改时长") {
                editMinutes = String(Int((s.duration / 60).rounded()))
                editingSession = s.id
            }
            Button("删除这条", role: .destructive) { store.deleteSession(s.id) }
        }
    }

    private func commitEdit(_ id: UUID) {
        if let m = Int(editMinutes.trimmingCharacters(in: .whitespaces)) {
            store.updateSession(id, minutes: m)
        }
        editingSession = nil
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设置").font(.headline)
            Stepper("每日目标 \(Fmt.short(store.goalSeconds))",
                    value: Binding(get: { store.dailyGoalMin }, set: { store.setDailyGoal($0) }),
                    in: 30...720, step: 30)
            Toggle("番茄钟模式", isOn: Binding(get: { store.pomodoroMode }, set: { store.setPomodoroMode($0) }))
                .disabled(store.running != nil)
            if store.pomodoroMode {
                Stepper("专注 \(store.focusMin) 分钟", value: Binding(get: { store.focusMin }, set: { store.setFocusMin($0) }), in: 5...90, step: 5)
                Stepper("休息 \(store.breakMin) 分钟", value: Binding(get: { store.breakMin }, set: { store.setBreakMin($0) }), in: 1...30)
            }
            Text("小提示：右键科目可以删除；右键计划可以改目标时长；右键记录可以修改或删除。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func confirmDelete(_ s: Subject) {
        let alert = NSAlert()
        alert.messageText = "删除「\(s.name)」？"
        alert.informativeText = "以前的学习记录会保留，统计里照常显示。以后再新建同名科目，会恢复成原来那个。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.deleteSubject(s.id) }
    }
}
