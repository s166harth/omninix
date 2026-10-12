pragma Singleton
import QtQuick

// qs.Commons Style portal for nixmarchy-shell.
//
// Omarchy's Style singleton derives everything from shell.toml typography +
// spacing tokens. This portal pins omarchy's DEFAULTS (base-size 12, spacing
// scale 1.0, monospace) for the keys the installed plugins read (verified by
// grep):
//   Style.space(px) / Style.spaceReal(px), Style.duration(ms)
//   Style.hoverFill, Style.selectedAccentFill, Style.selectionFillFor(...)
//               body,subtitle,title,heading,icon,iconLarge,display,displayLarge}
//   Style.spacing.{xxs,xs,sm,md,lg,xl,xxl,xxxl,huge,rowPaddingX,panelPadding,
//                  popupPadding}
//   Style.bar.sizeHorizontal
//   Style.hoverFill, Style.selectedAccentFill, Style.selectionFillFor(...)
//   State control API used by qs.Ui.BorderSurface / Border.controlSpec():
//   normal/hover/selected/focus{StateColor,BorderAlpha,BorderWidth} + styleOverrides
QtObject {
  id: root

  readonly property int cornerRadius: 0
  // Half of Hyprland's general:gaps_out (upstream default; no hyprctl probe here).
  readonly property int gapsOut: 5

  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property string resolvedFamily: "monospace"
    readonly property string menuFamily: "monospace"
    readonly property int baseSize: 12
    readonly property int caption: 10
    readonly property int bodySmall: 11
    readonly property int body: 12
    readonly property int subtitle: 13
    readonly property int title: 14
    readonly property int heading: 16
    readonly property int icon: 14
    readonly property int iconLarge: 18
    readonly property int display: 24
    readonly property int displayLarge: 28
  }

  // Spacing scale. Upstream derives this from shell.toml; the portal pins the
  // 1.0 default, so spaceReal() is a pass-through and space() still rounds.
  // WidgetButton margins/padding route through spaceReal to keep the door
  // open for a per-user scale later.
  property real spacingScale: 1.0
  property bool spacingScaleWithFont: true
  readonly property real effectiveSpacingScale: spacingScale

  // Animations collapse to 0 rather than being removed, so a Behavior still
  // runs without visibly moving anything. Honoured by WidgetButton.
  property bool reduceMotion: false

  function spaceReal(px) {
    var n = Number(px)
    if (!isFinite(n) || n <= 0) return 0
    return n * root.effectiveSpacingScale
  }

  function duration(ms) {
    return root.reduceMotion ? 0 : ms
  }

  function space(px) {
    var n = root.spaceReal(px)
    if (n <= 0) return 0
    return Math.max(1, Math.round(n))
  }

  readonly property QtObject spacing: QtObject {
    readonly property int hairline: 1
    readonly property int xxs: 2
    readonly property int xs: 3
    readonly property int sm: 4
    readonly property int md: 6
    readonly property int lg: 8
    readonly property int xl: 10
    readonly property int xxl: 12
    readonly property int xxxl: 14
    readonly property int huge: 18
    readonly property int rowPaddingX: 12
    readonly property int panelPadding: 18
    readonly property int popupPadding: 14
  }

  // Bar metrics. iconSlot/iconCanvas/iconSize/iconFont are what WidgetButton
  // and BarIconButton size and align themselves against; the defaults are
  // omarchy's quattro values (bar height 26, 27px slot, 16px canvas).
  readonly property QtObject bar: QtObject {
    readonly property int sizeHorizontal: 26
    readonly property int sizeVertical: 28
    readonly property int iconSlot: 27
    readonly property int iconCanvas: 16
    readonly property int iconFont: 13
    readonly property int iconSize: 12
    readonly property int statusSlot: 21
  }

  // No shell.toml here -> no per-user style overrides. Kept as a real map so
  // Border.controlSpec() and any plugin reading Style.styleOverrides works.
  readonly property var styleOverrides: ({})

  function styleRawNum(key) {
    var v = styleOverrides[key];
    var n = Number(v);
    return isFinite(n) ? n : null;
  }

  function styleNum(key, fallback) {
    var n = styleRawNum(key);
    return n === null ? fallback : n;
  }

  function styleRawAlpha(key) {
    var v = styleOverrides[key];
    if (v === undefined || v === null || String(v).length === 0) return null;
    var n = Number(v);
    return isFinite(n) ? n : null;
  }

  function styleAlpha(key, fallback) {
    var n = styleRawAlpha(key);
    return n === null ? fallback : n;
  }

  // Omarchy defaults (shell/Commons/Style.qml).
  readonly property int normalBorderWidth: Math.max(0, Math.round(styleNum("normal-border-width", 1)))
  readonly property int hoverBorderWidth: Math.max(0, Math.round(styleNum("hover-cursor-border-width", normalBorderWidth)))
  readonly property int selectedBorderWidth: Math.max(0, Math.round(styleNum("selected-border-width", 0)))
  readonly property int focusBorderWidth: Math.max(0, Math.round(styleNum("focus-border-width", hoverBorderWidth)))

  readonly property real hoverFillAlpha: styleAlpha("hover-cursor-fill-alpha", 0.08)
  readonly property real selectedFillAlpha: styleAlpha("selected-fill-alpha", 0.18)
  readonly property real selectionFillAlpha: styleAlpha("selection-fill-alpha", 0.04)
  readonly property real normalBorderAlpha: styleAlpha("normal-border-alpha", 0.4)
  readonly property real hoverBorderAlpha: styleAlpha("hover-cursor-border-alpha", 0.25)
  readonly property real selectedBorderAlpha: styleAlpha("selected-border-alpha", 1.0)
  readonly property real focusBorderAlpha: styleAlpha("focus-border-alpha", hoverBorderAlpha)

  function resolveStateColor(token, foreground, accent, urgent, fallback) {
    var role = String(token === undefined || token === null ? "" : token).replace(/^\s+|\s+$/g, "").toLowerCase();
    if (role === "foreground" || role === "text") return foreground || Color.foreground;
    if (role === "accent") return accent || Color.accent;
    if (role === "urgent") return urgent || Color.urgent;
    if (role === "background") return Color.background;
    if (role.length > 0) return role;
    return fallback;
  }

  function normalStateColor(foreground, accent, urgent) {
    return resolveStateColor(styleOverrides["normal-color"], foreground, accent, urgent, foreground || Color.foreground);
  }

  function hoverStateColor(foreground, accent, urgent) {
    return resolveStateColor(styleOverrides["hover-cursor-color"], foreground, accent, urgent, foreground || Color.foreground);
  }

  function selectedStateColor(foreground, accent, urgent) {
    return resolveStateColor(styleOverrides["selected-color"], foreground, accent, urgent, foreground || Color.foreground);
  }

  function selectionStateColor(foreground, accent, urgent) {
    return resolveStateColor(styleOverrides["selection-color"], foreground, accent, urgent, foreground || Color.foreground);
  }

  function focusStateColor(foreground, accent, urgent) {
    var role = String(styleOverrides["focus-color"] || "").replace(/^\s+|\s+$/g, "").toLowerCase();
    if (role === "hover" || role === "hover-cursor" || role === "inherit")
      return hoverStateColor(foreground, accent, urgent);
    return resolveStateColor(styleOverrides["focus-color"], foreground, accent, urgent, hoverStateColor(foreground, accent, urgent));
  }

  function normalFillFor(foreground, accent, urgent) {
    return Util.alpha(normalStateColor(foreground, accent, urgent), 0.0);
  }

  function hoverFillFor(foreground, accent, urgent) {
    return Util.alpha(hoverStateColor(foreground, accent, urgent), hoverFillAlpha);
  }

  function selectedFillFor(foreground, accent, urgent) {
    return Util.alpha(selectedStateColor(foreground, accent, urgent), selectedFillAlpha);
  }

  function selectionFillFor(foreground, accent, urgent) {
    return Util.alpha(selectionStateColor(foreground, accent, urgent), selectionFillAlpha);
  }

  function focusFillFor(foreground, accent, urgent) {
    return Util.alpha(focusStateColor(foreground, accent, urgent), hoverFillAlpha);
  }

  // Composite helper for the focus > hover > normal priority chain used by
  // form controls (upstream Commons/Style.qml).
  function controlFill(focused, hot, foreground, accent) {
    if (focused) return focusFillFor(foreground, accent);
    if (hot) return hoverFillFor(foreground, accent);
    return normalFillFor(foreground, accent);
  }

  // Omarchy defaults: hover = foreground @ 0.08, selected accent @ 0.18.
  readonly property color hoverFill: Qt.rgba(0xFB / 255, 0xF1 / 255, 0xC7 / 255, 0.08)
  readonly property color selectedAccentFill: Qt.rgba(0xFE / 255, 0x80 / 255, 0x19 / 255, 0.18)
}
