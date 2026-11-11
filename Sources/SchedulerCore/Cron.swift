import Foundation

/// 5칸 cron 하나 이상을 `;` 로 이은 식. 가장 먼저 오는 시각에 돈다.
/// 하루 여러 번을 분이 다른 시각으로 정할 때 쓴다(예: `30 9 * * *; 0 18 * * *`).
public struct Cron: Equatable, Sendable {
    public let expression: String
    let rules: [CronRule]

    public init?(_ expression: String) {
        let pieces = expression.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        var rules: [CronRule] = []
        for piece in pieces {
            guard let r = CronRule(piece) else { return nil }
            rules.append(r)
        }
        self.rules = rules
        self.expression = rules.map(\.expression).joined(separator: "; ")
    }

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        rules.compactMap { $0.next(after: date, calendar: calendar) }.min()
    }

    /// 같은 요일 칸의 「분 시 * * 요일」 식들이면 시각을 모아 한 줄로 쓴다.
    public var summary: String {
        guard rules.count > 1 else { return rules[0].summary }
        let dow = rules[0].part(4)
        if rules.allSatisfy({ $0.isDailyTimes && $0.part(4) == dow }) {
            let times = rules.flatMap { r in r.hours.map { (h: $0, m: r.minutes[0]) } }
                .sorted { ($0.h, $0.m) < ($1.h, $1.m) }
            return rules[0].dayPart + " " + times.map { "\(CronRule.pad($0.h)):\(CronRule.pad($0.m))" }.joined(separator: " · ")
        }
        return rules.map(\.summary).joined(separator: " / ")
    }
}

/// 5칸 cron(분 시 일 월 요일), 이 맥의 현지 시각 기준.
/// 일·요일 칸이 둘 다 `*` 로 시작하지 않으면 둘 중 하나만 맞아도 된다(Vixie cron 과 같음). 요일 7 은 일요일(0).
struct CronRule: Equatable, Sendable {
    let expression: String
    let minutes: [Int]
    let hours: [Int]
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool

    init?(_ expression: String) {
        let parts = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5,
              let mi = CronRule.field(parts[0], 0, 59),
              let h = CronRule.field(parts[1], 0, 23),
              let d = CronRule.field(parts[2], 1, 31),
              let mo = CronRule.field(parts[3], 1, 12),
              var w = CronRule.field(parts[4], 0, 7)
        else { return nil }
        if w.contains(7) { w.remove(7); w.insert(0) }
        self.expression = parts.joined(separator: " ")
        minutes = mi.sorted()
        hours = h.sorted()
        days = d
        months = mo
        weekdays = w
        dayRestricted = !parts[2].hasPrefix("*")
        weekdayRestricted = !parts[4].hasPrefix("*")
    }

    static func field(_ text: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
        var out = Set<Int>()
        for item in text.split(separator: ",") {
            var range = Substring(item)
            var step = 1
            if let slash = item.firstIndex(of: "/") {
                guard let s = Int(item[item.index(after: slash)...]), s > 0 else { return nil }
                step = s
                range = item[..<slash]
            }
            var a = lo, b = hi
            if range == "*" {
                // 전체 범위
            } else if let dash = range.firstIndex(of: "-") {
                guard let x = Int(range[..<dash]), let y = Int(range[range.index(after: dash)...]) else { return nil }
                a = x; b = y
            } else {
                guard let x = Int(range) else { return nil }
                a = x
                b = step > 1 ? hi : x  // "5/15" = 5 부터 15 씩
            }
            guard a >= lo, b <= hi, a <= b else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// `date` 보다 뒤(같은 분 제외)의 첫 실행 시각.
    func next(after date: Date, calendar: Calendar) -> Date? {
        let floor = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let start = floor.addingTimeInterval(60)
        let firstDay = calendar.startOfDay(for: start)
        for offset in 0..<400 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let c = calendar.dateComponents([.month, .day, .weekday], from: day)
            guard let month = c.month, let dom = c.day, let wd = c.weekday, months.contains(month) else { continue }
            let w = wd - 1  // Calendar: 1=일요일 → cron 0
            let dayOK: Bool
            if dayRestricted && weekdayRestricted {
                dayOK = days.contains(dom) || weekdays.contains(w)
            } else {
                dayOK = days.contains(dom) && weekdays.contains(w)
            }
            guard dayOK else { continue }
            for h in hours {
                for m in minutes {
                    guard let t = calendar.date(bySettingHour: h, minute: m, second: 0, of: day) else { continue }
                    if t >= start { return t }
                }
            }
        }
        return nil
    }

    func part(_ i: Int) -> String { String(expression.split(separator: " ")[i]) }

    /// 「분 시 * * 요일」에 분이 하나 — 하루 몇 시 몇 분 꼴.
    var isDailyTimes: Bool { minutes.count == 1 && !part(1).hasPrefix("*") && part(2) == "*" && part(3) == "*" }

    static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    var dayPart: String {
        if part(4) == "*" { return "매일" }
        if weekdays == [1, 2, 3, 4, 5] { return "평일" }
        let names = ["일", "월", "화", "수", "목", "금", "토"]
        return "매주 " + weekdays.sorted().map { names[$0] }.joined(separator: "·")
    }

    /// 사람이 읽는 한 줄. 흔한 모양만 풀고 나머지는 식 그대로.
    var summary: String {
        let p = expression.split(separator: " ").map(String.init)
        let pad = CronRule.pad
        if p[2] == "*" && p[3] == "*" && p[4] == "*" && p[1] == "*" {
            if p[0].hasPrefix("*/") { return "\(p[0].dropFirst(2))분마다" }
            if minutes.count == 1 { return "매시 \(pad(minutes[0]))분" }
        }
        guard isDailyTimes else { return expression }
        let m = minutes[0]
        let times = hours.count <= 3
            ? hours.map { "\(pad($0)):\(pad(m))" }.joined(separator: " · ")
            : hours.map(pad).joined(separator: "·") + "시 \(pad(m))분"
        return "\(dayPart) \(times)"
    }
}
