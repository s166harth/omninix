pragma Singleton
import QtQuick
import Quickshell

// qs.Commons Util portal: pure helpers plugins may call unqualified.
// Covers the subset the target plugins touch: alpha/fileUrl/clamp plus the
// process helpers (shellQuote/execDetached/execArgv) evindor.keystroke builds
// its actions from. The layout normalizers remain host-side bash in
// nixmarchy/nixmarchy-ipc.
QtObject {
  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function clampAlpha(value) {
    return clamp(Number(value), 0, 1);
  }

  function alpha(c, opacity) {
    var col = String(c);
    // Qt.rgba passthrough for color values; strings resolve via Qt.tint.
    try {
      var cc = Qt.color(col);
      return Qt.rgba(cc.r, cc.g, cc.b, clampAlpha(opacity));
    } catch (e) {
      return c;
    }
  }

  function fileUrl(path) {
    return "file://" + path;
  }

  // Single-quote a string for bash. Handles embedded quotes by closing,
  // escaping, and re-opening the literal. Mirrors upstream Commons/Util.qml.
  function shellQuote(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'";
  }

  function execDetached(command) {
    Quickshell.execDetached(["bash", "-lc", command]);
  }

  // Run an argv vector without a shell interpreting it: the constant
  // `exec "$@"` keeps args in positional parameters, so untrusted data stays
  // literal. The login shell preserves the GUI PATH/session env.
  function execArgv(argv) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv));
  }
}
