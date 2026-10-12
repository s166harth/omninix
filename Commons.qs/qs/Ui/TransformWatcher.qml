import QtQuick

// Re-evaluates the item chain from `a` down to `b` whenever either moves or
// resizes, and exposes the accumulated transform as a readable property.
//
// KeyboardPanel uses this to make its card-position binding reactive:
// `anchorItem.mapToItem(window.contentItem, 0, 0)` is a one-shot read, so
// without a watcher the panel would never follow a widget that moves inside
// the bar. Touching `transform` in a binding is what re-runs it.
//
// nixmarchy: KeyboardPanel.qml references TransformWatcher, but quickshell
// 0.3.0 ships no such type and omacom/omarchy@quattro defines it nowhere in
// shell/Ui or shell/Commons — it is a private type from Omarchy's own bar
// tree that never made it into the quattro plugin surface. This is a
// minimal, dependency-free equivalent.
Item {
  id: root

  // The ancestor item (typically a bar's contentItem) and the descendant to
  // track. Either may be null before layout settles.
  property Item a: null
  property Item b: null

  // Accumulated translation from a down to b, in a's coordinate space. Zero
  // when either end is missing. Named `trackedOffset` rather than
  // `transform`, which Item declares FINAL.
  readonly property point trackedOffset: {
    // Reading width/height keeps this binding dependent on both items'
    // geometry, which is what fires when a bar lays out or a slot resizes.
    if (!a || !b) return Qt.point(0, 0);
    var aw = a.width;
    var ah = a.height;
    var bw = b.width;
    var bh = b.height;
    if (aw <= 0 || ah <= 0) return Qt.point(0, 0);
    var p = b.mapToItem(a, 0, 0);
    return Qt.point(p.x, p.y);
  }

  // Size of the tracked item, for callers that need the parallel axis.
  readonly property real trackedWidth: b ? b.width : 0
  readonly property real trackedHeight: b ? b.height : 0
}