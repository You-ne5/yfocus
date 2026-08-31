import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "FocusModel.js" as Model

// yfocus overlay. One layer-shell window serves all three modes via
// the summon payload:
//   {"mode":"manage"} (default) -> FocusManageView
//   {"mode":"jump"}             -> JumpPrompt  (insert at top, becomes current)
//   {"mode":"add"}              -> AddPrompt   (append to end of queue)
//
// Focus architecture: keyCatcher WRAPS everything inside the window, so
// keys the add-input doesn't consume bubble up into the shortcut handler.
// open() routes focus deterministically — never auto-focus the input.
//
// In-memory state is authoritative for rendering; every mutation also
// fires a detached `yfocus` CLI call (from QML scope) that performs the
// same op on disk under the store lock. FileView's watch reconciles.
Item {
  id: root

  // Injected by omarchy-shell summon/hide.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string mode: "manage"
  property var state: Model.emptyQueue()
  property int selectedIndex: 0
  property bool showCompleted: false
  property string executablePath: ""

  // Shared menu-surface tokens so themes that style the menu style us too.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderCol: Color.menu.border
  readonly property color scrimColor: Color.menu.scrim
  readonly property string fontFamily: Style.font.menuFamily

  readonly property var queueRows: Model.getQueue(state)

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.mode = ["manage", "jump", "add"].indexOf(payload.mode) !== -1 ? payload.mode : "manage"

    queueFile.reload()
    clampSelection()

    // Prompt items are mounted permanently (loaders are mode-bound, not
    // opened-bound), so these calls are synchronous and race-free.
    root.opened = true

    if (root.mode === "manage") {
      keyCatcher.forceActiveFocus()
    } else if (root.mode === "jump") {
      jumpLoader.item.reset()
      jumpLoader.item.focusInput()
    } else if (root.mode === "add") {
      addLoader.item.reset()
      addLoader.item.focusInput()
    }
  }

  function close() {
    root.opened = false
  }

  function toggle(payloadJson) {
    if (root.opened) root.close()
    else root.open(payloadJson || "{}")
  }

  function ping() { return "ok" }

  // ---- selection ----------------------------------------------------

  function clampSelection() {
    if (root.queueRows.length === 0) { root.selectedIndex = 0; return }
    if (root.selectedIndex >= root.queueRows.length) root.selectedIndex = root.queueRows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }
  onQueueRowsChanged: clampSelection()

  function select(delta) {
    if (root.queueRows.length === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = root.queueRows.length - 1
    else if (next > root.queueRows.length - 1) next = 0
    root.selectedIndex = next
  }

  // ---- persistence ----------------------------------------------------
  // Detached CLI call from QML scope. The optimistic in-memory state stays
  // authoritative for rendering; the binary applies the same op on disk
  // under the store lock, and FileView's watch reconciles afterwards.

  function persist(op, args) {
    if (!root.executablePath) return
    Quickshell.execDetached([root.executablePath, op].concat(args || []))
  }

  // ---- mutations (optimistic in-memory + detached CLI persistence) ---

  function applyJump(title) {
    var next = Model.jump(root.state, title)
    if (next === root.state) return
    root.state = next
    persist("jump", [title])
  }

  function applyAdd(title) {
    var next = Model.add(root.state, title)
    if (next === root.state) return
    root.state = next
    persist("add", [title])
  }

  function applyPop() {
    var next = Model.pop(root.state)
    if (next === root.state) return
    root.state = next
    persist("pop", [])
  }

  function applyRemove(id) {
    var next = Model.remove(root.state, id)
    if (next === root.state) return
    root.state = next
    persist("remove", [id])
  }

  function applySetCurrent(id) {
    var next = Model.setCurrent(root.state, id)
    if (next === root.state) return
    root.state = next
    persist("set-current", [id])
  }

  function applyReorder(fromIndex, toIndex) {
    var next = Model.reorder(root.state, fromIndex, toIndex)
    if (next === root.state) return
    root.state = next
    persist("reorder", [String(fromIndex), String(toIndex)])
  }

  function applyClearCompleted() {
    var next = Model.clearCompleted(root.state)
    if (next === root.state) return
    root.state = next
    persist("clear-completed", [])
  }

  // ---- state loading --------------------------------------------------

  function loadState(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.tasks)) {
        root.state = Model.emptyQueue()
      } else {
        root.state = parsed
      }
    } catch (e) {
      root.state = Model.emptyQueue()
    }
  }

  property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/youn.yfocus"
  FileView {
    id: queueFile
    path: root.stateDir + "/queue.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
    onFileChanged: reload()
  }

  function decodeFileUrl(url) {
    var p = String(url).replace(/^file:\/\//, "")
    try { return decodeURIComponent(p) } catch (e) { return p }
  }
  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(code) { queueFile.reload() }
  }
  property string bundledBin: decodeFileUrl(Qt.resolvedUrl("bin/yfocus").toString())
  Process {
    id: ensureBinSymlink
    command: ["bash", "-c", "mkdir -p \"$HOME/.local/bin\" && ln -sf \"" + bundledBin + "\" \"$HOME/.local/bin/yfocus\""]
  }
  // Migrate legacy state (yfocus-queue, yfocus) → youn.yfocus (one-shot)
  Process {
    id: legacyMigrate
    command: ["bash", "-c", "base=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy\"; new=\"$base/youn.yfocus/queue.json\"; if [ ! -f \"$new\" ]; then for old in \"$base/yfocus/queue.json\" \"$base/yfocus-queue/queue.json\"; do if [ -f \"$old\" ]; then mkdir -p \"$(dirname \"$new\")\" && cp \"$old\" \"$new\"; break; fi; done; fi; true"]
    onExited: function(code) { queueFile.reload() }
  }
  Component.onCompleted: {
    var bin = Quickshell.env("YFOCUS_BIN")
    if (!bin) {
      bin = decodeFileUrl(Qt.resolvedUrl("bin/yfocus").toString())
    }
    root.executablePath = bin
    ensureStateDir.running = true
    ensureBinSymlink.running = true
    legacyMigrate.running = true
    queueFile.reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-yfocus"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Key catcher wraps EVERYTHING: scrim, prompts, manage view. Keys the
    // focused input doesn't consume bubble up the parent chain and land in
    // the shortcut handler below.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: root.opened && root.mode === "manage"

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (!root.opened || root.mode !== "manage") return

        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_P) {
          root.applyPop()
          event.accepted = true
        } else if (event.key === Qt.Key_N) {
          manageView.focusAddInput()
          event.accepted = true
        } else if (event.key === Qt.Key_Up && !(event.modifiers & Qt.ControlModifier)) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down && !(event.modifiers & Qt.ControlModifier)) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up && (event.modifiers & Qt.ControlModifier)) {
          if (root.selectedIndex > 0) root.applyReorder(root.selectedIndex, root.selectedIndex - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down && (event.modifiers & Qt.ControlModifier)) {
          if (root.selectedIndex < root.queueRows.length - 1) {
            root.applyReorder(root.selectedIndex, root.selectedIndex + 1)
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          // Space is the only promote key. Enter deliberately does nothing
          // here: it belongs to the add input, and binding both meant one
          // Enter press could add a task AND promote a queue row.
          var row = root.queueRows[root.selectedIndex]
          if (row) root.applySetCurrent(row.id)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          // Swallow stray Enters so they can never promote; submitting
          // happens inside the focused input only.
          event.accepted = true
        } else if (event.key === Qt.Key_D && !(event.modifiers & Qt.ShiftModifier)) {
          var victim = root.queueRows[root.selectedIndex]
          if (victim) root.applyRemove(victim.id)
          event.accepted = true
        } else if (event.key === Qt.Key_D && (event.modifiers & Qt.ShiftModifier)) {
          root.applyClearCompleted()
          event.accepted = true
        } else if (event.key === Qt.Key_S) {
          root.showCompleted = !root.showCompleted
          event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
          // Any other printable key starts a new task right away, with
          // the pressed character already in the field.
          manageView.beginCapture(event.text)
          event.accepted = true
        }
      }

      Rectangle {
        anchors.fill: parent
        color: root.scrimColor
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }

      // ---- micro-overlay prompts (permanently mounted per mode) ------

      Loader {
        id: jumpLoader
        active: true
        visible: root.opened && root.mode === "jump"
        anchors.centerIn: parent
        sourceComponent: jumpComponent
      }

      Component {
        id: jumpComponent
        JumpPrompt {
          background: root.background
          foreground: root.foreground
          border: root.borderCol
          fontFamily: root.fontFamily

          onSubmitted: function (title) {
            root.applyJump(title)
            root.close()
          }
          onCancelled: root.close()
        }
      }

      Loader {
        id: addLoader
        active: true
        visible: root.opened && root.mode === "add"
        anchors.centerIn: parent
        sourceComponent: addComponent
      }

      Component {
        id: addComponent
        AddPrompt {
          background: root.background
          foreground: root.foreground
          border: root.borderCol
          fontFamily: root.fontFamily

          onSubmitted: function (title) {
            root.applyAdd(title)
            root.close()
          }
          onCancelled: root.close()
        }
      }

      // ---- manage view -------------------------------------------------

      FocusManageView {
        id: manageView
        anchors.centerIn: parent
        visible: root.opened && root.mode === "manage"
        state: root.state
        queueRows: root.queueRows
        selectedIndex: root.selectedIndex
        showCompleted: root.showCompleted
        background: root.background
        foreground: root.foreground
        border: root.borderCol
        selectedBackground: Color.menu.selectedBackground
        selectedText: Color.menu.selectedText
        fontFamily: root.fontFamily

        onPopRequested: root.applyPop()
        onRemoveRequested: function (id) { root.applyRemove(id) }
        onJumpRequested: function (id) { root.applySetCurrent(id) }
        onAddSubmitted: function (text) { root.applyAdd(text) }
        onReorderRequested: function (fromIndex, toIndex) { root.applyReorder(fromIndex, toIndex) }
        onSelectionChanged: function (index) { root.selectedIndex = index }
        onToggleShowCompleted: root.showCompleted = !root.showCompleted
        onClearCompletedRequested: root.applyClearCompleted()
        onEscapeRequested: keyCatcher.forceActiveFocus()
      }
    }
  }
}
