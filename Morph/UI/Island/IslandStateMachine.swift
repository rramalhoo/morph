import Foundation

enum IslandMode: Equatable, Sendable {
    /// How the panel was opened decides how it closes.
    enum Origin: Equatable, Sendable {
        case pointer
        /// From the menu bar. Holds focus until Escape or focus moves elsewhere.
        case keyboard
        case fileDrag
    }

    case idle
    case hover
    case expanded(Origin)

    var isExpanded: Bool {
        if case .expanded = self { true } else { false }
    }
}

enum IslandEvent: Equatable, Sendable {
    case pointerEntered
    case pointerExited
    case hoverDelayElapsed
    case collapseDelayElapsed
    case clicked
    case openRequested
    case escapePressed
    case focusLost
    case interactionBegan
    case interactionEnded
    case fileDragEntered
    case fileDragExited
    /// Sleep, display changes and pausing: drop everything transient.
    case reset
}

enum IslandEffect: Equatable, Sendable {
    case scheduleHover
    case cancelHover
    case scheduleCollapse
    case cancelCollapse
}

/// The pure interaction logic. Timers live in `IslandController`, which turns effects into
/// scheduled work and feeds elapsed delays back in as events.
struct IslandStateMachine: Sendable {
    var hoverEnabled = true
    var clickEnabled = true

    private(set) var mode = IslandMode.idle
    private(set) var isPointerInside = false
    private var isDraggingFile = false
    private var interactionCount = 0

    var isInteracting: Bool { interactionCount > 0 }

    private var shouldStayOpen: Bool {
        isPointerInside || isDraggingFile || interactionCount > 0 || mode == .expanded(.keyboard)
    }

    mutating func handle(_ event: IslandEvent) -> [IslandEffect] {
        switch event {
        case .pointerEntered:
            isPointerInside = true
            return mode == .idle && hoverEnabled ? [.cancelCollapse, .scheduleHover] : [.cancelCollapse]

        case .pointerExited:
            isPointerInside = false
            return [.cancelHover] + collapseIfNeeded()

        case .hoverDelayElapsed:
            if mode == .idle, isPointerInside, hoverEnabled { mode = .hover }
            return []

        case .collapseDelayElapsed:
            if mode != .idle, !shouldStayOpen { mode = .idle }
            return []

        case .clicked:
            guard clickEnabled, !isInteracting else { return [] }
            if mode.isExpanded { return close() }
            mode = .expanded(.pointer)
            return [.cancelHover, .cancelCollapse]

        case .openRequested:
            mode = .expanded(.keyboard)
            return [.cancelHover, .cancelCollapse]

        case .escapePressed:
            return close()

        case .focusLost:
            guard mode == .expanded(.keyboard) else { return [] }
            return close()

        case .interactionBegan:
            interactionCount += 1
            return [.cancelCollapse]

        case .interactionEnded:
            interactionCount = max(0, interactionCount - 1)
            return collapseIfNeeded()

        case .fileDragEntered:
            isDraggingFile = true
            if !mode.isExpanded { mode = .expanded(.fileDrag) }
            return [.cancelHover, .cancelCollapse]

        case .fileDragExited:
            isDraggingFile = false
            return collapseIfNeeded()

        case .reset:
            isPointerInside = false
            isDraggingFile = false
            interactionCount = 0
            mode = .idle
            return [.cancelHover, .cancelCollapse]
        }
    }

    private func collapseIfNeeded() -> [IslandEffect] {
        mode != .idle && !shouldStayOpen ? [.scheduleCollapse] : []
    }

    private mutating func close() -> [IslandEffect] {
        interactionCount = 0
        isDraggingFile = false
        mode = .idle
        return [.cancelHover, .cancelCollapse]
    }
}
