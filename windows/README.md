# Codex Quota Tray for Windows

A Windows notification-area (system tray) version of Codex Quota Tray. It
shows the remaining quota for available usage windows and updates every
15 seconds.

## Run

Double-click `Run-CodexQuotaTray.cmd`. The compact indicator appears in the
lower-right notification area; it may initially be under the `^` overflow
menu. Right-click it for quota details, refresh, session-log access,
start-at-login, and quit.

## Command-line check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaTray.ps1 -Once
```

The app reads local Codex session logs only and uses no network or API key.

