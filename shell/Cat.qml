import QtQuick
import Quickshell
import Quickshell.Io

// One-shot synchronous file read. Set filePath, call go(), receive done(text).
// "" when the file is missing/unreadable. Used for host state files
// (shell.json, priority/installedAt sidecars).
Item {
  id: root
  property string filePath: ""
  signal done(string text)

  Process {
    id: reader
    running: false
    command: ["cat", "--", root.filePath]
    stdout: StdioCollector {
      onStreamFinished: root.done(this.text)
    }
    onExited: function(code) {
      if (code !== 0) root.done("");
    }
  }

  function go() { reader.running = true }
}
