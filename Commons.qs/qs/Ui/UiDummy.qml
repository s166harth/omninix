import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Ui.Panel base ported from omacom/omarchy@quattro shell/Ui/Panel.qml +
// shell/Ui/PanelController.qml (MIT). Omadex Panel.qml inherits Ui.Panel as
// its root and owns its content; this base owns the shared open/close
// lifecycle (PanelController state + ShellIpc wiring) exactly like upstream.
// Verified against omadex usage: bar/moduleName/settings/ipcTarget/
// manageIpc/controller/opened/open/close/toggle/setting props + children
// land on the inner `panel` Item, NOT a window (upstream Panel is a plain
// Item; FloatingWindow/WindowAnchor live in the plugin's own Panel.qml).
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool manageIpc: true
  property alias controller: panelController
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false

  readonly property bool opened: panelController.open
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground

  function open() { panelController.show() }
  function close() { panelController.hide() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(root, direction)
    return false
  }

  // Read a single value from this panel's inline shell.json entry, with a
  // fallback for missing/null values. Matches BarWidget.setting().
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  QtObject {
    id: panelController
    property bool open: false
    function toggle() { open = !open }
    function show() { if (!open) open = true }
    function hide() { open = false }
  }

  // nixmarchy note: upstream's ShellIpc (omarchy's qs extension) does not
  // exist in quickshell 0.3.0; the host drives open()/close() directly via
  // loadPlugin's createObject, so the IPC block is intentionally omitted.
}
