import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "FocusModel.js" as Model



// Bar chip: shows the task you are currently working on. Click opens the
// manage overlay. Reads queue.json via FileView watch; never writes.
BarWidget {
  
  id: root
  moduleName: "youn.yfocus"

  property var state: Model.emptyQueue()
  readonly property var currentTask: Model.getCurrent(state)
  readonly property bool hasTask: !!currentTask
  readonly property int textLimit: 60
  
  function loadState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && parsed.version === 1 && Array.isArray(parsed.tasks)) return parsed
    } catch (e) {}
    return Model.emptyQueue()
  }

  function truncate(text) {
    return text.length > root.textLimit ? text.slice(0, root.textLimit-3) + "..." : text;
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root. The panel lives in
  // another process surface (the overlay plugin), so these forward over IPC.
  readonly property bool opened: false

  function open() { summonManage() }
  function close() { hideManage() }
  function toggle() { toggleManage() }

  function summonManage() {
    Quickshell.execDetached([
      "omarchy-shell", "shell", "summon",
      "youn.yfocus", JSON.stringify({ mode: "manage" })
    ])
  }

  function toggleManage() {
    Quickshell.execDetached([
      "omarchy-shell", "shell", "toggle",
      "youn.yfocus", JSON.stringify({ mode: "manage" })
    ])
  }

  function hideManage() {
    Quickshell.execDetached(["omarchy-shell", "shell", "hide", "youn.yfocus"])
  }

  property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/youn.yfocus"
  FileView {
    id: queueFile
    path: root.stateDir + "/queue.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.state = root.loadState(text())
    onLoadFailed: root.state = Model.emptyQueue()
    onFileChanged: reload()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      if (root.vertical) return root.hasTask ? "▸" : ""
      if (root.hasTask) return "▸ " + truncate(root.currentTask.title)
      return setting("idleLabel", "▸ yfocus")
    }
    tooltipText: root.hasTask ? root.currentTask.title : ""
    dimmed: !root.hasTask

    onPressed: function (b) {
      if (b === Qt.RightButton) {
        // Right click pops from anywhere — no need to open the manager.
        Quickshell.execDetached([root.executablePath(), "pop"])
      } else {
        root.toggleManage()
      }
    }
  }

  function decodeFileUrl(url) {
    var p = String(url).replace(/^file:\/\//, "")
    try { return decodeURIComponent(p) } catch (e) { return p }
  }
  // Bundled CLI — YFOCUS_BIN → bin/yfocus → PATH (like obsidian-daily-qs)
  property string _binPath: ""
  function executablePath() {
    if (root._binPath) return root._binPath
    var override = Quickshell.env("YFOCUS_BIN")
    if (override) { root._binPath = override; return override }
    var base = decodeFileUrl(Qt.resolvedUrl("bin/yfocus").toString())
    root._binPath = base
    return base
  }
  // Ensure state dir and yfocus on PATH (fresh install)
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
    ensureStateDir.running = true
    ensureBinSymlink.running = true
    legacyMigrate.running = true
  }
}
