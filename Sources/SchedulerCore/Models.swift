import Foundation

public struct TerminalRef: Codable, Equatable, Sendable {
    public var handle: String
    /// 고를 때의 터미널 이름. 터미널 제목은 대화 주제에 따라 바뀌므로 화면에는 지금 제목을 따로 보여 준다.
    public var label: String
    /// Orca 탭·패인 id. Orca 를 다시 켜면 handle 은 바뀌지만 이 둘은 남아 같은 터미널을 다시 찾는다.
    public var tabId: String?
    public var leafId: String?
    /// 고를 때 그 터미널에 떠 있던 에이전트(Orca agentIdentity). 터미널이 사라져도 아이콘을 보여 주려고 남긴다.
    public var agent: String?

    public init(handle: String, label: String, tabId: String? = nil, leafId: String? = nil, agent: String? = nil) {
        self.handle = handle
        self.label = label
        self.tabId = tabId
        self.leafId = leafId
        self.agent = agent
    }

    public var kind: AgentKind? { AgentKind(identity: agent) }
}

public struct RunRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var status: String
    public var summary: String?
    public var link: String?

    public init(at: Date, status: String, summary: String? = nil, link: String? = nil) {
        self.at = at
        self.status = status
        self.summary = summary
        self.link = link
    }
}

public struct Schedule: Codable, Equatable, Identifiable, Sendable {
    // 사용자가 정하는 칸
    public var id: String
    public var name: String
    public var terminal: TerminalRef
    public var cron: String
    public var enabled: Bool
    /// 작업 파일 키(tasks/<키>.md). 없으면 prompt 를 그대로 보낸다.
    public var task: String?
    public var prompt: String?
    public var runNowRequestedAt: Date?
    /// 시각 없이 한 번만 보내는 메시지(메뉴의 「보내기」). 보낸 뒤 24시간이 지나면 목록에서 지운다.
    public var oneShot: Bool?
    /// 끝나면 결과 명령을 부르게 할지. 정해 두지 않으면 예약은 받고, 1회 보내기는 받지 않는다.
    public var track: Bool?
    /// 예정 시각보다 이만큼(초) 넘게 늦으면 보내지 않고 건너뛴다(맥 잠자기·앱 꺼짐). 없으면 늦어도 보낸다.
    public var lateLimit: Double?
    /// 보내기 전에 `/clear` 를 먼저 보내 새 대화로 시작한다(예약 전용 터미널용).
    public var clearFirst: Bool?

    // 실행기가 채우는 칸
    public var nextRunAt: Date?
    /// nextRunAt 을 어느 cron 으로 계산했는지. cron 을 고치면 다시 계산한다.
    public var nextRunFor: String?
    public var runNowHandledAt: Date?
    public var pendingSince: Date?
    public var pendingReason: String?
    public var waitNote: String?
    /// 보낸 뒤 결과를 기다리는 동안 터미널이 멈춰 보이는 이유(권한 창 등). 결과가 오면 지운다.
    public var blocked: String?
    /// 이번 대기(pendingSince)에 이미 /clear 를 보냈는지.
    public var clearedFor: Date?
    public var runId: String?
    public var sentAt: Date?
    public var lastRunAt: Date?
    public var lastStatus: String?
    public var lastSummary: String?
    public var lastLink: String?
    public var history: [RunRecord]

    public static let historyLimit = 10

    public var isOneShot: Bool { oneShot == true }
    /// 직접 입력이 `/` 로 시작하면 Claude 명령으로 보고 글 그대로 보낸다 — 같은 줄에 결과 명령을 붙일 수 없어 결과를 받지 않는다.
    public var isCommand: Bool { task == nil && (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }
    public var tracksResult: Bool { !isCommand && (track ?? !isOneShot) }

    public init(id: String, name: String, terminal: TerminalRef, cron: String, enabled: Bool = true,
                task: String? = nil, prompt: String? = nil) {
        self.id = id
        self.name = name
        self.terminal = terminal
        self.cron = cron
        self.enabled = enabled
        self.task = task
        self.prompt = prompt
        self.history = []
    }

    /// 사용자 칸만 옮긴 새 예약 — 실행 기록·대기 상태는 비어 있다(「복제」).
    public func duplicated(id newId: String, name newName: String) -> Schedule {
        var s = Schedule(id: newId, name: newName, terminal: terminal, cron: cron, enabled: enabled, task: task, prompt: prompt)
        s.oneShot = oneShot
        s.track = track
        s.lateLimit = lateLimit
        s.clearFirst = clearFirst
        return s
    }

    mutating func record(_ r: RunRecord) {
        lastStatus = r.status
        lastSummary = r.summary
        lastLink = r.link
        history.insert(r, at: 0)
        if history.count > Schedule.historyLimit { history.removeLast(history.count - Schedule.historyLimit) }
    }

    mutating func clearPending() {
        pendingSince = nil
        pendingReason = nil
        waitNote = nil
        clearedFor = nil
    }
}

public struct StoreFile: Codable, Equatable, Sendable {
    public var schedules: [Schedule]

    public init(schedules: [Schedule] = []) {
        self.schedules = schedules
    }
}

/// 터미널 쪽 세션이 `OrcaCron finish` 로 남기는 결과.
public struct RunResult: Codable, Equatable, Sendable {
    public var runId: String
    public var status: String
    public var summary: String?
    public var link: String?
    public var at: Date

    public init(runId: String, status: String, summary: String?, link: String?, at: Date) {
        self.runId = runId
        self.status = status
        self.summary = summary
        self.link = link
        self.at = at
    }

    public static let allowedStatuses = ["성공", "실패", "건너뜀"]
}

/// `OrcaCron send`·`test` 가 inbox/ 에 남기는 보내기 요청. 앱이 다음 확인 때 1회 보내기로 바꾼다.
public struct SendRequest: Codable, Equatable, Sendable {
    public var id: String
    public var terminal: String
    public var text: String?
    public var task: String?
    public var track: Bool
    public var name: String?
    public var at: Date

    public init(id: String, terminal: String, text: String?, task: String?, track: Bool, name: String?, at: Date) {
        self.id = id
        self.terminal = terminal
        self.text = text
        self.task = task
        self.track = track
        self.name = name
        self.at = at
    }
}

public struct TaskFile: Identifiable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var detail: String
    public var id: String { key }
}
