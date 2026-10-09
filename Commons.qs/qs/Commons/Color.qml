pragma Singleton
import QtQuick

// qs.Commons Color portal for nixmarchy-shell.
//
// Omarchy's own Color singleton is theme-reactive (shell.toml -> shellValues)
// and exposes ~30 keys. This portal covers exactly the keys the plugins read
// (verified by grep over the installed plugin sources):
//   Color.{accent,urgent,foreground,background,muted}
//   Color.bar.{background,text,active}
//   Color.popups.{background,text,border}
//   Color.menu.{background,text,border,scrim,selectedBackground,selectedText}
// Values follow the nixmarchy shell theme (Gruvbox, same as the local
// Commons module), NOT Omarchy's defaults — plugins only use them for
// HUD/panel chrome, never for theme fidelity.
QtObject {
  id: root

  readonly property color accent: "#FE8019"
  readonly property color urgent: "#CC241D"
  readonly property color foreground: "#FBF1C7"
  readonly property color background: "#282828"
  readonly property color muted: "#928374"

  readonly property QtObject bar: QtObject {
    readonly property color background: root.background
    readonly property color text: root.foreground
    readonly property color active: root.urgent
  }

  readonly property QtObject popups: QtObject {
    readonly property color background: "#282828"
    readonly property color text: "#FBF1C7"
    readonly property color border: "#FE8019"
  }

  // Omarchy menu surface tokens. Upstream derives these with composed()/pick()
  // over shellValues + palette roles; here they resolve to the same results at
  // Omarchy's DEFAULT alphas (menu bg @1.0, border @ foreground, scrim @0.5 of
  // background, selected bg @ foreground 0.08, selected text @ accent).
  readonly property QtObject menu: QtObject {
    readonly property color background: root.background
    readonly property color text: root.foreground
    readonly property color border: root.foreground
    readonly property color scrim: Qt.rgba(0x28 / 255, 0x28 / 255, 0x28 / 255, 0.5)
    readonly property color selectedBackground: Qt.rgba(0xFB / 255, 0xF1 / 255, 0xC7 / 255, 0.08)
    readonly property color selectedText: root.accent
    readonly property color selectedBorder: Qt.rgba(0xFB / 255, 0xF1 / 255, 0xC7 / 255, 0.0)
  }
}
