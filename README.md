# Codex Quota Tray

**v1.0** 鈥?a local, privacy-first quota indicator for Codex. It reads local
Codex session logs only; no network access or API key is needed.

| Platform | App | Install / run |
| --- | --- | --- |
| Windows | Notification-area tray app | See [windows/README.md](windows/README.md) |
| macOS | Native menu-bar app | See below |

## macOS

Requires macOS 13 or later on Apple Silicon. To build it, install the Xcode
command-line tools, then run:

```bash
./build.sh
./run.sh
```

The application bundle is created at `build/CodexQuotaMenuBar.app`. To create a
distributable archive, run `./package_release.sh`; it produces
`dist/CodexQuotaMenuBar-1.0.0-macOS.zip`.

## Privacy

Both apps work entirely offline and read only these local Codex logs:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/*.jsonl`

## Author

[**PlutaB**](https://github.com/PlutaB)

Adapted from [BowenZZZZZZZ/codex-quota-menubar](https://github.com/BowenZZZZZZZ/codex-quota-menubar)

## License

Copyright 漏 2026 PlutaB.

Licensed under the [MIT License](https://github.com/PlutaB/codex-quota-menubar/blob/main/LICENSE).

