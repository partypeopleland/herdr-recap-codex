# Herdr Codex Recap (Windows)

A manual, cached Codex recap popup for the Herdr app on Windows.

This mod was informed by [mrolafsson/herdr-recap](https://github.com/mrolafsson/herdr-recap) at commit `b2e25a779ad1b0260e3dcce3e39ee1974ad01382`, especially its Codex session lookup, ephemeral fork prompt, and transcript stamp cache. The upstream Herdr app mod currently targets Claude Code and macOS/Linux. This Windows Codex mod has its own app UI and PowerShell backend. The upstream project is MIT licensed; its copyright and license are retained in `LICENSE`.

## Behavior

- Opening the popup, switching agents, and polling only inspect local Codex sessions and read cached recaps. They do not invoke the Codex CLI.
- Pressing an agent card's refresh icon checks its cache. A fresh cache returns without model use. A missing or stale cache starts one `codex exec fork --ephemeral` request with a read-only sandbox.
- Each card shows its coding-agent tag and the local time of its cached recap. A green dot means the conversation changed after that recap was made.
- Cache entries are keyed by Codex session ID, language, transcript size, and transcript modification time. A per-session mutex prevents concurrent duplicate generation.
- The old recap remains visible when stale. Session lookup refuses ambiguous matches rather than showing another session's recap.
- No automatic title suggestions are made.

## Install

Prerequisites: Windows, Herdr app, PowerShell 7 (`pwsh`), and Codex CLI on `PATH`.

Run `./install.ps1`. It copies `mod/` to `~/.config/herdr-app/mods/recap-codex/`, backs up `keys.json`, and binds `ctrl-alt-r` to the new popup. It leaves other mods installed. You can also open the popup from Herdr's command palette with `mod.open:recap-codex`.

The mod currently handles Codex agents on the local Windows machine. For new sessions it matches the Codex process beneath the Herdr terminal to the session metadata using the process start time and working directory. Explicit `codex resume <session-id>` is supported. If the match is ambiguous, no recap is generated. Sessions resumed with `--last` may need an explicit ID to be identified.

Generated recaps are stored locally under `%LOCALAPPDATA%/HerdrRecapCodex/recaps/`. The repo contains no transcripts, cache, credentials, or personal Herdr settings.

## Verify

Run `herdr-app check ~/.config/herdr-app/mods/recap-codex` and open the popup in the live app. `test-cache.ps1` uses a fake Codex command to verify cache reuse and invalidation without model use.
