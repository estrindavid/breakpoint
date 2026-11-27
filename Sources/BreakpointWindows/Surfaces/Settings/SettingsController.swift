import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The settings window (SPEC §3.9): the Windows counterpart of the macOS
/// `SettingsWindowController`. A resizable document window on Mica that follows the system's
/// light or dark app mode, default `Theme.Size.settingsSize`, minimum 720 × 560, sidebar 200.
///
/// Contract: `show(pane:)` creates the window on first use, selects `pane` (or
/// `SettingsNavigator.pendingPane`, or keeps the current one), and brings it to the front with the
/// focus in the sidebar. Closing hides it (state kept). `tearDown()` destroys it. The last pane and
/// the window's frame are remembered under `HKCU\Software\Breakpoint` (not in development runs
/// with `BREAKPOINT_HOME`, which must leave no trace outside it), as the Mac keeps them in its
/// user defaults.
///
/// Keyboard: Ctrl+1…Ctrl+8 select a pane; ↑ ↓ move through the sidebar while it has the focus;
/// Page Up / Page Down / Home / End and the mouse wheel scroll the pane; Tab moves through the
/// controls (scrolling the focused one into view); Ctrl+W and Esc close (Esc first closes an
/// options sheet, stops recording a shortcut or leaves the text field).
@MainActor
public final class SettingsController: SurfaceController {
    private let state: AppState
    private let actions: AppActions
    private var window: DrawnWindow?
    private let ui = SettingsUI()
    /// The selected pane.
    public private(set) var pane: SettingsPane
    private var scroll: Float = 0
    private var look: Look = .system
    private var opaque = Appearance.prefersOpaque
    private var listening = false
    private var controlsKeyDown: ((UInt32) -> Bool)?
    private var controlsMouseDown: ((PointF) -> Void)?
    private var controlsMouseUp: ((PointF) -> Void)?
    private var seenConnectedAt: [IntegrationID: Date] = [:]
    private var flashTimer: Timer?
    private var copiedTimer: Timer?

    public init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
        pane = SettingsMemory.pane ?? .breaks
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// The window's handle once created (dialogs it owns, the tour).
    public var hwnd: HWND? { window?.window.hwnd }

    // MARK: SurfaceController

    public func sync() {
        guard let window, window.isVisible else { return }
        noticeVerifiedInstalls()
        updateAnimation()
        clampScroll()
        window.setNeedsDisplay()
    }

    public func tearDown() {
        hideWindow()
        flashTimer?.invalidate()
        copiedTimer?.invalidate()
        window?.destroy()
        window = nil
    }

    // MARK: Showing

    public func show(pane requested: SettingsPane? = nil) {
        if let pending = SettingsNavigator.pendingPane {
            select(pending)
            SettingsNavigator.pendingPane = nil
        }
        if let requested { select(requested) }
        listen()
        let window = self.window ?? makeWindow()
        self.window = window
        refreshLook()
        ui.login = WindowsLoginItem().availability()
        if !window.isVisible {
            seenConnectedAt = Dictionary(uniqueKeysWithValues: state.integrations.compactMap { row in row.connectedAt.map { (row.id, $0) } })
            window.controls.focused = SettingsView.sidebarID(pane)
        }
        clampScroll()
        window.window.show(activate: true)
        if let hwnd = window.window.hwnd, IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        updateAnimation()
    }

    /// Hides the window (Take the tour: the tour happens on the real surfaces, not over Settings).
    public func close() {
        hideWindow()
    }

    private func hideWindow() {
        guard let window, window.isVisible else { return }
        leaveTransientStates()
        ui.sheet = nil
        SettingsMemory.saveFrame(window.window.pixelFrame)
        window.hide()
        window.animating = false
    }

    private func makeWindow() -> DrawnWindow {
        let window = DrawnWindow(style: .document(title: "Breakpoint Settings", resizable: true), look: look)
        window.background = nil
        window.create(size: Theme.Size.settingsSize)
        window.window.setContentSize(Theme.Size.settingsSize)
        place(window)
        window.content = { [weak self] canvas, controls in
            guard let self else { return }
            SettingsView.draw(canvas, controls, self.model, self.handlers)
        }
        // Keys, characters and clicks go through the window first, then to the controls.
        controlsKeyDown = window.window.onKeyDown
        controlsMouseDown = window.window.onMouseDown
        controlsMouseUp = window.window.onMouseUp
        window.window.onKeyDown = { [weak self] key in self?.keyDown(key) ?? false }
        window.window.onMouseDown = { [weak self] point in self?.mouseDown(point) }
        window.window.onMouseUp = { [weak self] point in self?.mouseUp(point) }
        window.window.onChar = { [weak self] character in self?.typed(character) }
        window.window.onScroll = { [weak self] notches in self?.scrollBy(-notches * 48) }
        window.window.onResize = { [weak self] in self?.clampScroll() }
        window.window.onClose = { [weak self] in
            self?.hideWindow()
            return false
        }
        window.window.onMessage = { [weak self] message, _, lParam in self?.message(message, lParam) }
        return window
    }

    /// The remembered frame if it is still on a display, else centred on the display under the
    /// pointer.
    private func place(_ window: DrawnWindow) {
        guard let hwnd = window.window.hwnd else { return }
        if let saved = SettingsMemory.frame, MonitorFromRect([saved], DWORD(MONITOR_DEFAULTTONULL)) != nil {
            SetWindowPos(hwnd, nil, saved.left, saved.top, saved.right - saved.left, saved.bottom - saved.top,
                         UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            return
        }
        guard let monitor = Monitors.underPointer() ?? Monitors.primary() else { return }
        let frame = window.window.pixelFrame
        let width = frame.right - frame.left, height = frame.bottom - frame.top
        let area = monitor.workArea
        let x = area.left + max(0, (area.right - area.left - width) / 2)
        let y = area.top + max(0, (area.bottom - area.top - height) / 2)
        SetWindowPos(hwnd, nil, x, y, 0, 0, UINT(SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE))
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        SystemEvents.shared.start()
        SystemEvents.shared.on(UInt32(WM_SETTINGCHANGE)) { [weak self] _, _ in
            // The app mode, transparency effects or high contrast may have changed.
            self?.refreshLook()
            return nil
        }
    }

    private func refreshLook() {
        look = Look.system
        opaque = Appearance.prefersOpaque
        guard let window else { return }
        window.controls.look = look
        if let hwnd = window.window.hwnd { Appearance.refresh(hwnd) }
        window.setNeedsDisplay()
    }

    // MARK: The model

    private var model: SettingsModel {
        SettingsModel(state: state, pane: pane, scroll: scroll, look: look, ui: ui, opaque: opaque)
    }

    private lazy var handlers: SettingsHandlers = {
        var handlers = SettingsHandlers()
        handlers.actions = actions
        handlers.select = { [weak self] pane in self?.select(pane) }
        handlers.changed = { [weak self] in self?.redraw() }
        handlers.startRecording = { [weak self] in self?.toggleRecording() }
        handlers.revealData = { SettingsShell.revealData() }
        handlers.copyCommand = { [weak self] in self?.copyCommand() }
        handlers.chooseCodexFolder = { [weak self] in self?.chooseCodexFolder() }
        handlers.focusCodexField = { [weak self] in self?.beginEditingCodexFolder() }
        handlers.openSheet = { [weak self] sheet in
            guard let self else { return }
            self.leaveTransientStates()
            self.ui.sheet = sheet
            // Return presses Done until a control in the sheet takes the focus.
            self.window?.controls.focused = nil
            self.redraw()
        }
        handlers.closeSheet = { [weak self] in
            self?.ui.sheet = nil
            self?.redraw()
        }
        return handlers
    }()

    private func redraw() { window?.setNeedsDisplay() }

    private func select(_ newPane: SettingsPane) {
        leaveTransientStates()
        if newPane != pane {
            pane = newPane
            scroll = 0
            SettingsMemory.pane = newPane
        }
        if let controls = window?.controls, controls.focused?.hasPrefix("sidebar.") ?? true {
            controls.focused = SettingsView.sidebarID(newPane)
        }
        redraw()
    }

    /// Stops recording a shortcut and keeps what the text field holds.
    private func leaveTransientStates() {
        ui.recording = false
        ui.recorderHint = nil
        commitCodexFolder()
        if let draft = ui.volumeDraft { commitVolume(draft) }
    }

    // MARK: Scrolling

    private func clampScroll() {
        guard let window else { return }
        let limit = SettingsView.maxScroll(model, size: window.window.size)
        scroll = min(max(0, scroll), limit)
    }

    private func scrollBy(_ distance: Float) {
        let before = scroll
        scroll += distance
        clampScroll()
        if scroll != before { redraw() }
    }

    private func scroll(to step: Int32) {
        guard let window else { return }
        let page = max(40, SettingsView.viewport(window.window.size).height - 60)
        switch step {
        case VK_PRIOR: scrollBy(-page)
        case VK_NEXT: scrollBy(page)
        case VK_HOME: scrollBy(-.greatestFiniteMagnitude / 4)
        default: scrollBy(.greatestFiniteMagnitude / 4)
        }
    }

    /// After Tab, the focused control comes into view.
    private func revealFocus() {
        guard let window, let id = window.controls.focused, let rect = ui.frames.rects[id] else { return }
        let viewport = SettingsView.viewport(window.window.size)
        let margin: Float = 12
        let top = rect.y - scroll, bottom = rect.maxY - scroll
        if top < viewport.minY + margin {
            scrollBy(top - viewport.minY - margin)
        } else if bottom > viewport.maxY - margin {
            scrollBy(bottom - viewport.maxY + margin)
        }
    }

    // MARK: Input

    private func message(_ message: UINT, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_GETMINMAXINFO:
            guard let window, let hwnd = window.window.hwnd,
                  let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) else { return nil }
            var frame = RECT(), client = RECT()
            GetWindowRect(hwnd, &frame)
            GetClientRect(hwnd, &client)
            let chromeWidth = (frame.right - frame.left) - (client.right - client.left)
            let chromeHeight = (frame.bottom - frame.top) - (client.bottom - client.top)
            let s = window.window.scale
            info.pointee.ptMinTrackSize.x = LONG(SettingsMetrics.minimumSize.width * s) + chromeWidth
            info.pointee.ptMinTrackSize.y = LONG(SettingsMetrics.minimumSize.height * s) + chromeHeight
            return 0
        case WM_SYSCHAR:
            // Alt+key while recording a shortcut: no menu mnemonic, no beep.
            return ui.recording ? 0 : nil
        default:
            return nil
        }
    }

    private static func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    private func keyDown(_ key: UInt32) -> Bool {
        guard let window else { return false }
        let vk = Int32(key)
        let ctrl = Self.isDown(VK_CONTROL), alt = Self.isDown(VK_MENU)
        if ui.recording, recordKey(vk) { return true }
        if ui.codexDraft != nil, editKey(vk, ctrl: ctrl) { return true }
        if ui.sheet != nil {
            if vk == VK_ESCAPE || (vk == VK_RETURN && window.controls.focused == nil) {
                ui.sheet = nil
                redraw()
                return true
            }
            return controlsKeyDown?(key) ?? false
        }
        if ctrl, !alt {
            if (0x31...0x38).contains(vk) {
                select(SettingsPane.allCases[Int(vk - 0x31)])
                return true
            }
            if vk == 0x57 { // W
                hideWindow()
                return true
            }
        }
        if vk == VK_ESCAPE {
            hideWindow()
            return true
        }
        if !ctrl, !alt {
            switch vk {
            case VK_PRIOR, VK_NEXT, VK_HOME, VK_END:
                scroll(to: vk)
                return true
            case VK_UP, VK_DOWN:
                if window.controls.focused?.hasPrefix("sidebar.") ?? true {
                    let panes = SettingsPane.allCases
                    let index = panes.firstIndex(of: pane) ?? 0
                    let next = min(max(0, index + (vk == VK_UP ? -1 : 1)), panes.count - 1)
                    window.controls.focused = SettingsView.sidebarID(panes[next])
                    select(panes[next])
                    return true
                }
            default:
                break
            }
        }
        let used = controlsKeyDown?(key) ?? false
        if vk == VK_TAB {
            revealFocus()
            // Tabbing into the Codex folder field starts typing in it.
            if window.controls.focused == SettingsUI.codexFieldID { beginEditingCodexFolder() }
        }
        return used
    }

    private func mouseDown(_ point: PointF) {
        let wasRecording = ui.recording
        controlsMouseDown?(point)
        guard let controls = window?.controls else { return }
        if ui.codexDraft != nil, controls.focused != SettingsUI.codexFieldID { commitCodexFolder() }
        // A click anywhere but the recorder stops recording.
        if wasRecording, controls.pressed != SettingsUI.recorderID {
            ui.recording = false
            ui.recorderHint = nil
            redraw()
        }
    }

    private func mouseUp(_ point: PointF) {
        controlsMouseUp?(point)
        if let draft = ui.volumeDraft, window?.controls.pressed == nil {
            commitVolume(draft)
            actions.previewSound(.needsYouChime)
        }
    }

    private func commitVolume(_ value: Double) {
        ui.volumeDraft = nil
        actions.updateSettings { $0.volume = value }
        redraw()
    }

    // MARK: The shortcut recorder

    private func toggleRecording() {
        if ui.recording {
            ui.recording = false
        } else {
            commitCodexFolder()
            ui.recording = true
        }
        ui.recorderHint = nil
        redraw()
    }

    /// The next key combination becomes the flyout shortcut. Esc cancels, Backspace or Delete
    /// clears it; it needs Ctrl, Alt or Win, and the nudge's own two are refused.
    private func recordKey(_ vk: Int32) -> Bool {
        let modifierKeys: [Int32] = [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN, VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL,
                                     VK_LMENU, VK_RMENU, VK_CAPITAL]
        if modifierKeys.contains(vk) { return true }
        func finish() {
            ui.recording = false
            ui.recorderHint = nil
            redraw()
        }
        switch vk {
        case VK_ESCAPE:
            finish()
            return true
        case VK_BACK, VK_DELETE:
            actions.updateSettings { $0.popoverHotkey = nil }
            finish()
            return true
        case VK_TAB where !Self.isDown(VK_CONTROL) && !Self.isDown(VK_MENU):
            finish()
            return false
        default:
            break
        }
        var carbon: UInt32 = 0
        var symbols = ""
        if Self.isDown(VK_CONTROL) { carbon |= HotKeyCombo.controlKey; symbols += "⌃" }
        if Self.isDown(VK_MENU) { carbon |= HotKeyCombo.optionKey; symbols += "⌥" }
        if Self.isDown(VK_SHIFT) { carbon |= HotKeyCombo.shiftKey; symbols += "⇧" }
        if Self.isDown(VK_LWIN) || Self.isDown(VK_RWIN) { carbon |= HotKeyCombo.cmdKey; symbols += "⌘" }
        guard carbon & (HotKeyCombo.controlKey | HotKeyCombo.optionKey | HotKeyCombo.cmdKey) != 0 else {
            ui.recorderHint = "Add Ctrl, Alt or Win"
            redraw()
            return true
        }
        guard let keyCode = HotKeys.carbonKey(vk) else {
            ui.recorderHint = "Use a letter, digit or symbol key"
            redraw()
            return true
        }
        // The display form is the Mac's, so one settings file reads right on both.
        let key = HotKeys.display(HotKeyCombo(keyCode: keyCode, carbonModifiers: 0, display: ""))
        let combo = HotKeyCombo(keyCode: keyCode, carbonModifiers: carbon, display: symbols + key)
        let reserved = [HotKeyCombo.nudgeStart, HotKeyCombo.nudgeDismiss]
        if reserved.contains(where: { $0.keyCode == combo.keyCode && $0.carbonModifiers == combo.carbonModifiers }) {
            ui.recorderHint = "\(HotKeys.display(combo)) is used by the nudge"
            redraw()
            return true
        }
        actions.updateSettings { $0.popoverHotkey = combo }
        finish()
        return true
    }

    // MARK: The Codex folder field

    private func beginEditingCodexFolder() {
        guard ui.codexDraft == nil else { return }
        ui.recording = false
        ui.codexDraft = state.settings.codexHome ?? ""
        window?.controls.focused = SettingsUI.codexFieldID
        redraw()
    }

    private func commitCodexFolder() {
        guard let draft = ui.codexDraft else { return }
        ui.codexDraft = nil
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        if value != state.settings.codexHome { actions.updateSettings { $0.codexHome = value } }
        redraw()
    }

    private func typed(_ character: Character) {
        guard ui.codexDraft != nil else { return }
        ui.codexDraft?.append(character)
        redraw()
    }

    /// Keys while the field is being edited; false passes the key on (Tab, arrows).
    private func editKey(_ vk: Int32, ctrl: Bool) -> Bool {
        switch vk {
        case VK_BACK:
            if ctrl {
                // Ctrl+Backspace: the last path component.
                var draft = ui.codexDraft ?? ""
                while let last = draft.last, last == "\\" || last == "/" { draft.removeLast() }
                while let last = draft.last, last != "\\" && last != "/" { draft.removeLast() }
                ui.codexDraft = draft
            } else if ui.codexDraft?.isEmpty == false {
                ui.codexDraft?.removeLast()
            }
            redraw()
            return true
        case VK_RETURN:
            commitCodexFolder()
            return true
        case VK_ESCAPE:
            ui.codexDraft = nil
            redraw()
            return true
        case VK_SPACE:
            return true // typed as a character, not a press of the field
        case VK_TAB:
            commitCodexFolder()
            return false
        default:
            if ctrl, vk == 0x56, let pasted = SettingsShell.clipboardText() { // Ctrl+V
                ui.codexDraft?.append(contentsOf: pasted.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))
                redraw()
                return true
            }
            return ctrl ? false : !(vk == VK_UP || vk == VK_DOWN || vk == VK_PRIOR || vk == VK_NEXT)
        }
    }

    private func chooseCodexFolder() {
        guard let path = SettingsShell.chooseFolder(owner: window?.window.hwnd, title: "Choose the folder Codex keeps its settings in")
        else { return }
        ui.codexDraft = nil
        actions.updateSettings { $0.codexHome = path }
        redraw()
    }

    // MARK: Copy, flashes and spinners

    private func copyCommand() {
        SettingsShell.copy(SettingsPanes.anyToolCommand, owner: window?.window.hwnd)
        ui.copiedUntil = Date().addingTimeInterval(1.5)
        redraw()
        copiedTimer?.invalidate()
        let timer = Timer.after(1.55, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.ui.copiedUntil = nil
                self?.redraw()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        copiedTimer = timer
    }

    /// An install just verified (a new `connectedAt`) flashes its pill mint for a moment.
    private func noticeVerifiedInstalls() {
        var changed = false
        for row in state.integrations {
            guard let at = row.connectedAt, seenConnectedAt[row.id] != at else { continue }
            seenConnectedAt[row.id] = at
            ui.flashing.insert(row.id)
            changed = true
        }
        guard changed else { return }
        flashTimer?.invalidate()
        let timer = Timer.after(1.6, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.ui.flashing.removeAll()
                self?.redraw()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    /// Spinners turn only while something is busy and the window shows (steady under Reduce Motion).
    private func updateAnimation() {
        guard let window else { return }
        let busy = state.integrations.contains { $0.isBusy }
        let updating: Bool
        switch state.update.phase {
        case .checking, .installing: updating = true
        default: updating = false
        }
        let spins = window.isVisible && !Appearance.reduceMotion && (busy || updating)
        ui.spins = spins
        window.animating = spins
    }
}

/// The few shell services the window uses itself: File Explorer, the clipboard, the folder picker.
@MainActor
enum SettingsShell {
    /// Opens Breakpoint's data folder (or the home folder before it exists) in File Explorer.
    static func revealData() {
        let paths = BreakpointPaths.live()
        let url = FileManager.default.fileExists(atPath: paths.appSupport.path) ? paths.appSupport : paths.home
        _ = ShellExecuteW(nil, "open".wide, PathDisplay.native(url).wide, nil, nil, SW_SHOWNORMAL)
    }

    static func copy(_ text: String, owner: HWND?) {
        let utf16 = Array(text.utf16) + [0]
        guard OpenClipboard(owner) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let bytes = utf16.count * MemoryLayout<UInt16>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        utf16.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
    }

    static func clipboardText() -> String? {
        guard IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), OpenClipboard(nil) else { return nil }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let pointer = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }
        return String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }

    /// The system's folder picker; the chosen folder's path, or nil.
    static func chooseFolder(owner: HWND?, title: String) -> String? {
        _ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
        let titleText = title.wide
        return titleText.withUnsafeBufferPointer { titleBuffer -> String? in
            var info = BROWSEINFOW()
            info.hwndOwner = owner
            info.lpszTitle = titleBuffer.baseAddress
            info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE)
            guard let list = SHBrowseForFolderW(&info) else { return nil }
            defer { CoTaskMemFree(UnsafeMutableRawPointer(mutating: list)) }
            var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
            guard SHGetPathFromIDListW(list, &buffer) else { return nil }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            return String(decoding: buffer.prefix(length), as: UTF16.self)
        }
    }
}

/// The last pane and the window's frame, under `HKCU\Software\Breakpoint` (never in development
/// runs with `BREAKPOINT_HOME`, which must leave nothing outside their home).
@MainActor
enum SettingsMemory {
    static let key = "Software\\Breakpoint"

    static var isEnabled: Bool { ProcessInfo.processInfo.environment[BreakpointPaths.homeOverrideVariable] == nil }

    static var pane: SettingsPane? {
        get { read("SettingsPane").flatMap(SettingsPane.init(rawValue:)) }
        set { if let newValue { write("SettingsPane", newValue.rawValue) } }
    }

    static var frame: RECT? {
        guard let text = read("SettingsFrame") else { return nil }
        let numbers = text.split(separator: ",").compactMap { Int32($0) }
        guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] else { return nil }
        return RECT(left: numbers[0], top: numbers[1], right: numbers[2], bottom: numbers[3])
    }

    static func saveFrame(_ rect: RECT) {
        guard rect.right > rect.left, rect.bottom > rect.top, rect.left > -30000 else { return }
        write("SettingsFrame", "\(rect.left),\(rect.top),\(rect.right),\(rect.bottom)")
    }

    private static func read(_ name: String) -> String? {
        guard isEnabled else { return nil }
        var size: DWORD = 0
        guard RegGetValueW(HKEY_CURRENT_USER, key.wide, name.wide, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == ERROR_SUCCESS,
              size > 0 else { return nil }
        var buffer = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
        guard RegGetValueW(HKEY_CURRENT_USER, key.wide, name.wide, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) == ERROR_SUCCESS
        else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }

    private static func write(_ name: String, _ value: String) {
        guard isEnabled else { return }
        let wide = value.wide
        _ = wide.withUnsafeBufferPointer { buffer in
            RegSetKeyValueW(HKEY_CURRENT_USER, key.wide, name.wide, DWORD(REG_SZ), buffer.baseAddress,
                            DWORD(buffer.count * MemoryLayout<WCHAR>.size))
        }
    }
}
