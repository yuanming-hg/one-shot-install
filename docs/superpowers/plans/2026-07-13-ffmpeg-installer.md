# ffmpeg Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone `install_ffmpeg()` to `install.sh` so ffmpeg is available as a general-purpose CLI tool on sudo-less hosts, closing the gap where it's currently only attempted (via package manager, no fallback) as an optional yazi preview dependency.

**Architecture:** One new function following the existing `install_gh()`/`install_wezterm()` shape: skip if present, try `try_install_pkgs_no_password ffmpeg` (covers macOS brew + Linux passwordless-sudo apt/dnf/pacman in one call — same helper `install_yazi()`'s optional-dep loop already uses for this exact package), then fall back to a static-binary download for sudo-less Linux. Wired into `main()` before `install_yazi` so yazi's own ffmpeg optional-dep check becomes a no-op.

**Tech Stack:** Bash, `curl`/`wget` via the existing `download_to()` helper, `tar`, johnvansickle.com's static ffmpeg builds (rolling URL — see Global Constraints).

## Global Constraints

- No sudo required — every fallback path must work as a normal user.
- Follow existing conventions exactly: `need_cmd`, `download_to`, `try_install_pkgs_no_password`, `~/.local/bin` as the install target, `mktemp -d ... | trap RETURN` cleanup pattern (see `install_gh()` at `install.sh:789` for the canonical example).
- No `FFMPEG_VERSION` pin variable — the static-binary URL (`https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-{amd64,arm64}-static.tar.xz`) is an intentionally rolling pointer to upstream's current stable build. This is a deliberate, documented deviation from this repo's usual pinned-version convention (verified live: johnvansickle's `old-releases/` true-pin archive caps at a 2+-year-stale `6.0.1`; BtbN's alternative embeds git-hash filenames that would need two things kept in sync). Do not add a version-pin variable for ffmpeg.
- Full spec: `docs/superpowers/specs/2026-07-13-ffmpeg-installer-design.md`.

---

### Task 1: Add `install_ffmpeg()` function

**Files:**
- Modify: `install.sh` (new function, insert immediately after `install_gh()`, which ends at line 843 — i.e. right before the `# ---------------------------------------------------------------------------` / `# Cache symlink management` section header that currently follows it)

**Interfaces:**
- Consumes: `need_cmd()`, `try_install_pkgs_no_password()`, `download_to()`, `log()`, `warn()` — all pre-existing helpers defined earlier in `install.sh`.
- Produces: `install_ffmpeg()` — a no-argument shell function, callable from `main()`. On success, `ffmpeg` and (on the Linux static-binary path) `ffprobe` are on `PATH` via `~/.local/bin`.

- [ ] **Step 1: Confirm the exact insertion point**

Run:
```bash
grep -n "^install_gh() {" -A 60 install.sh | tail -15
```
Expected: shows the end of `install_gh()` (its closing `}` and final `log` line), followed by a comment-divider line and `# Cache symlink management`. This confirms where the new function goes.

- [ ] **Step 2: Insert `install_ffmpeg()`**

Add this function directly after `install_gh()`'s closing `}` (before the `# Cache symlink management` comment block):

```bash
install_ffmpeg() {
  if need_cmd ffmpeg; then
    log "ffmpeg already installed: $(ffmpeg -version 2>/dev/null | head -1)"
    return 0
  fi

  # Package manager covers macOS (brew) and Linux-with-passwordless-sudo
  # (apt/dnf/pacman) in one call — package name is "ffmpeg" everywhere.
  try_install_pkgs_no_password ffmpeg

  if need_cmd ffmpeg; then
    log "ffmpeg installed via package manager."
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    warn "Homebrew unavailable/failed. Skipping ffmpeg."
    return 0
  fi

  # No-sudo Linux fallback: static binary (self-contained, no shared libs
  # needed). This URL is a rolling pointer to upstream's current stable
  # static build (currently 7.0.2) — not version-pinned. See Global
  # Constraints in the implementation plan for why.
  local arch target_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)         target_arch="amd64" ;;
    aarch64|arm64)  target_arch="arm64" ;;
    *)              warn "Unsupported architecture for ffmpeg: $arch. Skipping."; return 0 ;;
  esac

  log "Installing ffmpeg (static build) from johnvansickle.com"
  local url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${target_arch}-static.tar.xz"
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN

  download_to "$url" "${tmpdir}/ffmpeg.tar.xz"
  tar -xJf "${tmpdir}/ffmpeg.tar.xz" -C "$tmpdir"

  local extracted_dir
  extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'ffmpeg-*-static')"

  mkdir -p "${HOME}/.local/bin"
  cp "${extracted_dir}/ffmpeg" "${HOME}/.local/bin/ffmpeg"
  cp "${extracted_dir}/ffprobe" "${HOME}/.local/bin/ffprobe"
  chmod +x "${HOME}/.local/bin/ffmpeg" "${HOME}/.local/bin/ffprobe"

  rm -rf "$tmpdir"
  trap - RETURN
  log "ffmpeg installed to ~/.local/bin/ ($("${HOME}/.local/bin/ffmpeg" -version 2>/dev/null | head -1))"
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Functional check — already-installed short-circuit**

This machine already has ffmpeg via brew, so this exercises the first branch (the only branch reachable without a real sudo-less Linux box — see Task 5 for the fallback-path check on a real remote host).

```bash
head -n -1 install.sh > /tmp/install_no_main.sh
bash -c 'source /tmp/install_no_main.sh; install_ffmpeg'
```
Expected output: `[+] ffmpeg already installed: ffmpeg version 8.0.1 ...` (version will match whatever is currently on this machine), exit code 0.

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
✨ [install] Add install_ffmpeg() core logic

brew/apt/dnf/pacman first (via try_install_pkgs_no_password), johnvansickle
static-binary fallback for sudo-less Linux hosts. Not wired into main() yet.
EOF
)"
```

---

### Task 2: Wire `install_ffmpeg` into `main()` and simplify yazi's optional deps

**Files:**
- Modify: `install.sh:1638` (main()'s call sequence — line number as of this plan's writing; re-grep if Task 1's insertion shifted things)
- Modify: `install.sh:659` (`yazi_opt_deps` array inside `install_yazi()`)

**Interfaces:**
- Consumes: `install_ffmpeg()` from Task 1.
- Produces: `ffmpeg` guaranteed to be on `PATH` (or a warned skip) before `install_yazi` runs.

- [ ] **Step 1: Find current call site and array**

```bash
grep -n "install_pnpm$\|install_yazi$\|install_wezterm$\|install_gh$\|yazi_opt_deps=" install.sh
```
Expected: shows `local yazi_opt_deps=(ffmpeg chafa)` and the `main()` block listing `install_pnpm`, `install_yazi`, `install_wezterm`, `install_gh` on consecutive lines.

- [ ] **Step 2: Add the call to `main()`**

Change:
```bash
  install_pnpm
  install_yazi
  install_wezterm
  install_gh
```
to:
```bash
  install_pnpm
  install_ffmpeg
  install_yazi
  install_wezterm
  install_gh
```

- [ ] **Step 3: Drop `ffmpeg` from yazi's optional-dep list**

Change:
```bash
  local yazi_opt_deps=(ffmpeg chafa)
```
to:
```bash
  # ffmpeg is installed separately by install_ffmpeg() (called before this
  # function in main()) — only chafa needs this fallback path.
  local yazi_opt_deps=(chafa)
```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Verify main() ordering**

```bash
grep -n "install_ffmpeg\|install_yazi\|install_pnpm\|install_wezterm\|install_gh" install.sh | grep -v "^[0-9]*:install_"
```
Actually just visually confirm via:
```bash
sed -n '/^main() {/,/^}/p' install.sh | grep -n "install_"
```
Expected: `install_ffmpeg` appears immediately before `install_yazi` in the printed list, and `install_gh` still defined as a function elsewhere (not accidentally removed).

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
✨ [install] Wire install_ffmpeg into main(), drop it from yazi's opt-deps

install_ffmpeg now runs before install_yazi, so yazi's own ffmpeg
optional-dep check is a no-op by the time it runs.
EOF
)"
```

---

### Task 3: `--check` mode entry and post-install summary line

**Files:**
- Modify: `install.sh:1457` (checks array in `run_check_mode()`)
- Modify: `install.sh` post-install summary block (the `echo "     - yazi --version"` line and its neighbors, near the end of `main()`)

**Interfaces:**
- Consumes: none new.
- Produces: `bash install.sh --check` reports ffmpeg's presence/absence; post-install summary tells the user to verify it.

- [ ] **Step 1: Find current checks array and summary block**

```bash
grep -n '"yazi:yazi"\|"wezterm:wezterm"\|"gh:gh"\|yazi --version\|wezterm --version\|gh --version' install.sh
```
Expected: shows the `checks=(...)` array entries and the three matching `echo` lines in the summary block.

- [ ] **Step 2: Add `ffmpeg:ffmpeg` to the checks array**

Change:
```bash
    "nvm:${HOME}/.nvm/nvm.sh"
    "yazi:yazi"
    "wezterm:wezterm"
    "gh:gh"
  )
```
to:
```bash
    "nvm:${HOME}/.nvm/nvm.sh"
    "ffmpeg:ffmpeg"
    "yazi:yazi"
    "wezterm:wezterm"
    "gh:gh"
  )
```

- [ ] **Step 3: Add the summary line**

Change:
```bash
  echo "     - zsh --version"
  echo "     - tmux -V (if installed)"
  echo "     - yazi --version"
```
to:
```bash
  echo "     - zsh --version"
  echo "     - tmux -V (if installed)"
  echo "     - ffmpeg -version"
  echo "     - yazi --version"
```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Functional check — `--check` mode**

```bash
bash install.sh --check | grep -i ffmpeg
```
Expected: a line showing `ffmpeg` as found/not-found (format matches the other entries in the same output, e.g. `[✓] ffmpeg: found` or `[x] ffmpeg: missing` depending on this machine's state — ffmpeg is present locally via brew, so expect the "found" form).

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
✨ [install] Add ffmpeg to --check mode and post-install summary
EOF
)"
```

---

### Task 4: Version bump and CHANGELOG entry

**Files:**
- Modify: `install.sh:18` (`INSTALL_VERSION`)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: none.
- Produces: version marker that `main()`'s upgrade-detection logic (`install.sh:1607-1615`) uses to decide whether to re-run.

- [ ] **Step 1: Check whether the other pending plan already bumped the version**

The `2026-07-13-remote-shell-startup-fix-design.md` spec also claims a version bump. Run:
```bash
grep -n "^INSTALL_VERSION" install.sh
head -20 CHANGELOG.md
```
- If `INSTALL_VERSION` is still `"1.4.0"` and `CHANGELOG.md`'s top entry is still `## [1.4.0]` → this plan is executing first. Use **`1.5.0`** below.
- If `INSTALL_VERSION` is already `"1.5.0"` (i.e. the nvm/startup-fix plan landed first) → use **`1.6.0`** below instead, and adjust the CHANGELOG heading accordingly.

The steps below assume the first case (`1.5.0`); substitute `1.6.0` throughout if the second case applies.

- [ ] **Step 2: Bump `INSTALL_VERSION`**

Change:
```bash
INSTALL_VERSION="1.4.0"
```
to:
```bash
INSTALL_VERSION="1.5.0"
```

- [ ] **Step 3: Add CHANGELOG entry**

Insert after the `All notable changes...` line and before the existing `## [1.4.0]` entry:
```markdown
## [1.5.0] - 2026-07-13

### Added

- `install_ffmpeg()` — ffmpeg CLI with package-manager-first install (brew/apt/dnf/pacman via `try_install_pkgs_no_password`), johnvansickle.com static-binary fallback for sudo-less Linux hosts (amd64/arm64)
- ffmpeg entry in `--check` dry-run mode
- ffmpeg in post-install verification summary
- yazi's `ffmpeg` optional-dep check simplified — `install_ffmpeg` now runs first in `main()`, so yazi's own check is a no-op by the time it runs

```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Verify version marker logic still works**

```bash
grep -n "INSTALL_VERSION" install.sh | head -3
```
Expected: `INSTALL_VERSION="1.5.0"` (or `1.6.0` per Step 1's check) at line 18, consistent everywhere else it's referenced (it's referenced by variable, not hardcoded elsewhere, so this is just a sanity check that no stray hardcoded `1.4.0` string remains).

```bash
grep -n '"1\.4\.0"\|1\.4\.0' install.sh CHANGELOG.md
```
Expected: no remaining `1.4.0` references in `install.sh` (the CHANGELOG.md will still have `## [1.4.0]` as a historical entry — that's correct and expected, do not remove it).

- [ ] **Step 6: Commit**

```bash
git add install.sh CHANGELOG.md
git commit -m "$(cat <<'EOF'
🔧 [install] Bump to v1.5.0 for ffmpeg installer
EOF
)"
```

---

### Task 5 (manual QA, not a hard gate): Verify the Linux static-binary fallback on a real host

This machine is macOS with brew, so Tasks 1-4's automated checks only ever exercise the "already installed" and macOS branches. The no-sudo Linux fallback path (johnvansickle static binary) has been verified manually during design (the exact tarball was downloaded and its contents inspected — confirmed `ffmpeg` and `ffprobe` both present at the top level of `ffmpeg-7.0.2-amd64-static/`), but the *installer code path* itself should be exercised on a real Linux host before considering this fully done.

- [ ] **Step 1: Find an idle host**

```bash
python3 ~/.claude/scripts/remote_sync.py status
```
Pick any `idle` entry with a "shared" user (low-risk to touch briefly).

- [ ] **Step 2: Sync and run**

```bash
python3 ~/.claude/scripts/remote_sync.py sync /Users/lym/PycharmProjects/one-shot-install <host> ~/one-shot-install-test
```
```bash
ssh <host> 'cd ~/one-shot-install-test && head -n -1 install.sh > /tmp/install_no_main.sh'
```
```bash
ssh <host> 'bash -c "source /tmp/install_no_main.sh; PATH=/usr/bin:/bin install_ffmpeg"'
```
(The restricted `PATH` in the last call hides any pre-existing `ffmpeg`/package-manager binaries so the static-binary fallback branch actually runs — adjust if the host's package manager still succeeds via passwordless sudo, which is also a valid success path, just not the one this step is targeting.)

Expected: log lines showing the johnvansickle download, extraction, and a final `ffmpeg installed to ~/.local/bin/ (ffmpeg version 7.0.2 ...)` line.

- [ ] **Step 3: Confirm the binaries work**

```bash
ssh <host> '~/.local/bin/ffmpeg -version | head -1'
ssh <host> '~/.local/bin/ffprobe -version | head -1'
```
Expected: both print version banners, no errors.

- [ ] **Step 4: Clean up test artifacts on the remote host**

```bash
ssh <host> 'rm -rf ~/one-shot-install-test ~/.local/bin/ffmpeg ~/.local/bin/ffprobe /tmp/install_no_main.sh'
```
(Only remove `~/.local/bin/ffmpeg`/`ffprobe` if this was a scratch/test host where ffmpeg wasn't wanted — skip this on any host where the user actually wants ffmpeg installed.)
