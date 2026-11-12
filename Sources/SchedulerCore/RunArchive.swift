import Foundation

/// 예약마다 실행 기록을 history/<id>.jsonl 에 한 줄씩 쌓는다(오래된 것이 위).
/// schedules.json 에는 최근 10개만 두고(30초마다 다시 쓰는 파일이라), 날짜별로 보는 기록은 여기서 읽는다.
public enum RunArchive {
    /// 이보다 오래된 기록은 지운다.
    public static let keepDays = 30

    static func file(_ id: String, _ paths: Paths) -> URL {
        paths.history.appendingPathComponent("\(id).jsonl")
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// 틱 전(old)에 없던 새 기록 — 오래된 것부터.
    public static func added(old: Schedule?, new: Schedule) -> [RunRecord] {
        let fresh = new.history.prefix { r in old?.history.first.map { r.at > $0.at } ?? true }
        return fresh.reversed()
    }

    /// 틱 전후를 비교해 새 기록을 덧붙인다. 파일이 아직 없으면 지금 가진 최근 기록 전부로 시작한다. 1회 보내기는 쌓지 않는다.
    public static func record(old: StoreFile, new: StoreFile, _ paths: Paths, now: Date) {
        for s in new.schedules where !s.isOneShot {
            let fresh = added(old: old.schedules.first { $0.id == s.id }, new: s)
            guard !fresh.isEmpty else { continue }
            let url = file(s.id, paths)
            if FileManager.default.fileExists(atPath: url.path) {
                append(fresh, url)
                prune(url, now: now)
            } else {
                write(Array(s.history.reversed()), url)
            }
        }
    }

    /// 날짜별로 보기 위한 전체 기록 — 새것이 위. 파일이 없으면 fallback(schedules.json 의 최근 기록).
    public static func load(_ id: String, fallback: [RunRecord], _ paths: Paths) -> [RunRecord] {
        guard let text = try? String(contentsOf: file(id, paths), encoding: .utf8) else { return fallback }
        let d = Store.decoder()
        let all = text.split(separator: "\n").compactMap { try? d.decode(RunRecord.self, from: Data($0.utf8)) }
        return all.isEmpty ? fallback : all.reversed()
    }

    /// 지운 예약의 기록 — 되돌리기 시간이 지나도록(하루) 그 id 의 예약이 없으면 지운다.
    public static func removeOrphans(keeping ids: Set<String>, _ paths: Paths, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.history, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "jsonl" && !ids.contains(url.deletingPathExtension().lastPathComponent) {
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(changed) > 86400 { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func lines(_ records: [RunRecord]) -> Data {
        let e = encoder()
        return Data(records.compactMap { r in (try? e.encode(r)).map { $0 + Data("\n".utf8) } }.joined())
    }

    static func write(_ records: [RunRecord], _ url: URL) {
        try? lines(records).write(to: url, options: .atomic)
    }

    static func append(_ records: [RunRecord], _ url: URL) {
        guard let h = try? FileHandle(forWritingTo: url) else { return write(records, url) }
        h.seekToEndOfFile()
        h.write(lines(records))
        try? h.close()
    }

    /// 맨 윗줄이 보관 기간보다 하루 넘게 오래됐으면 보관 기간 안의 것만 남긴다(하루에 한 번꼴로 다시 쓴다).
    static func prune(_ url: URL, now: Date) {
        let limit = now.addingTimeInterval(-Double(keepDays) * 86400)
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        let head = h.readData(ofLength: 4096)
        try? h.close()
        guard let line = head.split(separator: UInt8(ascii: "\n")).first,
              let first = try? Store.decoder().decode(RunRecord.self, from: Data(line)),
              first.at < limit.addingTimeInterval(-86400) else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let d = Store.decoder()
        let kept = text.split(separator: "\n").compactMap { try? d.decode(RunRecord.self, from: Data($0.utf8)) }.filter { $0.at >= limit }
        write(kept, url)
    }

    /// 하루치 기록을 한 쪽에 perPage 개씩.
    public static let perPage = 10

    /// 기록이 있는 날(그날 0시) — 새 날이 위.
    public static func days(_ records: [RunRecord], calendar: Calendar = .current) -> [Date] {
        var seen = Set<Date>()
        return records.map { calendar.startOfDay(for: $0.at) }.filter { seen.insert($0).inserted }.sorted(by: >)
    }

    /// 그날의 page 쪽(0부터) 기록과 그날 전체 개수.
    public static func page(_ records: [RunRecord], day: Date, page: Int, calendar: Calendar = .current) -> (items: [RunRecord], total: Int) {
        let ofDay = records.filter { calendar.isDate($0.at, inSameDayAs: day) }
        let start = max(0, page) * perPage
        guard start < ofDay.count else { return ([], ofDay.count) }
        return (Array(ofDay[start..<min(start + perPage, ofDay.count)]), ofDay.count)
    }
}
