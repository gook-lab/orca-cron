import Foundation

/// 5칸 cron(분 시 일 월 요일), 이 맥의 현지 시각 기준.
/// 일·요일 칸이 둘 다 `*` 로 시작하지 않으면 둘 중 하나만 맞아도 된다(Vixie cron 과 같음). 요일 7 은 일요일(0).
public struct Cron: Equatable, Sendable {
    public let expression: String
    let minutes: [Int]
    let hours: [Int]
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool

    public init?(_ expression: String) {
        let parts = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5,
              let mi = Cron.field(parts[0], 0, 59),
              let h = Cron.field(parts[1], 0, 23),
              let d = Cron.field(parts[2], 1, 31),
              let mo = Cron.field(parts[3], 1, 12),
              var w = Cron.field(parts[4], 0, 7)
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
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
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

    /// 사람이 읽는 한 줄. 흔한 모양만 풀고 나머지는 식 그대로.
    public var summary: String {
        let p = expression.split(separator: " ").map(String.init)
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if p[2] == "*" && p[3] == "*" && p[4] == "*" && p[1] == "*" {
            if p[0].hasPrefix("*/") { return "\(p[0].dropFirst(2))분마다" }
            if minutes.count == 1 { return "매시 \(pad(minutes[0]))분" }
        }
        guard minutes.count == 1, !p[1].hasPrefix("*"), p[2] == "*", p[3] == "*" else { return expression }
        let m = minutes[0]
        let times = hours.count <= 3
            ? hours.map { "\(pad($0)):\(pad(m))" }.joined(separator: " · ")
            : hours.map(pad).joined(separator: "·") + "시 \(pad(m))분"
        let dayPart: String
        if p[4] == "*" {
            dayPart = "매일"
        } else if weekdays == [1, 2, 3, 4, 5] {
            dayPart = "평일"
        } else {
            let names = ["일", "월", "화", "수", "목", "금", "토"]
            dayPart = "매주 " + weekdays.sorted().map { names[$0] }.joined(separator: "·")
        }
        return "\(dayPart) \(times)"
    }
}
