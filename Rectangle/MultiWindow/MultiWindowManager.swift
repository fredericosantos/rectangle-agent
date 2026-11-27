/// MultiWindowManager.swift

import Cocoa
import MASShortcut

class MultiWindowManager {
    typealias BandDirection = GridTiling.Direction
    typealias BandConstraint = GridTiling.Constraint
    typealias BackingPixelBounds = GridTiling.Bounds

    private static var gridStates = [NSScreen: GridTiling.State<AccessibilityElement>]()

    struct TilingWindow {
        let element: AccessibilityElement
        let frame: CGRect
        let windowId: CGWindowID?
        let pid: pid_t?
        let isFocused: Bool
    }

    static func execute(parameters: ExecutionParameters) -> Bool {
        // TODO: Protocol and factory for all multi-window positioning algorithms
        switch parameters.action {
        case .reverseAll:
            ReverseAllManager.reverseAll(windowElement: parameters.windowElement)
            return true
        case .tileAll:
            tileAllWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .tileRows:
            tileWindowsInBands(.rows, windowElement: parameters.windowElement)
            return true
        case .tileColumns:
            tileWindowsInBands(.columns, windowElement: parameters.windowElement)
            return true
        case .cascadeAll:
            cascadeAllWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .cascadeActiveApp:
            cascadeActiveAppWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .tileActiveApp:
            tileActiveAppWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .fillRest:
            fillRestWithLastSelectedWindow(windowElement: parameters.windowElement)
            return true
        case .cycleStackedWindows:
            StackCycleManager.cycle(forward: true, windowElement: parameters.windowElement, windowIsFocused: !parameters.preservesFocus)
            return true
        case .cycleStackedWindowsBackward:
            StackCycleManager.cycle(forward: false, windowElement: parameters.windowElement, windowIsFocused: !parameters.preservesFocus)
            return true
        default:
            return false
        }
    }

    private static func allWindowsOnScreen(windowElement: AccessibilityElement? = nil, sortByPID: Bool = false) -> (screens: UsableScreens, windows: [AccessibilityElement])? {
        let screenDetection = ScreenDetection()

        guard let windowElement = windowElement ?? AccessibilityElement.getFrontWindowElement(),
              let screens = screenDetection.detectScreens(using: windowElement)
        else {
            NSSound.beep()
            Logger.log("Can't detect screen for multiple windows")
            return nil
        }

        return windowsOnScreen(screens: screens, windows: AccessibilityElement.getAllWindowElements(),
                               sortByPID: sortByPID,
                               screenFor: { screenDetection.detectScreens(using: $0)?.currentScreen })
    }

    private static func isActiveTodoWindow(_ window: AccessibilityElement) -> Bool {
        Defaults.todo.userEnabled && TodoManager.isTodoWindow(window)
    }

    static func windowsOnScreen(screens: UsableScreens, windows: [AccessibilityElement],
                                focusedWindow: AccessibilityElement? = nil,
                                sortByPID: Bool = false, combineScreens: Bool = false,
                                isActiveTodoWindow: (AccessibilityElement) -> Bool = MultiWindowManager.isActiveTodoWindow,
                                screenFor: (AccessibilityElement) -> NSScreen?) -> (screens: UsableScreens, windows: [AccessibilityElement]) {
        var windows = windows
        // Focus is known even when CG omits its app, but still obeys the display
        // and Todo exclusions applied to every other candidate.
        if let focusedWindow, !windows.contains(focusedWindow) {
            windows.append(focusedWindow)
        }
        if sortByPID {
            windows.sort(by: { (w1: AccessibilityElement, w2: AccessibilityElement) -> Bool in
                w1.pid ?? pid_t(0) > w2.pid ?? pid_t(0)
            })
        }

        var actualWindows = [AccessibilityElement]()
        for w in windows {
            if isActiveTodoWindow(w) { continue }
            if combineScreens || screenFor(w) == screens.currentScreen,
               w.isWindow == true,
               w.isSheet != true,
               w.isMinimized != true,
               w.isHidden != true,
               w.isSystemDialog != true
            {
                actualWindows.append(w)
            }
        }

        return (screens, actualWindows)
    }

    static func tilingContext(focusedWindow: AccessibilityElement?,
                              screenDetection: ScreenDetection) -> (focusedWindow: AccessibilityElement?, screens: UsableScreens)? {
        let eligibleFocus: AccessibilityElement?
        if let focusedWindow,
              focusedWindow.isWindow == true,
              focusedWindow.isSheet != true,
              focusedWindow.isMinimized != true,
              focusedWindow.isHidden != true,
              focusedWindow.isSystemDialog != true,
              !focusedWindow.frame.isNull {
            eligibleFocus = focusedWindow
        } else {
            eligibleFocus = nil
        }

        let screens: UsableScreens?
        if let eligibleFocus {
            screens = screenDetection.detectScreens(using: eligibleFocus)
        } else {
            screens = screenDetection.detectScreensAtCursor()
        }

        return screens.map { (eligibleFocus, $0) }
    }

    private static func tileWindowsInBands(_ direction: BandDirection, windowElement: AccessibilityElement?) {
        let screenDetection = ScreenDetection()
        guard let context = tilingContext(focusedWindow: windowElement ?? AccessibilityElement.getFocusedWindowElement(),
                                          screenDetection: screenDetection) else { return }

        // Reuse this new on-screen snapshot for AX app discovery and for Space
        // membership, even when another tiling action just moved windows.
        let visibleInfo = WindowUtil.getWindowList(forceRefresh: true)
        let windows = windowsOnScreen(screens: context.screens,
                                      windows: AccessibilityElement.getAllWindowElements(from: visibleInfo),
                                      focusedWindow: context.focusedWindow,
                                      combineScreens: !NSScreen.screensHaveSeparateSpaces && Defaults.combinedDisplayMode.userEnabled,
                                      screenFor: { screenDetection.detectScreens(using: $0)?.currentScreen }).windows

        tileWindowsInBands(direction, focusedWindow: context.focusedWindow, windows: windows,
                           visibleWindowInfo: visibleInfo, screen: context.screens.currentScreen,
                           visibleFrame: context.screens.currentScreen.adjustedVisibleFrame())
    }

    static func tileWindowsInBands(_ direction: BandDirection, focusedWindow: AccessibilityElement?,
                                    windows: [AccessibilityElement], visibleWindowInfo: [WindowInfo],
                                    screen: NSScreen, visibleFrame: CGRect) {
        guard focusedWindow?.frame.screenFlipped.intersects(screen.frame) != false else { return }

        let snapshots = windows.compactMap { window -> TilingWindow? in
            let frame = window.frame
            guard !frame.isNull else { return nil }
            return TilingWindow(element: window,
                                frame: frame,
                                windowId: window.windowId,
                                pid: window.pid,
                                isFocused: window == focusedWindow)
        }

        let currentSpaceWindows = selectCurrentSpaceWindows(snapshots, visibleWindowInfo: visibleWindowInfo,
                                                           frameTolerance: 1 / max(1, screen.backingScaleFactor))
        let ordered = orderForBandTiling(currentSpaceWindows, direction: direction)
        guard !ordered.isEmpty else { return }

        let bounds = BackingPixelBounds(screen.convertRectToBacking(visibleFrame))
        guard bounds.extent(.rows) > 0, bounds.extent(.columns) > 0 else { return }

        let constraints = ordered.map { candidate -> GridTiling.WindowConstraints in
            let isResizable = candidate.element.isResizable()
            let size = isResizable ? (candidate.element.minimumSize ?? .zero) : candidate.frame.size
            let backingSize = screen.convertRectToBacking(CGRect(origin: .zero, size: size)).size
            func constraint(_ size: CGFloat, maximum: Int) -> GridTiling.Constraint {
                let pixels = max(0, Int(isResizable ? ceil(size) : size.rounded()))
                return isResizable ? .resizable(minimum: pixels, maximum: maximum) : .fixed(pixels)
            }
            return GridTiling.WindowConstraints(width: constraint(backingSize.width, maximum: bounds.extent(.columns)),
                                                height: constraint(backingSize.height, maximum: bounds.extent(.rows)))
        }

        let limit = direction == .rows ? Defaults.tileRowsMaxWindows.value : Defaults.tileColumnsMaxWindows.value
        let observed = ordered.map { BackingPixelBounds(screen.convertRectToBacking($0.frame.screenFlipped)).rect }
        gridStates[screen] = GridTiling.perform(windows: ordered.map(\.element), observedFrames: observed,
                                               bounds: bounds, direction: direction, limit: limit,
                                               constraints: constraints, previous: gridStates[screen]) { index, frame in
            let window = ordered[index].element
            window.setFrame(screen.convertRectFromBacking(frame).screenFlipped)
            let achieved = window.frame
            return achieved.isNull ? .null : BackingPixelBounds(screen.convertRectToBacking(achieved.screenFlipped)).rect
        }
    }

    /// On-screen CG records supply current-Space evidence. Raw IDs are exact;
    /// ID-less windows enter only if every maximum one-to-one PID/frame match
    /// uses them. Focus is independently known but still competes for CG evidence.
    /// Identical PID/frame records without IDs cannot prove actual identity.
    static func selectCurrentSpaceWindows(_ snapshots: [TilingWindow], visibleWindowInfo: [WindowInfo],
                                          frameTolerance: CGFloat = 1) -> [TilingWindow] {
        let visibleIds = Set(visibleWindowInfo.map(\.id))
        let identifiedIds = Set(snapshots.compactMap(\.windowId)).intersection(visibleIds)
        var seenVisibleIds = Set<CGWindowID>()
        let unmatchedVisible = visibleWindowInfo.filter {
            !identifiedIds.contains($0.id) && seenVisibleIds.insert($0.id).inserted
        }
        let idlessIndices = snapshots.indices.filter {
            snapshots[$0].windowId == nil && snapshots[$0].pid != nil
        }
        let matches = idlessIndices.map { index in
            unmatchedVisible.indices.filter { cgIndex in
                let info = unmatchedVisible[cgIndex]
                return info.pid == snapshots[index].pid
                    && framesMatch(info.frame, snapshots[index].frame, tolerance: frameTolerance)
            }
        }

        // -1 marks a vertex that has no partner in the current matching.
        var matchedAXForCG = [Int](repeating: -1, count: unmatchedVisible.count)
        func augment(_ ax: Int, seenCG: inout [Bool], matchedAXForCG: inout [Int]) -> Bool {
            for cg in matches[ax] {
                if seenCG[cg] {
                    continue
                } else {
                    seenCG[cg] = true
                    let previousAX = matchedAXForCG[cg]
                    if previousAX == -1 || augment(previousAX, seenCG: &seenCG, matchedAXForCG: &matchedAXForCG) {
                        matchedAXForCG[cg] = ax
                        return true
                    }
                }
            }
            return false
        }
        for ax in matches.indices {
            var seenCG = [Bool](repeating: false, count: unmatchedVisible.count)
            _ = augment(ax, seenCG: &seenCG, matchedAXForCG: &matchedAXForCG)
        }

        var matchedCGForAX = [Int](repeating: -1, count: matches.count)
        for (cg, ax) in matchedAXForCG.enumerated() where ax >= 0 {
            matchedCGForAX[ax] = cg
        }

        // Alternating paths from unmatched AX windows reach every AX window
        // that another equally large assignment could leave unmatched.
        var optionalAX = [Bool](repeating: false, count: matches.count)
        var queue = matches.indices.filter { matchedCGForAX[$0] == -1 }
        for ax in queue {
            optionalAX[ax] = true
        }
        var next = 0
        while next < queue.count {
            let ax = queue[next]
            next += 1
            for cg in matches[ax] where cg != matchedCGForAX[ax] {
                let otherAX = matchedAXForCG[cg]
                if otherAX >= 0 && !optionalAX[otherAX] {
                    optionalAX[otherAX] = true
                    queue.append(otherAX)
                }
            }
        }

        var established = [Bool](repeating: false, count: snapshots.count)
        for ax in matches.indices where matchedCGForAX[ax] >= 0 && !optionalAX[ax] {
            established[idlessIndices[ax]] = true
        }
        return snapshots.enumerated().compactMap { index, candidate in
            if candidate.isFocused {
                return candidate
            } else if let windowId = candidate.windowId {
                return visibleIds.contains(windowId) ? candidate : nil
            } else if established[index] {
                return candidate
            } else {
                return nil
            }
        }
    }

    private static func framesMatch(_ first: CGRect, _ second: CGRect, tolerance: CGFloat) -> Bool {
        let tolerance = max(0, tolerance)
        // AX and CG can round position and size independently. Comparing far
        // edges would add those errors and reject an otherwise matching frame.
        return abs(first.minX - second.minX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance
            && abs(first.width - second.width) <= tolerance
            && abs(first.height - second.height) <= tolerance
    }

    static func orderForBandTiling(_ windows: [TilingWindow], direction: BandDirection) -> [TilingWindow] {
        windows.sorted { first, second in
            let firstPrimary = direction == .rows ? first.frame.minY : first.frame.minX
            let secondPrimary = direction == .rows ? second.frame.minY : second.frame.minX
            let firstSecondary = direction == .rows ? first.frame.minX : first.frame.minY
            let secondSecondary = direction == .rows ? second.frame.minX : second.frame.minY
            if firstPrimary != secondPrimary {
                return firstPrimary < secondPrimary
            } else {
                return firstSecondary < secondSecondary
            }
        }
    }

    static func tileAllWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        let screenDetection = ScreenDetection()
        guard let context = tilingContext(focusedWindow: windowElement ?? AccessibilityElement.getFocusedWindowElement(),
                                          screenDetection: screenDetection) else { return }
        let windows = windowsOnScreen(screens: context.screens,
                                      windows: AccessibilityElement.getAllWindowElements(),
                                      sortByPID: true,
                                      screenFor: { screenDetection.detectScreens(using: $0)?.currentScreen }).windows
        tileAllWindowsOnScreen(windows: windows, screen: context.screens.currentScreen)
    }

    static func tileAllWindowsOnScreen(windows: [AccessibilityElement], screen: NSScreen) {
        guard !windows.isEmpty else { return }

        let screenFrame = screen.adjustedVisibleFrame().screenFlipped
        let count = windows.count

        let columns = Int(ceil(sqrt(CGFloat(count))))
        let rows = Int(ceil(CGFloat(count) / CGFloat(columns)))
        let size = CGSize(width: (screenFrame.maxX - screenFrame.minX) / CGFloat(columns), height: (screenFrame.maxY - screenFrame.minY) / CGFloat(rows))

        for (ind, w) in windows.enumerated() {
            let column = ind % Int(columns)
            let row = ind / Int(columns)
            tileWindow(w, screenFrame: screenFrame, size: size, column: column, row: row)
        }
    }

    private static func tileWindow(_ w: AccessibilityElement, screenFrame: CGRect, size: CGSize, column: Int, row: Int) {
        var rect = w.frame

        // TODO: save previous position in history

        rect.origin.x = screenFrame.origin.x + size.width * CGFloat(column)
        rect.origin.y = screenFrame.origin.y + size.height * CGFloat(row)
        rect.size = size

        w.setFrame(rect)
    }

    static func cascadeAllWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true) else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped

        let delta = CGFloat(Defaults.cascadeAllDeltaSize.value)

        for (ind, w) in windows.enumerated() {
            cascadeWindow(w, screenFrame: screenFrame, delta: delta, index: ind)
        }
    }

    private struct CascadeActiveAppParameters {
        let right: Bool
        let bottom: Bool
        let numWindows: Int
        let size: CGSize

        init(windowFrame: CGRect, screenFrame: CGRect, numWindows: Int, size: CGSize, delta: CGFloat) {
            right = windowFrame.midX > screenFrame.midX
            bottom = windowFrame.midY > screenFrame.midY
            self.numWindows = numWindows
            let maxSize = CGSize(width: screenFrame.width - CGFloat(numWindows - 1) * delta, height: screenFrame.height - CGFloat(numWindows - 1) * delta)
            self.size = CGSize(width: min(size.width, maxSize.width), height: min(size.height, maxSize.height))
        }
    }

    static func cascadeActiveAppWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true),
              let frontWindowElement = windowElement ?? AccessibilityElement.getFrontWindowElement()
        else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped

        let delta = CGFloat(Defaults.cascadeAllDeltaSize.value)

        // keep windows with a pid equal to the front window's pid
        var filtered = windows.filter(hasFrontWindowPid(_:))

        // parameters for cascading active app windows
        var cascadeParameters: CascadeActiveAppParameters?

        if let first = filtered.first, let size = first.size {
            // move the first to become the last (top)
            filtered.append(filtered.removeFirst())
            // set up parameters
            cascadeParameters = CascadeActiveAppParameters(windowFrame: first.frame, screenFrame: screenFrame, numWindows: filtered.count, size: size, delta: delta)
        }

        // cascade the filtered windows
        for (ind, w) in filtered.enumerated() {
            cascadeWindow(w, screenFrame: screenFrame, delta: delta, index: ind, cascadeParameters: cascadeParameters)
        }

        // return true for a w pid equal to the front window's pid
        func hasFrontWindowPid(_ w: AccessibilityElement) -> Bool {
            return w.pid == frontWindowElement.pid
        }
    }

    private static func cascadeWindow(_ w: AccessibilityElement, screenFrame: CGRect, delta: CGFloat, index: Int, cascadeParameters: CascadeActiveAppParameters? = nil) {
        var rect = w.frame

        // TODO: save previous position in history

        rect.origin.x = screenFrame.origin.x + delta * CGFloat(index)
        rect.origin.y = screenFrame.origin.y + delta * CGFloat(index)

        if let cascadeParameters {
            rect.size.width = cascadeParameters.size.width
            rect.size.height = cascadeParameters.size.height

            if cascadeParameters.right {
                rect.origin.x = screenFrame.origin.x + screenFrame.size.width - cascadeParameters.size.width - delta * CGFloat(index)
            }
            if cascadeParameters.bottom {
                rect.origin.y = screenFrame.origin.y + screenFrame.size.height - cascadeParameters.size.height - delta * CGFloat(cascadeParameters.numWindows - 1 - index)
            }
        }

        w.setFrame(rect)
        w.bringToFront()
    }

    static func tileActiveAppWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true),
              let frontWindowElement = windowElement ?? AccessibilityElement.getFrontWindowElement()
        else {
            return
        }

        // keep windows with a pid equal to the front window's pid
        let filtered = windows.filter { $0.pid == frontWindowElement.pid }

        tileAllWindowsOnScreen(windows: filtered, screen: screens.currentScreen)
    }

    // MARK: - Organize the rest of the windows around the focused one

    /// Owners whose "windows" nobody wants arranged. The level check below catches most of them;
    /// this catches the rest, and matches the predicate `getWindowElementUnderCursor` already uses.
    private static let fillRestExcludedProcessNames: Set<String> = ["Dock", "WindowManager", "Notification Center"]

    /// A window that survived filtering, with its id and frame already in hand.
    ///
    /// The id is resolved during planning and never again. `getWindowId()` falls back to matching
    /// pid and frame against a list cached for 100 ms, so once frames are being written that
    /// fallback can answer with a *different* window's id — which would then be recorded as the
    /// restore rect for a window that was never touched.
    private struct FillCandidate {
        let element: AccessibilityElement
        let id: CGWindowID
        let frame: CGRect
    }

    /// The smallest a window may be made, as the rest of the app defines it: a fraction of the
    /// visible frame, a quarter by default, ignoring out-of-range values. Same convention as
    /// `ChangeWindowDimensionCalculation`, which owns it for single-window resizes.
    static func minimumWindowSize(in visibleFrame: CGRect) -> CGSize {
        func fraction(_ value: Double) -> CGFloat {
            (value <= 0 || value > 1) ? 0.25 : CGFloat(value)
        }
        return CGSize(width: floor(visibleFrame.width * fraction(Defaults.minimumWindowWidth.value)),
                      height: floor(visibleFrame.height * fraction(Defaults.minimumWindowHeight.value)))
    }

    /// The exact complement of `anchor` inside `visibleFrame`, as disjoint rectangles.
    ///
    /// At most four: the full-height bands left and right of the anchor, and the strips above and
    /// below it within the anchor's own column. One band for a half or a third, two for a corner,
    /// four for a window floating clear of every edge. Because their union is exactly the free
    /// space, nothing downstream has to reason about L shapes — each band is filled as its own
    /// grid, and a band too small to hold a window at the minimum size is simply dropped.
    private static func freeBands(around anchor: CGRect, in visibleFrame: CGRect) -> [CGRect] {
        let clipped = anchor.intersection(visibleFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return [visibleFrame] }

        return [
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                   width: clipped.minX - visibleFrame.minX, height: visibleFrame.height),
            CGRect(x: clipped.maxX, y: visibleFrame.minY,
                   width: visibleFrame.maxX - clipped.maxX, height: visibleFrame.height),
            CGRect(x: clipped.minX, y: visibleFrame.minY,
                   width: clipped.width, height: clipped.minY - visibleFrame.minY),
            CGRect(x: clipped.minX, y: clipped.maxY,
                   width: clipped.width, height: visibleFrame.maxY - clipped.maxY)
        ].filter { $0.width >= 1 && $0.height >= 1 }
    }

    /// Which of a cell's edges do not lie on the visible frame's boundary, and therefore abut
    /// something else — another cell, or the anchor. `GapCalculation` gives those half a gap, so
    /// two abutting cells contribute a full one between them while a screen edge keeps the whole.
    private static func sharedEdges(of rect: CGRect, in visibleFrame: CGRect) -> Edge {
        var edges: Edge = .none
        if rect.minX > visibleFrame.minX + 1 { edges.insert(.left) }
        if rect.maxX < visibleFrame.maxX - 1 { edges.insert(.right) }
        if rect.minY > visibleFrame.minY + 1 { edges.insert(.bottom) }
        if rect.maxY < visibleFrame.maxY - 1 { edges.insert(.top) }
        return edges
    }

    /// The rect a single window should take to fill what `anchor` leaves free: the largest of the
    /// disjoint bands around it, with gaps applied. Pure, and the only place the layout is decided.
    ///
    /// The largest band rather than the exact complement, because one window cannot be an L. For a
    /// half, a third or any full-width or full-height band they are the same thing; for a corner
    /// anchor the opposite quarter is left empty, which is the honest outcome for one window.
    ///
    /// Returns nil when nothing is left that clears `minSize`, and the caller then moves nothing.
    ///
    /// Coordinates are whatever space the caller is in, since every operation here is symmetric in
    /// y; `.bottom` and `.top` mean the low-y and high-y edges. The callers work in accessibility
    /// coordinates, as the other multi-window actions do.
    static func fillRect(anchor: CGRect,
                         visibleFrame: CGRect,
                         gapSize: CGFloat,
                         minSize: CGSize) -> CGRect? {
        guard let band = freeBands(around: anchor, in: visibleFrame)
            .filter({ $0.width >= minSize.width && $0.height >= minSize.height })
            .max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return nil }

        return GapCalculation.applyGaps(band, sharedEdges: sharedEdges(of: band, in: visibleFrame),
                                        gapSize: Float(gapSize))
    }

    /// Windows the user can actually see on `screen`, cheapest checks first.
    ///
    /// The CoreGraphics list does the expensive filtering for free. `.optionOnScreenOnly` is the
    /// current-Space membership test, so it excludes other Spaces and minimised windows in one
    /// predicate — which matters more than it sounds: `getAllWindowElements` asks each app for
    /// *all* its windows, so without this the multi-window actions move windows on Spaces the user
    /// is not looking at, and the damage is invisible until they switch. The list also carries the
    /// level, owner name and frame needed to drop the Dock, desktop widgets and Notification
    /// Center, and to pick the screen, without a single accessibility round trip. Only survivors
    /// cost AX reads, and those are one window-list enumeration per app rather than per window.
    private static func fillRestCandidates(on screen: NSScreen, screensOrdered: [NSScreen]) -> [FillCandidate] {
        let screenDetection = ScreenDetection()
        let infos = WindowUtil.getWindowList().filter { info in
            info.level == 0
                && !fillRestExcludedProcessNames.contains(info.processName ?? "")
                && info.frame.width >= 1 && info.frame.height >= 1
                && screenDetection.screenContaining(info.frame, screens: screensOrdered) == screen
        }

        /// Walked in the order the list arrives in, which is front to back, because that order is
        /// the whole basis of "the last selected window". Each application is still asked for its
        /// window list only once.
        var elementsByPid = [pid_t: [CGWindowID: AccessibilityElement]]()
        var candidates = [FillCandidate]()
        for info in infos {
            if elementsByPid[info.pid] == nil {
                var byId = [CGWindowID: AccessibilityElement]()
                for element in AccessibilityElement(info.pid).windowElements ?? [] {
                    if let id = element.windowId { byId[id] = element }
                }
                elementsByPid[info.pid] = byId
            }
            guard let element = elementsByPid[info.pid]?[info.id] else { continue }
            candidates.append(FillCandidate(element: element, id: info.id, frame: info.frame))
        }
        return candidates
    }

    private static func refuseFill(_ reason: String) {
        NSSound.beep()
        Logger.log("fill: \(reason)")
    }

    /// Keeps the focused window exactly where it is and expands the window you were using before
    /// it to fill the space it leaves.
    ///
    /// "The last selected window" is the second window in the CoreGraphics on-screen list, which
    /// arrives front to back. That is free, needs no focus tracking of its own, and matches what
    /// the user can see: the window behind the one they are in.
    ///
    /// Not animated, for the reasons on `execute` — the multi-window actions all move several
    /// windows at once, and one of them animating while the rest snap would read as a glitch.
    ///
    /// Undo is the existing `restore` action. The restore rect is recorded before the move, so
    /// focusing the filled window and pressing restore puts it back — the same granularity as
    /// every other undo in the app.
    static func fillRestWithLastSelectedWindow(windowElement: AccessibilityElement? = nil) {
        let start = CACurrentMediaTime()

        guard let anchor = windowElement ?? AccessibilityElement.getFrontWindowElement() else {
            refuseFill("no focused window to fill around")
            return
        }
        guard anchor.isSheet != true, anchor.isSystemDialog != true else {
            refuseFill("the focused window is a sheet or a system dialog")
            return
        }
        guard let anchorId = anchor.getWindowId() else {
            refuseFill("cannot resolve the focused window's id")
            return
        }
        guard let screens = ScreenDetection().detectScreens(using: anchor) else {
            refuseFill("cannot detect the screen of the focused window")
            return
        }

        /// Where the anchor is *going* if its own move is still animating, so a shortcut pressed
        /// mid-animation does not measure a halfway frame. And where Rectangle last put it, if it
        /// is still sitting there: a half placed by an action then leaves an exactly complementary
        /// band rather than one a point off from the app's own rounding.
        var anchorFrame = anchor.logicalFrame
        if let recorded = AppDelegate.windowHistory.lastRectangleActions[anchorId]?.rect,
           approximatelyEqual(recorded, anchorFrame) {
            anchorFrame = recorded
        }
        guard !anchorFrame.isNull else {
            refuseFill("cannot read the focused window's frame")
            return
        }

        let visibleFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped
        let minSize = minimumWindowSize(in: visibleFrame)

        guard let target = fillRestCandidates(on: screens.currentScreen, screensOrdered: screens.screensOrdered)
            .first(where: { candidate in
                guard candidate.id != anchorId,
                      candidate.element.isWindow == true,
                      candidate.element.isSheet != true,
                      candidate.element.isStandardWindow == true,
                      candidate.element.isResizable() else { return false }
                /// A window shelved in the Stage Manager strip is shelved deliberately, and
                /// `SnappingManager.canSnap` already refuses to move one for the same reason.
                guard StageUtil.stageCapable, StageUtil.stageEnabled else { return true }
                return StageUtil.getStageStripWindowGroup(candidate.id, screens.currentScreen) == nil
            })
        else {
            refuseFill("no other window on this screen to fill with")
            return
        }

        guard let rect = fillRect(anchor: anchorFrame, visibleFrame: visibleFrame,
                                  gapSize: CGFloat(Defaults.gapSize.value), minSize: minSize) else {
            refuseFill("the focused window leaves nothing bigger than \(Int(minSize.width))x\(Int(minSize.height))")
            return
        }

        /// Ask the WindowServer whether the window would actually take the rect before writing it.
        /// The animation settlement corrects a refused size after the fact with a second pass;
        /// predicting it costs one query and never shows the correction. An unknown answer counts
        /// as a refusal: a freshly opened window reports nothing for the first seconds of its
        /// life, and filling the screen with a window that then clamps is worse than not filling
        /// it.
        guard let achievable = target.element.achievableSize(for: rect.size),
              abs(achievable.width - rect.width) <= 1, abs(achievable.height - rect.height) <= 1 else {
            refuseFill("the last selected window will not take \(Int(rect.width))x\(Int(rect.height))")
            return
        }

        guard !approximatelyEqual(target.frame, rect) else {
            Logger.log("fill: the last selected window already fills the space")
            return
        }

        /// Same rule `WindowManager` uses: only claim the restore rect if the window has not
        /// already got one from a position the user chose, so a repeat press does not overwrite the
        /// original with an already-filled frame.
        let history = AppDelegate.windowHistory
        if history.restoreRects[target.id] == nil
            || history.lastRectangleActions[target.id]?.rect != target.frame {
            history.restoreRects[target.id] = target.frame
        }

        WindowAnimator.shared.cancel(for: target.element)
        target.element.setFrame(rect)

        history.recordAction(windowId: target.id, resultingRect: rect, action: .fillRest, subAction: nil)

        Logger.log(String(format: "fill: last selected window filled %.0fx%.0f in %.0f ms",
                          rect.width, rect.height, (CACurrentMediaTime() - start) * 1000))
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
