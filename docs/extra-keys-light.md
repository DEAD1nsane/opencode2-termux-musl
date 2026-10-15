# Light extra-keys (patched Termux APK)

Upstream `termux/termux-app#1544` (open since May 2020) hard-codes the
extra-keys bar to white-on-black: `activity_termux.xml:103`
(`@color/black`) plus white/black `extraKeysButton*` colors in both
`values/themes.xml` and `values-night/themes.xml`. `night-mode` /
`use-black-ui` only recolors drawer + dialogs, never the bar.

`patches/termux-extrakeys-light.patch` makes the **light** theme
dark-on-light and points the toolbar container at the theme attr:

- `values/themes.xml`: text `white→black`, background `black→white`,
  active text `red_400→red_800`, active bg `grey_500→grey_400`.
- `values-night/themes.xml`: untouched (stays white-on-black).
- `layout/activity_termux.xml`: `@color/black` →
  `?attr/extraKeysButtonBackgroundColor`.

## Build

Actions → "Build patched Termux APK" → Run workflow (default
`v0.119.0`). Download the `termux-patched-light-extrakeys` artifact
(`app-debug.apk`).

Debug-signed, so Android treats it as a different app from F-Droid /
GitHub release builds: back up first (`termux-backup` or tar `$HOME`),
uninstall, sideload, restore.

## Use with theme-sync

`scripts/theme-sync.sh` flips `night-mode` automatically (`false` by day,
`true` by night, deprecated `use-black-ui` removed) alongside `cli.json`
and the terminal background. `night-mode` needs a force-stop + reopen to
take effect; colors apply live. Manual override if ever needed:

```sh
sh scripts/theme-sync.sh --light   # or --dark
# then force-stop Termux and reopen
```

Stock APK + `night-mode=false` still shows a black bar (that's the
hard-code). The patch is what makes light actually light.
