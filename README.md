# Herdr Codex Recap (Windows)

A manual, cached Codex recap popup for the Herdr app on Windows, including Codex conversations in connected Linux machines.

This mod was informed by [mrolafsson/herdr-recap](https://github.com/mrolafsson/herdr-recap) at commit `b2e25a779ad1b0260e3dcce3e39ee1974ad01382`, especially its Codex session lookup, ephemeral fork prompt, and transcript stamp cache. The upstream Herdr app mod currently targets Claude Code and macOS/Linux. This Windows Codex mod has its own app UI and PowerShell backend. The upstream project is MIT licensed; its copyright and license are retained in `LICENSE`.

## Behavior

- Opening the popup, switching agents, and polling only inspect local Codex sessions and read cached recaps. They do not invoke the Codex CLI.
- Pressing an agent card's refresh icon checks its cache. A fresh cache returns without model use. A missing or stale cache starts one `codex exec fork --ephemeral` request with a read-only sandbox.
- Each card shows its coding-agent tag and the local time of its cached recap. A green dot means the conversation changed after that recap was made.
- Reopening the popup shows a matching local snapshot immediately. Background checks use a validated process-to-session mapping to avoid repeated full process and transcript scans.
- Cache entries are keyed by Codex session ID, language, transcript size, and transcript modification time. A per-session mutex prevents concurrent duplicate generation.
- The old recap remains visible when stale. Session lookup refuses ambiguous matches rather than showing another session's recap.
- No automatic title suggestions are made.

## Install

Prerequisites: Windows, Herdr app, PowerShell 7 (`pwsh`), and Codex CLI on `PATH`.

Run `./install.ps1`. It copies `mod/` to `~/.config/herdr-app/mods/recap-codex/`, backs up `keys.json`, and binds `ctrl-alt-r` to the new popup. It leaves other mods installed. You can also open the popup from Herdr's command palette with `mod.open:recap-codex`.

For local Windows sessions, the mod matches the Codex process beneath the Herdr terminal to session metadata using process start time and working directory. For a connected Linux machine, it uses Herdr's foreground Codex process ID and reads that machine's own `~/.codex/sessions/` metadata. Explicit `codex resume <session-id>` is supported. If the match is ambiguous, no recap is generated. Sessions resumed with `--last` may need an explicit ID to be identified.

Remote support needs Python 3.9 or newer and Codex CLI on the Linux machine. Herdr sends the bundled `remote.py` code through its remote command channel when needed; there is no separate manual installation on each machine. Inspecting remote sessions only reads metadata and cached summaries. Pressing refresh on a stale remote card starts an independent, read-only `codex exec fork --ephemeral` process in a temporary Herdr Core background terminal on that machine. The terminal removes itself after completion. Its cache stays under `~/.cache/herdr-recap-codex/`; only summary text and status return to the Windows interface. Remote disconnects are shown on the card. Other remote operating systems are not yet supported.

Local recaps are stored under `%LOCALAPPDATA%/HerdrRecapCodex/recaps/`. The repo contains no transcripts, cache, credentials, or personal Herdr settings.

## Verify

Run `herdr-app check ~/.config/herdr-app/mods/recap-codex` and open the popup in the live app. A connected Linux terminal with Codex in the foreground should appear with its machine name. Press its refresh icon once to create a remote cache; pressing it again without new conversation activity should reuse that cache. `test-cache.ps1` uses a fake Codex command to verify local cache reuse and invalidation without model use.
