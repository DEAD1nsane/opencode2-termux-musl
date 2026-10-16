# [DEAD1nsane/opencode2-termux-musl](https://github.com/DEAD1nsane/opencode2-termux-musl)

The v1 repo is archived. v2 is the official stable line — Node.js, ships via npm (`@opencode/cli`). This uses upstream's `@opencode/cli-linux-arm64-musl` + Alpine musl loader + `patchelf`, installed as plain `opencode`. Official installer misdetects Termux as glibc, this doesn't.

---

# 1-copy install

**Please install from the Copy-Ready link, it's much easier especially if using mobile reddit app (don't copy-paste from the codeblocks below, they're for display)**:

# ⚠️ Before-Install (required):

- install the app **[Termux:API F-Droid Download](https://f-droid.org/repo/com.termux.api_1002.apk)**, then in Termux:

```sh
pkg update && pkg upgrade -y
pkg install termux-api -y
termux-battery-status
```

The `termux-battery-status` line triggers the permission prompt / confirms the bridge works. Skip it and the installer below will refuse with these same steps.

```sh
pkg install curl tar python git
```

# Step 1 — install everything:

## [Copy-Ready Full Install here](https://gist.github.com/DEAD1nsane/9b37cba090602f473200fad8b1002e6c)

```sh
curl -sL https://gist.githubusercontent.com/DEAD1nsane/9b37cba090602f473200fad8b1002e6c/raw/all-in-one.sh | sh
opencode --version
opencode run "say hi"
```

☝🏼**Use the gist above — it pulls/updates the repo, runs `install.sh`, copies all 8 themes (dark + light, 16 files) to `~/.config/opencode/themes/`, and schedules auto-update (job 7802, every 6h, applies via `--yes` path, log `~/.opencode-auto-update.log`). Day/night theme-sync is NOT included — opt-in below.**

---

# Update check (only checks, downloads nothing unless `--yes`)

```sh
./scripts/check-update.sh              # check only, Termux notification if behind
./scripts/check-update.sh --status     # last-run status + periodic-job state
./scripts/check-update.sh --yes        # update now: version pinned, staged, smoke-tested
./scripts/check-update.sh --rollback   # restore last-known-good binary if upstream ships a bad build
```

The gist already scheduled unattended updates. Manual re-schedule if needed:

```sh
termux-job-scheduler --job-id 7802 --period-ms 21600000 --network any --persisted true -s "$HOME/GitHub/opencode2-termux-musl/scripts/auto-update.sh"
```

---

# Bonus 16 custom Themes:

- 8 true-black AMOLED & 8 light themes
  ^(Included in the all-in-one gist. Manual copy if needed 👇🏼)

```sh
cp themes/*.json ~/.config/opencode/themes/
```

→ Pick with `/themes`. Native v2 format.

^(**⚠️ Attached previews are rendered from the live theme JSONs [dark + light] by opencode2 with the same tree-sitter highlighting the TUI uses, set in Maple Mono NF — tab strip and a shared realistic Python sample on all 16, so what you see is what the TUI draws.**)

---

# 🌗 Optional auto day/night — NOT in all-in-one:

^(**This is so opencode will switch between dark and light themes based on your time, if the color mode is set to system in /settings**)

## [Copy-Ready Day/Night here](https://gist.github.com/DEAD1nsane/54621517a114c8e2a71d61ced990ca22)

```sh
curl -sL https://gist.githubusercontent.com/DEAD1nsane/54621517a114c8e2a71d61ced990ca22/raw/theme-daynight.sh | sh
```

Skip it and nothing changes. `system` follows terminal bg, never Android. Opt-in sets `light` 07:00-19:00, `dark` otherwise, 15-min job 7803, revert with `--system`.

---

# 🪧 Optional notifications (Discord-style, NOT in all-in-one):

## [Copy-Ready Notify Setup here](https://gist.github.com/DEAD1nsane/fa678446d982fed3f01808b09c1bcd8d)

Mute if viewing this session, banner if in another Termux session, loud if away 5min. `buzz` + `notify-decide` + zsh hook + opencode plugin. Same Copy-Ready format — install from the GitHub gist link above.

---

# ❔ Why it needs shims:

Official installer misdetects Termux as glibc (no `/etc/alpine-release`, no `ldd`). This always takes musl. Musl DNS reads `/etc/resolv.conf`, Node's c-ares does raw UDP DNS which Android blocks — `libresolvefix.so` doesn't help Node. Fixed via local Python proxy on `127.0.0.1:8080`, auto-started by wrapper (`HTTP(S)_PROXY` + `NO_PROXY=localhost,127.0.0.1,::1`). Ollama on `localhost:11434` bypasses proxy and works.

---

# ❌ What's not working:

Formatter needs one-time `sh scripts/enable-formatter.sh` (prettier shebang can't spawn, silently skips without it), no PTY lib yet, ~100-200ms proxy overhead. Standalone is default; shared via `opencode-shared serve --service`. Migrating from v1: `sh install.sh` then `sh scripts/remove-v1.sh` (~350MB freed, sessions/config kept).

---

# 📱 Tested On:

Pixel 10, Android 17, Termux 0.119, OpenCode v2.0.30 as `opencode`: TUI, `run`, shared-service, MCP (Railway/GitHub/Upstash/Chrome DevTools), v2 plugin API.

### Please any comments below 👇🏼
