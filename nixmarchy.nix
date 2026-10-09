# Plugin divergence log (local-only commits in
# ~/.local/state/nixmarchy/plugins/<id>/, NEVER pushed upstream; `nixmarchy
# update` deliberately refuses fast-forward on diverged checkouts):
#   - io.github.jacklapinza.omadex @5a947f9 (upstream 4084e50):
#     Quickshell 0.3.0 / Qt 6.11 rejects bare child elements under a
#     QtObject root ("Cannot assign to non-existent default property"), so
#     ApiRequest.qml's `Process {}` and ApiClient.qml's `Component {}`
#     are held in property declarations (`property Process process: ...`).
#     Upstream targets Omarchy's newer Qt where bare children parse.
#     Portal deps (tracked here): Commons.qs/qs/Ui/{UiDummy.qml (Ui.Panel
#     port of omacom/omarchy@quattro shell/Ui/Panel.qml + PanelController,
#     minus ShellIpc which 0.3.0 lacks), PanelKeyCatcher.qml},
#     Style.font.{family,bodySmall,display} keys.
#   - fkcodes.key-promoter @21c2b71 (upstream 21c2b71, one local commit on top):
#     upstream arms on the Omarchy menu layer (`closelayer omarchy-menu`) and
#     gates window promotion on launcher evidence from a `gtk-launch` systemd
#     scope (created by `uwsm-app -- gtk-launch`, i.e. Omarchy's app list).
#     This host's menu is rofi (layer namespace `rofi`, verified via the
#     Hyprland event socket: openlayer/closelayer>>rofi) and rofi spawns
#     entries directly (`run-command = {cmd}`), so no such scope exists.
#     Local patch: arm on `closelayer rofi` too, and set launcherAt at that
#     moment (we just watched the menu close). Activate with
#     `nixmarchy relink fkcodes.key-promoter` - `update` refuses to
#     fast-forward a diverged checkout.
#   - evindor.keystroke @c9cf1a0 (upstream c9cf1a0, NO local commit): the
#     palette loads unmodified once the portal carries its deps. Portal deps
#     (tracked here): Commons.qs/qs/Ui/PointerMoveGate.qml (plain QtObject,
#     ported verbatim from omacom/omarchy@quattro shell/Ui/), Style.font.heading
#     + Style.controlFill(), and Util.{shellQuote,execDetached,execArgv}
#     (the latter two via Quickshell.execDetached). Without PointerMoveGate the
#     `menu` entry point fails to create ("PointerMoveGate is not a type") and
#     the palette never mounts; the Style/Util gaps then flood
#     "Unable to assign [undefined] to int" / ReferenceError warnings.
#     Its Applications provider reads shell.appLibrary (host-injected). The
#     host now owns one: modules/home/nixmarchy/shell/AppLibrary.qml +
#     AppSearch.js (port of omacom/omarchy quattro shell/services/), exposed
#     through shellFacade().appLibrary. Launch uses DesktopEntry.execute()
#     (uwsm-app/gtk-launch absent here); remove()/launch-OSD are dropped.
# Service capability routing (per-host, NOT in the flake):
#   ~/.local/state/nixmarchy/services.json maps the first-party service ids
#   plugins ask for (`shell.serviceFor("omarchy.<name>")` /
#   `shell.firstPartyServiceFor(...)`) to a provider this host implements:
#     { "omarchy.<name>": { "provider": "builtin", "impl": "<key>" } }
#     { "omarchy.<name>": { "provider": "stub", ...static properties... } }
#     { "omarchy.<name>": { "provider": "reject", "reason": "..." } }
#   Unknown id / absent file / builtin without impl => reject proxy with
#   reason "not routed" - plugins degrade on null/enabled:false, so a
#   plugin needing 5 of 10 capabilities and another needing 9 both work
#   against the same table. New capability = one provider impl + one row.

{ pkgs, ... }:
let
  nixmarchy = pkgs.writeShellApplication {
    name = "nixmarchy";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      findutils
      git
      gnugrep
      gnused
      jq
      nix
      openssh
    ];
    text = builtins.readFile ./bin/nixmarchy;
  };
  nixmarchy-ipc = pkgs.writeShellApplication {
    name = "nixmarchy-ipc";
    runtimeInputs = with pkgs; [ quickshell ];
    text = builtins.readFile ./bin/nixmarchy-ipc;
  };
  nixmarchy-shell-run = pkgs.writeShellApplication {
    name = "nixmarchy-shell-run";
    runtimeInputs = with pkgs; [ quickshell ];
    text = builtins.replaceStrings [ "@commonsQml@" ] [ "${./Commons.qs}" ] (
      builtins.readFile ./bin/nixmarchy-shell-run
    );
  };

  # Upstream CLI signature shim (-g <glyph> -t <ms> <title> [body]) so plugin
  # helper scripts (e.g. neil.yautja trophies notify) work unmodified.
  omarchy-notification-send = pkgs.writeShellApplication {
    name = "omarchy-notification-send";
    runtimeInputs = with pkgs; [ libnotify ];
    text = builtins.readFile ./bin/omarchy-notification-send;
  };
  nixmarchy-notification-send = pkgs.writeShellApplication {
    name = "nixmarchy-notification-send";
    runtimeInputs = with pkgs; [ libnotify ];
    text = builtins.readFile ./bin/nixmarchy-notification-send;
  };

  # Omarchy's keybinding resolver, reimplemented against `hyprctl -j binds`.
  # Plugins source it for the record exporter (fkcodes.key-promoter's
  # bin/keybinds exits 1 without it, leaving the plugin with zero bindings).
  # Omarchy's interactive SUPER + K menu is deliberately NOT implemented.
  omarchy-menu-keybindings = pkgs.writeShellApplication {
    name = "omarchy-menu-keybindings";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      gnused
      jq
      hyprland
      gawk
    ];
    text = builtins.readFile ./bin/omarchy-menu-keybindings;
  };
in
{
  # Plugin CLIs (e.g. ~/.local/bin/yautja) live outside the Nix store; put
  # the dir on PATH for interactive shells.
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.packages = [
    nixmarchy
    nixmarchy-ipc
    nixmarchy-notification-send
    omarchy-notification-send
    omarchy-menu-keybindings
    nixmarchy-shell-run
    pkgs.quickshell
    # Plugin runtime dep: fkcodes.key-promoter watches app launches with
    # inotifywait; without it the watcher dies and promotion falls back to a
    # bare time window.
    pkgs.inotify-tools
  ];

  # nixmarchy-shell host config, run as `qs -c nixmarchy-shell` or via the
  # launcher. Plugin checkouts land in ~/.config/nixmarchy/plugins/<id>;
  # the host launcher passes -I <Commons.qs portal dir> so plugin
  # `import qs.Commons` resolves to the portal, never the user's Commons.
  xdg.configFile."nixmarchy-shell/shell.qml".source = ./shell/shell.qml;
  xdg.configFile."nixmarchy-shell/Cat.qml".source = ./shell/Cat.qml;
  xdg.configFile."nixmarchy-shell/AppLibrary.qml".source = ./shell/AppLibrary.qml;
  xdg.configFile."nixmarchy-shell/AppSearch.js".source = ./shell/AppSearch.js;
  xdg.configFile."nixmarchy/Commons.qs".source = ./Commons.qs;
}
