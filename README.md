# opencode2-termux-musl

Run **OpenCode v2** on Termux (Android) as a native musl binary — installed as plain `opencode`, exactly like on every other platform.

OpenCode v2 is the official stable line: Node.js runtime, ships via npm (`@opencode/cli`), with matching `v2.x` GitHub tags. Upstream docs: [opencode.ai/v2](https://opencode.ai/v2/docs/).

This repo replaces [`opencode-termux-musl`](https://github.com/DEAD1nsane/opencode-termux-musl) (v1 + side-by-side era), which is now archived.

## Why this repo exists

Three Termux/Android problems break the naive install; this repo solves all three:

1. **The official installer misdetects Termux.** No `/etc/alpine-release`, no `ldd` → it thinks glibc and downloads the wrong binary. This repo always takes `@opencode/cli-linux-arm64-musl` from npm and patches the ELF interpreter to Termux's musl loader.
2. **DNS is broken for musl/Node on Android.** Musl's raw UDP path is blocked; Node's c-ares resolver bypasses even the `libresolvefix.so` shim. The wrapper therefore routes outbound HTTPS through a small local Python proxy (`scripts/proxy.py`) on `127.0.0.1:8080`.
3. **Spawning `#!/usr/bin/env node` tools fails.** The musl wrapper swaps `LD_PRELOAD` away from `termux-exec`, so shebangs like prettier's never resolve. `scripts/enable-formatter.sh` fixes the formatter (see below).

## Requirements

- Termux (Android 7.0+ / API 24+, aarch64)
- `curl`, `tar` (installer auto-installs `patchelf` and `clang` if missing)
- `python3` (for the HTTP proxy)
- Internet access to `opencode.ai`, `registry.npmjs.org`, and `dl-cdn.alpinelinux.org`

## Install

```sh
pkg install curl tar python
git clone https://github.com/DEAD1nsane/opencode2-termux-musl.git
cd opencode2-termux-musl
sh install.sh
```

Or one-liner after cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/DEAD1nsane/opencode2-termux-musl/master/install.sh | sh
```

Then verify:

```sh
opencode --version
opencode run "say hi"
```

### What install.sh does

1. Resolves the latest v2 version from `https://opencode.ai/update/api/latest/cli/npm`
2. Downloads `@opencode/cli-linux-arm64-musl` from npm (always musl)
3. Reuses or installs Alpine musl + libstdc++/libgcc + `libresolvefix.so`
4. `patchelf`s the interpreter to `$PREFIX/lib/ld-musl-aarch64.so.1`
5. Installs `$PREFIX/libexec/opencode/opencode-v2-musl.bin` + wrapper `$PREFIX/bin/opencode`
6. Installs `$PREFIX/bin/opencode-shared` (shared-service mode helper)

Useful knobs:

```sh
OPENCODE_VERSION=2.0.21 sh install.sh        # pin a version
OPENCODE_WRAPPER_ONLY=1 sh install.sh        # refresh wrapper only, no download
OPENCODE_TARBALL_PATH=./cli-linux-arm64-musl-2.0.21.tgz sh install.sh  # offline
OPENCODE_STANDALONE=0 sh install.sh          # default to shared-service mode
```

Full details, including migration from v1, are in [docs/INSTALL.md](docs/INSTALL.md).

## Verify

| Check         | Command                                           | Status (2.0.21 on Pixel 10)                           |
| ------------- | ------------------------------------------------- | ----------------------------------------------------- |
| Version       | `opencode --version`                              | `opencode v2.0.21`                                    |
| DNS + API     | `opencode run "Reply with exactly: PONG"`         | works via Python proxy                                |
| Models / auth | `opencode models`, `opencode auth list`           | OpenCode Go key stored                                |
| Themes        | 8 native v2 AMOLED themes in [`themes/`](themes/) | copy + `/themes`                                      |
| Plugins       | v2 format `export default { id, setup }`          | auto-loaded from `~/.config/opencode/plugins/`        |
| MCP           | `opencode.json` `mcp` block                       | Railway / GitHub / Upstash / Chrome DevTools verified |

If `run` times out with `getaddrinfo ETIMEOUT opencode.ai`, the network path is broken — check that the wrapper's proxy env is present and `proxy.py` is running (`pgrep -f proxy.py`).

## Network: why the Python proxy

Node/c-ares on musl does raw UDP DNS, which Android blocks; `libresolvefix.so` (which redirects musl's `resolv.conf` reads to Termux's) does not help Node. The wrapper therefore:

- sets `HTTP(S)_PROXY=http://127.0.0.1:8080` (+ `NO_PROXY=localhost,127.0.0.1,::1`)
- starts `scripts/proxy.py` in the background if it is not already running
- sets `NODE_OPTIONS=--dns-result-order=ipv4first`

The proxy adds ~100–200 ms per request — acceptable for interactive use. Local endpoints (MCP servers on localhost, Ollama) bypass it via `NO_PROXY`.

## Standalone vs shared service

`--standalone` is a per-command flag in v2 (run/serve/web/acp), not a global mode:

- **Default (`OPENCODE_STANDALONE=1`)**: `opencode run …` / `opencode serve …` get `--standalone` injected → private server per invocation. The TUI (`opencode` with no args) attaches to a shared service if one is running.
- **Shared service**: start once with `opencode-shared serve --service` (backgrounded); TUI and `OPENCODE_STANDALONE=0 opencode run …` then attach to it — faster startups, one proxy path. The service picks up proxy env through the wrapper, so start it via `opencode-shared`, not by exec'ing the binary directly.

Both modes are verified on-device; pick whichever feels faster day to day.

## AMOLED themes

Eight true-black (`#000000`) themes in [`themes/`](themes/), all in the **native OpenCode v2 theme format** (explicit `categorical` hues, so agent pills — `Build`, `Plan`, … — keep their intended colors):

```sh
mkdir -p ~/.config/opencode/themes
cp themes/*.json ~/.config/opencode/themes/
```

Then pick one with `/themes` inside OpenCode. The seven accent themes are deliberately restrained — each leans on a single accent color for syntax highlighting on pure black; `8-rainbow-amoled` is the exception (white chrome, red links, full neon syntax).

| #   | Theme                                              | Accent            | Dark                                                                                                                                                                 | Light                                                                                                                                                                            |
| --- | -------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | [`1-rbw-amoled`](themes/1-rbw-amoled.json)         | Red `#ff2740`     | <a href="docs/screenshots/themes/1-rbw-amoled.png"><img src="docs/screenshots/themes/1-rbw-amoled.png" width="300" alt="1-rbw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/1-rbw-amoled-light.png"><img src="docs/screenshots/themes/1-rbw-amoled-light.png" width="300" alt="1-rbw-amoled light preview"></a>             |
| 2   | [`2-obw-amoled`](themes/2-obw-amoled.json)         | Orange `#FF914A`  | <a href="docs/screenshots/themes/2-obw-amoled.png"><img src="docs/screenshots/themes/2-obw-amoled.png" width="300" alt="2-obw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/2-obw-amoled-light.png"><img src="docs/screenshots/themes/2-obw-amoled-light.png" width="300" alt="2-obw-amoled light preview"></a>             |
| 3   | [`3-ybw-amoled`](themes/3-ybw-amoled.json)         | Yellow `#FFFF4B`  | <a href="docs/screenshots/themes/3-ybw-amoled.png"><img src="docs/screenshots/themes/3-ybw-amoled.png" width="300" alt="3-ybw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/3-ybw-amoled-light.png"><img src="docs/screenshots/themes/3-ybw-amoled-light.png" width="300" alt="3-ybw-amoled light preview"></a>             |
| 4   | [`4-gbw-amoled`](themes/4-gbw-amoled.json)         | Green `#00FF7A`   | <a href="docs/screenshots/themes/4-gbw-amoled.png"><img src="docs/screenshots/themes/4-gbw-amoled.png" width="300" alt="4-gbw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/4-gbw-amoled-light.png"><img src="docs/screenshots/themes/4-gbw-amoled-light.png" width="300" alt="4-gbw-amoled light preview"></a>             |
| 5   | [`5-bbw-amoled`](themes/5-bbw-amoled.json)         | Blue `#0090FF`    | <a href="docs/screenshots/themes/5-bbw-amoled.png"><img src="docs/screenshots/themes/5-bbw-amoled.png" width="300" alt="5-bbw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/5-bbw-amoled-light.png"><img src="docs/screenshots/themes/5-bbw-amoled-light.png" width="300" alt="5-bbw-amoled light preview"></a>             |
| 6   | [`6-vbw-amoled`](themes/6-vbw-amoled.json)         | Violet `#6F66FF`  | <a href="docs/screenshots/themes/6-vbw-amoled.png"><img src="docs/screenshots/themes/6-vbw-amoled.png" width="300" alt="6-vbw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/6-vbw-amoled-light.png"><img src="docs/screenshots/themes/6-vbw-amoled-light.png" width="300" alt="6-vbw-amoled light preview"></a>             |
| 7   | [`7-pbw-amoled`](themes/7-pbw-amoled.json)         | Pink `#FF60F8`    | <a href="docs/screenshots/themes/7-pbw-amoled.png"><img src="docs/screenshots/themes/7-pbw-amoled.png" width="300" alt="7-pbw-amoled theme preview"></a>             | <a href="docs/screenshots/themes/7-pbw-amoled-light.png"><img src="docs/screenshots/themes/7-pbw-amoled-light.png" width="300" alt="7-pbw-amoled light preview"></a>             |
| 8   | [`8-rainbow-amoled`](themes/8-rainbow-amoled.json) | Full neon (multi) | <a href="docs/screenshots/themes/8-rainbow-amoled.png"><img src="docs/screenshots/themes/8-rainbow-amoled.png" width="300" alt="8-rainbow-amoled theme preview"></a> | <a href="docs/screenshots/themes/8-rainbow-amoled-light.png"><img src="docs/screenshots/themes/8-rainbow-amoled-light.png" width="300" alt="8-rainbow-amoled light preview"></a> |

## Formatter on Termux

The built-in prettier formatter cannot spawn on Termux: its `.bin/prettier` uses a `#!/usr/bin/env node` shebang, `/usr/bin/env` does not exist on Android, and the musl wrapper's `LD_PRELOAD` swap prevents `termux-exec` from rewriting it. Format attempts fail with `NotFound: ChildProcess.spawn` and are silently skipped.

Fix (one time):

```sh
sh scripts/enable-formatter.sh
```

This installs prettier globally via Termux npm and points opencode at `node <prettier.cjs> --write $FILE` — no shebang involved. Only the `formatter` key of `~/.config/opencode/opencode.json` is changed (a `.bak` backup is written).

## Updating

Updates are unattended: schedule the job once (checks every 6h) and forget it.

```sh
termux-job-scheduler --job-id 7802 --period-ms 21600000 \
  --network any --persisted true \
  -s "$HOME/GitHub/opencode2-termux-musl/scripts/auto-update.sh"
```

The job (needs the Termux:API app — any network, survives reboot) checks the npm channel and re-runs `install.sh` only when behind; it never downgrades. You get a notification on success or failure, nothing to do manually. Runs are logged to `~/.opencode-auto-update.log`.

Manual options, if you ever need them:

```sh
./scripts/check-update.sh          # check only (exit 2 + notification if behind)
./scripts/check-update.sh --yes    # check + re-run install.sh if behind
```

v2 updates come from the npm channel only; the script compares against `opencode.ai/update/api/latest/cli/npm`.

Migrating the v1-era job (7801/7802 pointed at the archived `opencode-termux-musl` repo): reschedule the same job id with the path above — the v1 script compares against v1 GitHub tags and silently exits "nothing to do" once `opencode` reports 2.x.

## Migrating from v1 / side-by-side

If you previously ran v1 (`opencode` 1.x) or the side-by-side setup (`opencode2`):

```sh
cd opencode2-termux-musl
sh install.sh                 # v2 takes over the `opencode` name
sh scripts/remove-v1.sh       # deletes v1 binary + opencode2 leftovers (~350 MB)
```

`remove-v1.sh` refuses to run unless `opencode --version` already reports v2 and the v2 binary is in place. It never touches session data (`~/.local/share/opencode`) or config (`~/.config/opencode`). Your v1 sessions live in the same data directory and appear under v2.

## Known limitations

- **Formatter**: needs `enable-formatter.sh` once (shebang issue above). Without it, formatting silently no-ops.
- **Theme `system` mode**: follows the _terminal_ background (OSC 11), not the Android day/night mode — Termux's background is fixed, so `system` never auto-switches. Use `scripts/theme-sync.sh` for time-based light/dark (see below).
- **PTY support**: depends on `librust_pty_arm64.so`; not shipped yet. PRs welcome.
- **Proxy latency**: ~100–200 ms per outbound request (see Network above).

## Tested on

- Pixel 10 (Android 17, Termux 0.119, aarch64) — OpenCode v2.0.21 as `opencode`: TUI, `run`, shared service, themes, MCP servers (Railway, GitHub, Upstash, Chrome DevTools), and the v2 plugin API all verified on-device.

## Credits

- [guysoft/opencode-termux](https://github.com/guysoft/opencode-termux) — original Termux packaging ideas
- [DEAD1nsane/opencode-termux-musl](https://github.com/DEAD1nsane/opencode-termux-musl) — v1 musl era + side-by-side v2 bring-up (archived)
- [anomalyco/opencode](https://github.com/anomalyco/opencode) — OpenCode itself

## License

[MIT](LICENSE)
