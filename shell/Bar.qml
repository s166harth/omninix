import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// nixmarchy-shell bar host: the surface that mounts `bar` and `bar-widget`
// plugin kinds (roadmap M5, minimal form).
//
// Omarchy's own bar is a large themed shell (indicators, notch cutouts, centre
// reveal, per-monitor models). This is the smallest thing that satisfies the
// contract a bar widget is written against:
//   - a top-anchored layer-shell surface that reserves exclusive zone so
//     tiled windows start below it,
//   - left / center / right sections, the section names `barWidget
//     .defaultSection` uses,
//   - a PluginBarApi facade injected as each widget's `bar` property, with
//     its private callbacks wired to something real: tooltips render inside
//     the bar, `run()` executes, `moduleWidgets()` answers from the live
//     registry, `requestPopout`/`releasePopout` track one open popup.
//
// Deliberately absent vs upstream: indicators, notch, centre reveal,
// per-monitor surfaces, widget settings UI. Anything a widget calls that is
// not implemented here is a no-op on the facade rather than an error, so a
// widget degrades instead of failing to mount.
PanelWindow {
  id: win

  // Per-plugin `shell` facade builder, injected by the host. A bar widget
  // reaches its own service through bar.shell.serviceFor(<its own id>), so
  // the facade must be built per plugin id rather than shared.
  required property var shellFacadeFor

  readonly property int barSize: Style.bar.sizeHorizontal
  readonly property string position: "top"
  readonly property bool vertical: false
  readonly property bool barHidden: false
  readonly property string fontFamily: Style.font.family
  readonly property color barForeground: Color.foreground
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: Color.urgent
  readonly property bool foregroundAnimationEnabled: true

  // id -> { instance, section, moduleName }
  property var slots: ({})
  property var openPopouts: []

  anchors { top: true; left: true; right: true }
  // NB: the fill reads `surfaceFill`, not a property named `background`.
  // PanelWindow already owns `color`; a binding that mentions it while also
  // declaring its own `color` resolves against the shadowed name and paints
  // white (verified: win.color -> "#ffffff" while Color.background -> "#282828").
  readonly property color surfaceFill: Color.background
  readonly property color surfaceText: Color.foreground
  color: Qt.rgba(surfaceFill.r, surfaceFill.g, surfaceFill.b, 0.92)
  // Hard height, not implicitHeight: the widget rows sit inside a layout Item
  // that fills the window, so an implicit height let the content Item's own
  // implicit size grow the surface (observed h=100 instead of 26) and pushed
  // the 26px-tall widget rows to the bottom edge of it.
  height: barSize
  // ExclusionMode has no Reserve member in quickshell 0.3.0; Auto is the
  // reserving mode there (Ignore / Auto).
  exclusionMode: ExclusionMode.Auto
  // Quickshell 0.3.0 does not expose a PanelWindow child of ShellRoot as a
  // property on the parent (`root.hostBar` is undefined even though the
  // surface maps), so the host receives the instance through this signal and
  // keeps it in its own property.
  signal barReady(var bar)
  WlrLayershell.namespace: "nixmarchy-bar"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { item: rootContent }

  Component.onCompleted: {
    // The facade's private hooks. Everything a widget can ask the bar to do
    // resolves here; the ones this minimal bar does not implement are left
    // null and short-circuit inside PluginBarApi's own guards.
    api._showTooltip = function(target, text) { tooltip.show(target, text) }
    api._hideTooltip = function(target) { tooltip.hide() }
    api._run = function(command) { Util.execDetached(command) }
    api._moduleWidgets = function(moduleName) { return widgetsFor(moduleName) }
    api._requestPopout = function(owner) {
      if (openPopouts.indexOf(owner) === -1) openPopouts.push(owner)
    }
    api._releasePopout = function(owner) {
      var i = openPopouts.indexOf(owner)
      if (i !== -1) openPopouts.splice(i, 1)
    }
    api._switchPanelFrom = function(owner, direction) { return false }
    api._registerClickTarget = function(target) { clickTargets.push(target) }
    api._unregisterClickTarget = function(target) {
      var i = clickTargets.indexOf(target)
      if (i !== -1) clickTargets.splice(i, 1)
    }
    api._setCenterHoverRevealSuppressed = function(value) { centerRevealSuppressed = value }
    win.barReady(win)
  }

  property var clickTargets: []
  property bool centerRevealSuppressed: false

  // One facade instance per bar surface, handed to every widget this bar
  // mounts. Widgets treat it as their `bar`.
  PluginBarApi {
    id: api
    pluginId: "nixmarchy-shell"
    moduleName: "nixmarchy-shell"
    shell: win.shellFacadeFor ? win.shellFacadeFor() : null
    foreground: win.foreground
    barForeground: win.barForeground
    background: win.background
    urgent: win.urgent
    fontFamily: win.fontFamily
    position: win.position
    vertical: win.vertical
    barSize: win.barSize
    foregroundAnimationEnabled: win.foregroundAnimationEnabled
    activePopout: win.openPopouts.length > 0 ? win.openPopouts[0] : null
  }

  function widgetsFor(moduleName) {
    var out = []
    for (var id in slots) {
      if (slots[id] && slots[id].moduleName === moduleName && slots[id].instance) {
        out.push(slots[id].instance)
      }
    }
    return out
  }

  // Mount one bar-widget entry point. `id` is the plugin id, `file` its
  // manifest entryPoints.barWidget path, `section` left|center|right.
  function mountWidget(id, file, section, moduleName, manifest, defaults) {
    if (slots[id]) return slots[id].instance
    var comp = Qt.createComponent("file://" + file)
    if (comp.status === Component.Error) {
      console.warn("nixmarchy-shell: bar " + id + ": " + comp.errorString())
      return null
    }
    var settings = {}
    var defs = defaults || {}
    for (var k in defs) settings[k] = defs[k]
    // Point the shared facade at this widget's own plugin for the duration of
    // the mount. Reader's widget resolves bar.shell.serviceFor("clumzeez.reader"),
    // so a facade left on another plugin would route every widget to one
    // plugin's service.
    api.shell = win.shellFacadeFor ? win.shellFacadeFor(id) : null
    api.pluginId = id
    api.moduleName = moduleName || id
    // Only the three properties a BarWidget base declares are injected here.
    // `manifest` / `shell` are NOT set as initial properties: a widget whose
    // root does not declare them (all three real bar widgets) fails the whole
    // createObject with "does not have a property called ...". Widgets that
    // want them read them off `bar`, which carries the same shell facade.
    var inst = comp.createObject(sectionItem(section), {
      bar: api,
      moduleName: moduleName || id,
      settings: settings
    })
    if (!inst) {
      console.warn("nixmarchy-shell: bar " + id + ": createObject failed")
      return null
    }
    slots[id] = { instance: inst, section: section, moduleName: moduleName || id }
    return inst
  }

  function unmountWidget(id) {
    var s = slots[id]
    if (s && s.instance) { try { s.instance.destroy() } catch (e) {} }
    delete slots[id]
  }

  // Human-readable summary of what the bar currently holds, for
  // `nixmarchy-ipc shell bar` and for verifying that a mount landed.
  function summary() {
    var out = [];
    for (var id in slots) {
      var s = slots[id];
      if (!s || !s.instance) continue;
      out.push({
        id: id,
        section: s.section,
        moduleName: s.moduleName,
        visible: !!s.instance.visible,
        width: Math.round(s.instance.width),
        height: Math.round(s.instance.height)
      });
    }
    return JSON.stringify(out);
  }

  // Invoke a function on a mounted bar widget. `shell call <id> <fn>` cannot
  // reach these: a plugin whose manifest lists `service` before `bar-widget`
  // (Reader does) has its headless service as `instance`, so the widget is
  // only addressable here.
  function callWidget(id, fn, argsJson) {
    var s = slots[id];
    if (!s || !s.instance) return ""
    if (typeof s.instance[fn] !== "function") return ""
    var args = []
    try { args = JSON.parse(argsJson || "[]") } catch (e) { args = [] }
    try { return String(s.instance[fn].apply(s.instance, args)) } catch (e) { return "" }
  }

  // Click a mounted bar widget by pressing its clickable child. Widgets wrap
  // their action in a WidgetButton whose triggerPress(button) emits the
  // pressed() signal the plugin handles, so this is the real code path a
  // pointer click takes - the bar cannot be clicked with ydotool on this box.
  // `button` is "left" | "middle" | "right".
  function clickWidget(id, button) {
    var s = slots[id];
    if (!s || !s.instance) return "no such widget"
    var code = button === "right" ? 2 : (button === "middle" ? 4 : 1) // Qt.RightButton / MiddleButton / LeftButton
    var target = findClickable(s.instance)
    if (!target) return "no clickable child"
    target.triggerPress(code)
    return "ok"
  }

  function findClickable(item) {
    if (item && typeof item.triggerPress === "function") return item
    var kids = item && item.children ? item.children : []
    for (var i = 0; i < kids.length; i++) {
      var hit = findClickable(kids[i])
      if (hit) return hit
    }
    return null
  }

  function sectionItem(name) {
    if (name === "center") return centerRow
    if (name === "right") return rightRow
    return leftRow
  }

  // Layout root. Not a Row: a Row refuses anchored children ("Cannot specify
  // left, right, ... anchors for items inside Row"), and the three sections
  // must sit at opposite edges with the centre one truly centred.
  Item {
    id: rootContent
    anchors.fill: parent

    Row {
      id: leftRow
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
    }

    Row {
      id: centerRow
      anchors.centerIn: parent
      spacing: Style.spacing.xs
    }

    Row {
      id: rightRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
    }
  }

  // Tooltip shown under the widget that asked for it. Rendered in-bar: there is
  // no separate popup surface in this minimal host.
  Item {
    id: tooltip
    anchors { top: parent.bottom; left: parent.left; right: parent.right }
    height: visible ? label.implicitHeight + 10 : 0
    z: 10
    visible: false

    property var target: null
    // NB: named `message`, not `text` — a `text` property here would shadow the
    // inner Text's own `text`, and `tooltip.text = ...` is then an assignment
    // to a read-only binding ("left-hand side of assignment operator is not
    // an lvalue"), which took the whole host down on first hover.
    property string message: ""

    function show(t, value) {
      target = t || null
      message = String(value || "")
      visible = message.length > 0
    }

    function hide() {
      target = null
      message = ""
      visible = false
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.95)
      border.width: Style.normalBorderWidth
      border.color: Color.accent
      radius: Style.cornerRadius
    }

    Text {
      id: label
      anchors.centerIn: parent
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: win.fontFamily
      font.pixelSize: Style.font.caption
      text: tooltip.message
    }
  }

  // Label identifying this surface as the plugin bar, so a screenshot shows
  // where the widgets landed.
  Text {
    anchors.right: parent.right
    anchors.rightMargin: Style.gapsOut
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: Color.muted
    font.family: win.fontFamily
    font.pixelSize: Style.font.caption
    text: "nixmarchy"
  }
}