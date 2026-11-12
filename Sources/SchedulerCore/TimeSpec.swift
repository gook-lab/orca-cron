import Foundation

/// 편집 화면의 「시각」 — 어느 요일에, 정한 시각마다 또는 구간 안에서 N분마다. cron 식과 오간다.
///
/// 정한 시각은 시를 쉼표로만 잇고(`0 9,18 * * *`), 반복은 범위·걸음(`*/5 7 * * *; 0 8 * * *`)으로 쓴다.
/// 다시 열 때 분·시 칸에 `*`·`/`·`-` 가 있으면 반복으로, 없으면 정한 시각으로 읽는다 — 같은 시각 묶음이라도 고른 방식대로 다시 열린다.
public struct TimeSpec: Equatable, Sendable {
    public enum Days: Equatable, Sendable {
        case everyDay
        case weekdays
        /// 0=일 … 6=토.
        case some(Set<Int>)

        /// 모든 요일이면 매일, 월~금이면 평일로 정리한다.
        public static func of(_ set: Set<Int>) -> Days {
            if set == Set(0...6) { return .everyDay }
            if set == Set(1...5) { return .weekdays }
            return .some(set)
        }

        var field: String? {
            switch self {
            case .everyDay: return "*"
            case .weekdays: return "1-5"
            case .some(let s): return s.isEmpty ? nil : s.sorted().map(String.init).joined(separator: ",")
            }
        }

        var text: String {
            switch self {
            case .everyDay: return "매일"
            case .weekdays: return "평일"
            case .some(let s):
                let names = ["일", "월", "화", "수", "목", "금", "토"]
                return "매주 " + s.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { names[$0] }.joined(separator: "·")
            }
        }
    }

    public enum Pattern: Equatable, Sendable {
        /// 하루 중 분(0…1439).
        case times([Int])
        /// from 부터 to 까지(둘 다 포함) n 분마다. 하루 중 분(0…1439).
        case every(Int, from: Int, to: Int)
    }

    public var days: Days
    public var pattern: Pattern

    /// 정한 시각으로 읽을 수 있는 최대 개수 — 넘으면 「cron 직접」으로 연다.
    public static let maxTimes = 24
    /// 반복 간격 상한(분).
    public static let maxEvery = 720

    public init(days: Days, pattern: Pattern) {
        self.days = days
        self.pattern = pattern
    }

    /// 흔한 모양의 cron 이면 그 값. 날짜(일·월)를 제한하거나 식마다 요일이 다르면 nil.
    public init?(cron: String) {
        guard let c = Cron(cron) else { return nil }
        let weekdays: Set<Int> = c.rules[0].weekdays
        var set = Set<Int>()
        var stepped = false
        for r in c.rules {
            let everyDate: Bool = r.days.count == 31 && r.months.count == 12
            guard everyDate, r.weekdays == weekdays else { return nil }
            for h in r.hours { for m in r.minutes { set.insert(h * 60 + m) } }
            let fields: String = r.part(0) + " " + r.part(1)
            if fields.contains(where: { "*/-".contains($0) }) { stepped = true }
        }
        let list = set.sorted()
        let days = Days.of(weekdays)
        if stepped, list.count >= 3, let step = TimeSpec.step(list), step <= TimeSpec.maxEvery {
            // 하루 끝까지 이어지면 끝을 23:59 로 둔다 — 「종일」·「매시」로 다시 열린다.
            let last = list[list.count - 1]
            self.init(days: days, pattern: .every(step, from: list[0], to: last + step >= 1440 ? 1439 : last))
            return
        }
        guard list.count <= TimeSpec.maxTimes else { return nil }
        self.init(days: days, pattern: .times(list))
    }

    /// 저장할 cron 식. 시각·요일이 비었거나, 간격이 범위 밖이거나, 구간이 거꾸로면 nil.
    public var cron: String? {
        guard let dow = days.field else { return nil }
        switch pattern {
        case .times(let list):
            let ms = Set(list).filter { (0..<1440).contains($0) }
            guard !ms.isEmpty else { return nil }
            var byMinute: [Int: [Int]] = [:]
            for t in ms { byMinute[t % 60, default: []].append(t / 60) }
            return byMinute.map { (m: $0.key, hours: $0.value.sorted()) }
                .sorted { ($0.hours[0], $0.m) < ($1.hours[0], $1.m) }
                .map { "\($0.m) \($0.hours.map(String.init).joined(separator: ",")) * * \(dow)" }
                .joined(separator: "; ")
        case .every(let n, let from, let to):
            guard (1...TimeSpec.maxEvery).contains(n), from >= 0, from <= to, to < 1440 else { return nil }
            var minutesByHour: [Int: [Int]] = [:]
            for t in stride(from: from, through: to, by: n) { minutesByHour[t / 60, default: []].append(t % 60) }
            // 분 목록이 같은 시끼리 한 식에 모은다(5분마다 07:00~08:00 → `*/5 7`, `0 8`).
            var hoursByMinutes: [[Int]: [Int]] = [:]
            for (h, ms) in minutesByHour { hoursByMinutes[ms, default: []].append(h) }
            return hoursByMinutes.map { (ms: $0.key, hours: $0.value.sorted()) }
                .sorted { $0.hours[0] < $1.hours[0] }
                .map { "\(TimeSpec.compress($0.ms, max: 59)) \(TimeSpec.compress($0.hours, max: 23)) * * \(dow)" }
                .joined(separator: "; ")
        }
    }

    /// 하루에 도는 횟수.
    public var runsPerDay: Int {
        switch pattern {
        case .times(let list): return Set(list).count
        case .every(let n, let from, let to): return n > 0 && from <= to ? (to - from) / n + 1 : 0
        }
    }

    public var summary: String {
        let pad = CronRule.pad
        func clock(_ t: Int) -> String { "\(pad(t / 60)):\(pad(t % 60))" }
        switch pattern {
        case .times(let list):
            let ts = Set(list).sorted()
            let sameMinute = Set(ts.map { $0 % 60 }).count == 1
            let text = sameMinute && ts.count >= 4
                ? ts.map { pad($0 / 60) }.joined(separator: "·") + "시 \(pad(ts[0] % 60))분"
                : ts.map(clock).joined(separator: " · ")
            return "\(days.text) \(text)"
        case .every(let n, let from, let to):
            let wholeDay = to + n >= 1440
            if n == 60, from < 60, wholeDay {
                return (days == .everyDay ? "" : days.text + " ") + "매시 \(pad(from))분"
            }
            let interval = n < 60 ? "\(n)분마다" : n % 60 == 0 ? "\(n / 60)시간마다" : "\(n / 60)시간 \(n % 60)분마다"
            if from == 0, wholeDay {
                return days == .everyDay ? interval : "\(days.text) \(interval)"
            }
            return "\(days.text) \(clock(from))~\(clock(to)) \(interval)"
        }
    }

    /// 같은 간격으로 늘어선 목록이면 그 간격.
    static func step(_ list: [Int]) -> Int? {
        guard list.count > 1 else { return nil }
        let s = list[1] - list[0]
        return zip(list, list.dropFirst()).allSatisfy { $1 - $0 == s } ? s : nil
    }

    /// 오름차순 목록 → cron 칸. 같은 간격이면 `*`·`a-b`·`*/s`·`a-b/s`, 아니면 쉼표 목록.
    static func compress(_ list: [Int], max: Int) -> String {
        guard list.count > 1, let s = step(list) else { return list.map(String.init).joined(separator: ",") }
        let a = list[0], b = list[list.count - 1]
        if s == 1 { return a == 0 && b == max ? "*" : "\(a)-\(b)" }
        if b + s > max { return a == 0 ? "*/\(s)" : "\(a)-\(max)/\(s)" }
        return "\(a)-\(b)/\(s)"
    }
}
