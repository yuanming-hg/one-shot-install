# ffmpeg installer design

## Purpose

`install.sh` has no way to get `ffmpeg` onto a sudo-less host. It's currently
only referenced as an optional yazi preview dependency (`yazi_opt_deps=(ffmpeg
chafa)` in `install_yazi()`), attempted solely via the system package manager.
On a Linux box without passwordless sudo, ffmpeg is silently skipped and yazi
loses media thumbnails — and there's no way to get ffmpeg as a general-purpose
CLI tool at all.

Add a standalone `install_ffmpeg()`, following the existing pattern used by
`install_gh()`, `install_yazi()`, and `install_wezterm()`: try the system
package manager first, fall back to a static binary download when there's no
sudo.

## Constraints

- No sudo required (core project constraint).
- Must follow existing conventions: `need_cmd`, `download_to`,
  `try_install_pkgs_no_password`, `~/.local/bin` install target, `--check`
  dry-run entries, post-install summary line, `INSTALL_VERSION` bump,
  `CHANGELOG.md` entry.
- Upstream reality check (verified live during design): ffmpeg has no
  cleanly-pinned static-build source the way `gh`/`yazi`/`wezterm` do.
  - johnvansickle.com's `old-releases/` archive (true pinning) caps out at
    `6.0.1` (~2023) — stale by 2+ years, not updated since.
  - The `releases/ffmpeg-release-{arch}-static.tar.xz` URL is a rolling
    pointer to upstream's current stable static build (currently `7.0.2`,
    verified `200 OK` for both `amd64` and `arm64`), but re-running the
    installer later may silently fetch a newer ffmpeg.
  - BtbN/FFmpeg-Builds GitHub releases are pinnable via dated tags (e.g.
    `autobuild-2026-07-12-13-16`), but asset filenames embed a git-describe
    hash (`ffmpeg-n8.1.2-22-g94138f6973-linux64-gpl-8.1.tar.xz`) that would
    need to be hardcoded alongside the tag — messier than a single `VERSION=`
    var and two things to keep in sync.
  - Decision: use the rolling johnvansickle `release` URL. This is an
    intentional, documented deviation from this repo's usual pinned-version
    convention, made because no better option exists upstream.
- Archive layout confirmed by extracting the real tarball: top-level dir
  `ffmpeg-<version>-<arch>-static/` contains both `ffmpeg` and `ffprobe`
  binaries directly (plus `qt-faststart`, manpages, license, unused here).

## Design

### `install_ffmpeg()`

1. If `ffmpeg` is already on `PATH`, log its version and return.
2. Call `try_install_pkgs_no_password ffmpeg` — this already covers macOS
   (brew) and Linux-with-passwordless-sudo (apt/dnf/pacman) in one call,
   since the package name `ffmpeg` is identical across all of them. This is
   the same helper `install_yazi()`'s optional-dep loop already calls for the
   same package.
3. If `ffmpeg` is now present, log and return.
4. macOS without brew (or brew install failed): warn and skip — no macOS
   static build exists upstream, matching `install_gh()`'s
   "Homebrew not found. Skipping gh." precedent.
5. Linux, still missing: map `uname -m` to johnvansickle's arch naming
   (`x86_64` → `amd64`, `aarch64`/`arm64` → `arm64`; anything else warns and
   skips, matching `install_gh()`/`install_yazi()`).
6. Download `https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${target_arch}-static.tar.xz`
   via `download_to` into a `mktemp -d` scratch dir, extract with `tar -xJf`,
   copy `ffmpeg` and `ffprobe` out of the extracted
   `ffmpeg-*-${target_arch}-static/` directory into `~/.local/bin`, `chmod
   +x` both, clean up the scratch dir.
7. Log the installed version (`ffmpeg -version | head -1`).

### Wiring changes

- Call `install_ffmpeg` in `main()` immediately before `install_yazi`, so
  that by the time yazi's own optional-dep check runs, `ffmpeg` is already
  on `PATH` and that check is a no-op for it.
- Remove `ffmpeg` from `install_yazi()`'s `yazi_opt_deps` array — it's now
  fully owned by `install_ffmpeg`, and leaving it in would produce a
  redundant second warning if installation fails. Keep `chafa` there
  unchanged.
- Add `"ffmpeg:ffmpeg"` to the `checks` array in `run_check_mode()`.
- Add an `ffmpeg -version` line to the post-install summary, alongside the
  existing `yazi --version` / `wezterm --version` / `gh --version` lines.
- Bump `INSTALL_VERSION` `1.4.0` → `1.5.0`.
- Add a `CHANGELOG.md` entry under a new `[1.5.0]` section describing the
  installer, the rolling-URL tradeoff, and the yazi wiring change.

## Error handling

Matches existing style throughout the script: every failure path (missing
package manager, missing brew, unsupported architecture, failed download)
calls `warn` and returns `0` rather than aborting the whole install — ffmpeg
absence should never block the rest of `install.sh` from running, same as
`gh`, `yazi`, `wezterm`, and `chafa` today.

## Testing

- `bash -n install.sh` (syntax check).
- `bash install.sh --check` and confirm the new `ffmpeg:ffmpeg` line appears
  correctly for present/absent states.
- Run `install_ffmpeg` manually (or full `install.sh`) on a sudo-less Linux
  host to confirm the static-binary fallback path actually downloads,
  extracts, and installs a working `ffmpeg`/`ffprobe` into `~/.local/bin`.
- Confirm `install_yazi`'s optional-dep loop no longer touches ffmpeg (no
  duplicate log/warn lines) when run right after `install_ffmpeg`.
