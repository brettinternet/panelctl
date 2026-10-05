<p align="center">
  <img width="128" src="Packaging/AppIcon.png" style="padding:0.5rem;">
</p>

<h1 align="center">panelctl</h1>

A macOS CLI and menu-bar app for per-display Hide/Show, idle blackout,
click-through dimming, display sleep and experimental monitor controls.

## Install

### CLI with mise

```sh
mise use -g 'github:brettinternet/panelctl[matching=panelctl-cli]'
```

### App or CLI release

Download the universal app or CLI, plus its SHA-256 checksum, from
[GitHub Releases](https://github.com/brettinternet/panelctl/releases). Move
`PanelCtl.app` to `/Applications`, or put `panelctl` somewhere on your `PATH`.

Release artifacts are ad-hoc signed, not Developer ID signed or notarized. If
macOS blocks one, verify its checksum and source, then use **Open Anyway** in
System Settings → Privacy & Security or control-click it and choose **Open**.

### Build the CLI

Requires macOS 13 or newer and Swift 5.9 or newer.

```sh
swift build -c release --product panelctl
mkdir -p ~/.local/bin
install -m 0755 .build/release/panelctl ~/.local/bin/panelctl
```

See [Development](docs/development.md) to build the app or run tests.

## Use

Choose displays by UUID for stable automation, or use a Core Graphics ID or
`index:N` for interactive use.

```sh
panelctl list
panelctl blackout --display DISPLAY_UUID --idle-after 5m --watch
panelctl blackout --display DISPLAY_UUID --mode working --overlay-opacity 60 --timeout 1h
panelctl sleep-displays --keep-system-awake
panelctl wake-displays
```

Run `panelctl help` or `panelctl <command> --help` for all options.

The app's Settings has three tabs: **Displays** for per-display Hide/Show,
**Automation** for idle blackout, dimming and pause rules, and **General** for
launch at login, the menu icon and **Experimental features**.

Hide defaults to **Black out**, keeping the desktop in place until Show. With
Experimental features enabled and consent accepted, a display's **Remove from
desktop** switch makes Hide mirror it onto another display, optionally switching
its monitor input. Neither style powers the monitor off. Show and recovery stay
available when the experimental flag is off.

Use the menu's per-display actions, or copy a command from **Displays → Scripts**
for Stream Deck or Shortcuts. With the app already running:

```sh
panelctl app toggle-hide --display DISPLAY_UUID --json
```

See [Hide and Show](docs/display-hide-ux.md) for eligibility and recovery limits,
and [scripted commands](docs/usage.md#scripted-hide-and-show) for exit codes.

![Displays tab with display tiles and experimental Remove from desktop setup](docs/displays.png)

![Automations blackout specific displays after timeout](docs/automations.png)

*Settings rendered with synthetic displays; not a hardware qualification result.*

## Documentation

- [Usage, behavior, and automation](docs/usage.md)
- [Limits and safety](docs/usage.md#limits)
- [Hide and Show](docs/display-hide-ux.md)
- [DDC input select](docs/ddc-input.md), [mirroring](docs/display-mirroring.md), and [away/back handoff](docs/display-handoff.md)
- [Display recovery](docs/display-recovery.md)
- [Private display disable](docs/display-disable.md)
- [Selected-display feasibility research](docs/feasibility.md)
- [Development and release packaging](docs/development.md)
