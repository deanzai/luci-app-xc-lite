# XC operation reliability verification

Host verification time: 2026-08-11T10:39:06+08:00
Device verification time: 2026-08-12T03:14:13+08:00
Branch: `fast_select_api`
Implementation commit: `815bcbe`

## Host verification

- `LUA51=./.tools/lua5.1 XRAY_LOCATION_ASSET=./.xray-26.6.27-test/extracted bash tests/run-host.sh` — exit 0.
- Lua suite — 486 tests passed.
- Node UI tests, package structure, translation, CRLF, and sensitive-field checks — passed.
- `git diff --check` — exit 0.

## Package and device status

- Package release in `Makefile` — `0.1.0-r30`.
- Local OpenWrt SDK — unavailable.
- A local test IPK was assembled from the existing `r30` package metadata and current source tree; runtime, asset-job, and controller hashes matched before installation.
- Device `192.168.13.1` — SSH connected; package was reinstalled without `--force-depends`.
- Backup — `/tmp/xc-operation-fix-backup/20260812-025316-25561`; `/etc/config/xc` still matches the backup.
- Post-install package version — `0.1.0-r30`; Xray config test exit 0; service running; ports 7890 and 10809 listening.
- Restart and recovery commands — both returned success; service returned to running.
- Fast switch — succeeded after restoring the initial balancer override, cleared the exit-IP cache, and successfully switched back; final selection is consistent.
- Resource cancellation — ended with `asset_update_cancelled`; cancel marker and temporary asset were removed; lifecycle completion log was recorded.
- A residual device issue was observed: after restart, the asynchronous `restore-selection` did not converge within 60 status polls (`unknown`/recovery required). A direct `restore-selection` then returned `selection_restored`, and the final device state is consistent and running.
- Fix `f13167e` (pending device re-verification): `init.d/xc` previously gave up after the 60-second API probe window and never invoked `restore-selection` when Xray startup lagged. It now retries `restore-selection` with a bounded window (12 attempts, 5s apart) after probe exhaustion, so a slow startup converges once the loopback API becomes ready. Host verification passes 487 Lua tests plus Node UI, package, translation, CRLF, and sensitive-field checks; device verification on `192.168.13.1` is still required.

No credentials, node URLs, UUIDs, raw configuration, or complete logs are included here.
