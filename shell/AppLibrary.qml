import QtQuick
import Quickshell
import "AppSearch.js" as AppSearch

// nixmarchy host AppLibrary: the `shell.appLibrary` surface Omarchy injects
// into plugins (DesktopEntries-backed app list + icon lookup + launch). Ported
// from omacom/omarchy quattro shell/services/AppLibrary.qml, minus the
// Omarchy-only pieces that do not exist here:
//   - launch: entry.execute() (Quickshell's own desktop-entry launcher) instead
//     of `uwsm-app -- gtk-launch` (uwsm is absent on this host).
//   - no launch OSD (omarchy-shell osd absent) and no entry removal
//     (omarchy-remove-launcher-entry absent); remove() is a no-op.
//   - no icon-index rescan process: Quickshell.iconPath covers themed icons.
// Exposed to every plugin through shellFacade().appLibrary so evindor.keystroke
// resolves its applications without editing the plugin checkout.
QtObject {
  id: root

  // Emitted whenever the visible application set may have changed; consumers
  // (keystroke) drop caches and requery on it.
  signal appsChanged()

  // Empty by design (no Omarchy launcher.hides / hidden-entries.sh here).
  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})

  readonly property var entries: DesktopEntries.applications.values || []

  // DesktopEntries.applications is a notifiable model; re-emit as appsChanged.
  // Held in a property because Qt 6.11 rejects bare children under a QtObject.
  property Connections desktopConn: Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.appsChanged() }
  }

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  function isHiddenEntry(entry) {
    var id = String((entry && entry.id) || "")
    return root.configuredHiddenEntryIds[id] === true || root.desktopHiddenEntryIds[id] === true
  }

  function sortedEntries(query) {
    return AppSearch.sortedEntries(root.entries, query, function(entry) { return root.isHiddenEntry(entry) })
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    if (themed && themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  // Kept for interface parity; icons resolve lazily through iconSource().
  function refreshIcons() {}

  function entryFor(id) {
    var values = root.entries
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].id) === id) return values[i]
    }
    return null
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    var entry = root.entryFor(id)
    if (entry) {
      try { entry.execute(); return } catch (e) { console.warn("nixmarchy appLibrary: execute failed: " + e) }
    }
    // Fallback: gtk-launch resolves a desktop id with or without the suffix.
    Quickshell.execDetached(["gtk-launch", id + ".desktop"])
  }

  // Omarchy removes a launcher entry file; that mechanism does not exist here.
  function remove(desktopId, name) {}
}
