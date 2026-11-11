import Foundation

/// 메뉴 화면 하나.
public enum Route: Equatable, Sendable {
    case list
    case edit(Schedule, isNew: Bool)
    case send(handle: String, task: String?)
    case templates
    case template(key: String?)
}

/// 화면 이동 스택 — 앞으로 가면 쌓고, 뒤로·취소는 들어온 화면으로 돌아간다.
/// 저장·보내기처럼 일을 끝낸 동작은 결과가 보이는 목록으로 간다(`go(.list)`).
public struct RouteStack: Equatable, Sendable {
    /// 목록 위에 쌓인 화면. 비면 목록.
    public private(set) var stack: [Route]

    public init(_ start: Route = .list) {
        stack = start == .list ? [] : [start]
    }

    public var top: Route { stack.last ?? .list }

    /// `.list` 는 목록으로, 나머지는 그 화면을 쌓는다.
    public mutating func go(_ r: Route) {
        if r == .list { stack.removeAll() } else { stack.append(r) }
    }

    public mutating func back() {
        if !stack.isEmpty { stack.removeLast() }
    }

    /// 예약·보내기 화면에서 템플릿을 고치러 갈 때 — 지금 입력을 그 자리에 남겨 두고 템플릿 편집을 쌓는다.
    public mutating func openTemplate(_ key: String?, leaving current: Route) {
        if !stack.isEmpty { stack[stack.count - 1] = current }
        stack.append(.template(key: key))
    }

    /// 템플릿 편집을 마칠 때(saved = 저장한 키, 취소면 nil).
    /// 예약·보내기 화면에서 「새 템플릿」으로 왔으면 만든 템플릿을 골라 두고, 예약 이름이 비었으면 제목을 넣는다.
    public mutating func finishTemplate(key: String?, saved: String?, title: String?) {
        back()
        guard key == nil, let saved, let top = stack.last else { return }
        switch top {
        case .edit(var s, let isNew):
            if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = title ?? "" }
            s.task = saved
            s.prompt = nil
            stack[stack.count - 1] = .edit(s, isNew: isNew)
        case .send(let handle, _):
            stack[stack.count - 1] = .send(handle: handle, task: saved)
        default:
            break
        }
    }
}
