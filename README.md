<p align="center">
  <img width="128" src="Packaging/AppIcon.png" style="padding:0.5rem;">
</p>

<h1 align="center">panelctl</h1>

A macOS CLI and menu-bar app for OLED blackouts, click-through dimming,
display sleep, display inventory, and experimental DDC brightness control.

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

The menu-bar app adds saved per-display settings, snooze, launch at login,
automatic deferrals, and manual blackout, restore, sleep, and wake controls.

![PanelCtl settings](docs/settings.png)

## Documentation

- [Usage, behavior, and automation](docs/usage.md)
- [Limits and safety](docs/usage.md#limits-and-safety)
- [Development and release packaging](docs/development.md)
- [Selected-display feasibility research](docs/feasibility.md)
