import Foundation

public enum Health {
    /// 최근 24시간에 「입력 칸이 보이지 않음」으로 건너뛴 실행이 두 번 이상이면 알린다.
    /// 질문 창이 오래 떠 있었을 수도 있지만, 에이전트가 화면 모양을 바꿔 입력 칸을 못 찾는 경우를 놓치지 않으려는 것이다.
    public static func screenWarning(_ store: StoreFile, now: Date) -> String? {
        let hits = store.schedules.flatMap(\.history).filter {
            $0.status == "건너뜀" && ($0.summary ?? "").contains("입력 칸이 보이지 않음") && now.timeIntervalSince($0.at) < 86400
        }
        guard hits.count >= 2 else { return nil }
        return "최근 24시간에 「입력 칸이 보이지 않음」으로 \(hits.count)번 건너뜀 — 질문 창이 오래 떠 있었거나 에이전트(Claude Code·Codex·Gemini) 화면 모양이 바뀌었을 수 있습니다. ⋯ → 「화면 진단 저장」으로 확인해 주세요."
    }
}
