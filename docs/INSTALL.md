# Installation guide

Detailed install, migration and troubleshooting for OpenCode v2 on Termux. Quick start lives in the [README](../README.md).

## Fresh install

```sh
pkg install curl tar python
git clone https://github.com/DEAD1nsane/opencode2-termux-musl.git
cd opencode2-termux-musl
sh install.sh
```

The installer is idempotent — re-running it refreshes the binary (default) or, with `OPENCODE_WRAPPER_ONLY=1`, only the wrapper scripts.

### What lands on disk

| Path                                            | Purpose                                                  |
| ----------------------------------------------- | -------------------------------------------------------- |
| `$PREFIX/bin/opencode`                          | wrapper (env, proxy autostart, `--standalone` injection) |
| `$PREFIX/bin/opencode-shared`                   | same, but forces shared-service mode                     |
| `$PREFIX/libexec/opencode/opencode-v2-musl.bin` | upstream musl binary, interpreter patched                |
| `$PREFIX/libexec/opencode/proxy.py`             | local HTTPS proxy (Python)                               |
| `$PREFIX/lib/ld-musl-aarch64.so.1`              | musl loader (from Alpine)                                |
| `$PREFIX/lib/libstdc++.so.6`, `libgcc_s.so.1`   | C++ runtime for the musl binary                          |
| `$PREFIX/lib/libresolvefix.so`                  | musl DNS shim (resolv.conf redirect)                     |

## Versions, pinning, offline

```sh
OPENCODE_VERSION=2.0.21 sh install.sh       # pin
# pre-download the tarball, then:
curl -L -C - -o cli-linux-arm64-musl-2.0.21.tgz \
  https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-2.0.21.tgz
OPENCODE_TARBALL_PATH=./cli-linux-arm64-musl-2.0.21.tgz sh install.sh
```

## Migrating from v1 or side-by-side

1. `sh install.sh` — v2 becomes `opencode` (the v1 wrapper is backed up as `opencode.v1.bak` first).
2. `sh scripts/remove-v1.sh` — deletes the side-by-side `opencode2` wrapper/helpers and the v1 binaries (`opencode-musl.bin`, `opencode.bin`), freeing ~350 MB.

Safety gates in `remove-v1.sh`: it aborts unless `opencode --version` reports v2 **and** the v2 binary exists. Session data (`~/.local/share/opencode`) and config (`~/.config/opencode`) are never touched — v1 sessions appear under v2 (both use the same SQLite data dir).

Old v1-format themes in `~/.config/opencode/themes/` still load (v2 migrates them on read), but v2-native themes (this repo's `themes/`) color agent pills correctly. Replace them:

```sh
cp themes/*.json ~/.config/opencode/themes/
```

Plugins must use the v2 format (`export default { id, setup }`). v1-format plugins fail with `Plugin must export a default definition with an id and an effect or setup function` — remove them from `~/.config/opencode/plugins/` or port them.

## Standalone vs shared service

| Mode                 | How                                 | Behavior                                                            |
| -------------------- | ----------------------------------- | ------------------------------------------------------------------- |
| Standalone (default) | `opencode run …`                    | wrapper injects `--standalone` → private server per call            |
| Shared service       | `opencode-shared serve --service &` | one server; TUI + `OPENCODE_STANDALONE=0 opencode run` attach to it |

Start the shared service through `opencode-shared` (or with `OPENCODE_STANDALONE=0`), so the proxy env is set. Killing the phone's Termux process kills the service; restart it after Termux restarts if you want TUI attach mode.

## Formatter

```sh
sh scripts/enable-formatter.sh
```

Installs global prettier and rewrites the `formatter` key of `~/.config/opencode/opencode.json` to invoke it via `node` directly. Restart opencode afterwards. Rollback: restore the generated `opencode.json.bak`.

## Updating

Unattended daily auto-update (Termux:API — schedule once, applies updates on its own):

```sh
termux-job-scheduler --job-id 7802 --period-ms 86400000 \
  --network unmetered --persisted true \
  -s "$HOME/GitHub/opencode2-termux-musl/scripts/auto-update.sh"
```

The job checks the npm channel and re-runs `install.sh` only when behind; never downgrades. Notifications fire on success or failure — no manual step.

Manual options:

```sh
./scripts/check-update.sh          # check only
./scripts/check-update.sh --yes    # apply via install.sh
```

If a v1-era job (7801/7802) still points at the archived `opencode-termux-musl` repo, reschedule it with the path above — the v1 script checks the v1 GitHub tag channel and exits "nothing to do" forever once `opencode` reports 2.x. When the auto-update job is _not_ scheduled, `check-update.sh` says so explicitly instead of nudging a manual install.sh run.

## Troubleshooting

**`opencode run` times out with `getaddrinfo ETIMEOUT opencode.ai`**
Node/c-ares bypasses `libresolvefix.so`; the wrapper's proxy env is the fix. Check `pgrep -f proxy.py` and that `HTTP_PROXY` is set inside the session (`opencode` inherits it from the wrapper — if you exec the binary directly, env is missing). Shared-service users: restart the service via `opencode-shared`.

**Wrong binary downloaded / `not found` on exec**
You probably ran the official curl installer, which misdetects Termux as glibc. Re-run this repo's `install.sh` — it always takes the musl npm build and patches the interpreter.

**`failed to format file … NotFound: ChildProcess.spawn`**
The prettier shebang issue — run `scripts/enable-formatter.sh` (see above).

**`Plugin must export a default definition with an id and an effect or setup function`**
A v1-format plugin is being loaded. Port it to `export default { id, setup }` or remove it.

**Musl/clang/patchelf errors during install**
`pkg install clang patchelf` manually, then re-run `install.sh`.

**Proxy port 8080 already in use**
Another process owns the port; the wrapper skips starting `proxy.py` when any `proxy.py` is already running. If a _foreign_ process squats the port, stop it or change the port in `scripts/proxy.py` + the wrapper's `HTTP(S)_PROXY` values (`OPENCODE_WRAPPER_ONLY=1 sh install.sh` after editing).

## Uninstall

```sh
rm -f "$PREFIX/bin/opencode" "$PREFIX/bin/opencode-shared" \
      "$PREFIX/libexec/opencode/opencode-v2-musl.bin" \
      "$PREFIX/libexec/opencode/proxy.py"
# musl loader/libs/libresolvefix are shared; remove only if nothing else needs them:
# rm -f "$PREFIX/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/libstdc++.so.6"* \
#       "$PREFIX/lib/libgcc_s.so.1" "$PREFIX/lib/libresolvefix.so"
```

Data and config stay behind on purpose: `~/.local/share/opencode` and `~/.config/opencode`.
