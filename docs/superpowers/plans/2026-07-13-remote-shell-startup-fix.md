# Remote Shell Startup Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the ~900ms-1.2s of unnecessary nvm overhead on every interactive shell this installer provisions (nvm.sh sourced 3x per shell, each run paying nvm's default per-shell version auto-activation cost), and repair already-provisioned hosts on re-run — plus a bundled fix for a secondary completion-directory permissions nuisance found in the same investigation.

**Architecture:** Three independent-but-related fixes to `install.sh`, all following the existing idempotent-repair conventions (`append_block_if_missing`, marker comments): (1) an include-guard so `common.sh` can't double-execute its expensive contents when zsh sources `~/.bashrc` for compat, (2) `--no-use` on nvm's own sourcing plus `PROFILE=/dev/null` on nvm's upstream installer invocation so it stops self-appending a redundant block to `~/.bashrc`, with exact-string repair helpers so already-provisioned hosts get cleaned up on re-run, (3) a permissions sweep for zsh completion directories using oh-my-zsh's own recommended remedy (`compaudit | xargs chmod`).

**Tech Stack:** Bash, `awk`/`grep -F` for exact-line patch/removal, `zsh -ic '...'` for the `compaudit` sweep.

## Global Constraints

- Login shell for every host this installer manages is bash (project architecture: no `chsh`) — nvm's upstream installer always targets `~/.bashrc` specifically; repair logic is scoped there only, not `.zprofile`/`.profile`.
- `common.sh` is always sourced (`.`/`source`), never executed directly, throughout this project — a bare `return` at file top level is safe.
- The `~/.bashrc` repair (`remove_line_if_present`) is exact-string-match only, verified against nvm v0.40.4's literal `SOURCE_STR`/`COMPLETION_STR` output. Older nvm versions with different self-appended text are out of scope — best-effort, not exhaustive.
- `--no-use` is an accepted, real behavior change: fresh shells no longer auto-activate the default node version on `PATH`. `nvm use default` still works on demand.
- Full spec: `docs/superpowers/specs/2026-07-13-remote-shell-startup-fix-design.md`.

---

### Task 1: Add three generic file-patching helpers

**Files:**
- Modify: `install.sh` — insert `prepend_block_if_missing()` right after `append_block_if_missing()` (currently ends at line 101, before `replace_block()` at line 104); insert `replace_line_if_present()` and `remove_line_if_present()` right after `replace_block()` (currently ends at line 139, before `download_to()` at line 141).

**Interfaces:**
- Produces: `prepend_block_if_missing(file, marker, block)`, `replace_line_if_present(file, old_line, new_line)`, `remove_line_if_present(file, line)` — all no-return-value shell functions, all safe to call on a nonexistent-content-match (no-op) or nonexistent file (create/no-op as appropriate). Later tasks call these by these exact names.

- [ ] **Step 1: Confirm current line numbers**

Run:
```bash
grep -n "^append_block_if_missing\|^replace_block\|^download_to" install.sh
```
Expected: `append_block_if_missing` at 90, `replace_block` at 104, `download_to` at 141 (re-check if earlier edits in this session shifted things — use whatever `replace_block`'s closing `}` and `download_to`'s opening line actually are).

- [ ] **Step 2: Add `prepend_block_if_missing` after `append_block_if_missing`**

Insert immediately after `append_block_if_missing()`'s closing `}` (line 101), before the `# Replace a marker-delimited block...` comment:

```bash
# Prepend a multi-line block once, guarded by a marker string (inserted at
# the TOP of the file — append_block_if_missing can't prevent re-execution
# of content that already ran before it)
prepend_block_if_missing() {
  local file="$1"
  local marker="$2"
  local block="$3"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  if grep -Fq "$marker" "$file"; then
    log "Block already present in $file ($marker)"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  printf "%s\n" "$block" > "$tmp"
  cat "$file" >> "$tmp"
  mv "$tmp" "$file"
  trap - RETURN
}
```

- [ ] **Step 3: Add `replace_line_if_present` and `remove_line_if_present` after `replace_block`**

Insert immediately after `replace_block()`'s closing `}`, before the `download_to()` comment/function:

```bash
# Replace an exact line with a new one, if the old one is present verbatim
replace_line_if_present() {
  local file="$1" old="$2" new="$3"
  [[ -f "$file" ]] || return 0
  grep -Fqx "$old" "$file" || return 0
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  awk -v old="$old" -v new="$new" '$0==old{print new; next} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
  trap - RETURN
  log "Patched line in $file"
}

# Remove an exact line if present (used to strip lines a third-party
# installer added that we no longer want)
remove_line_if_present() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 0
  grep -Fqx "$line" "$file" || return 0
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  grep -Fvx "$line" "$file" > "$tmp" || true
  mv "$tmp" "$file"
  trap - RETURN
  log "Removed redundant line from $file"
}
```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Functional check — write a throwaway test harness**

```bash
cat > /tmp/test_helpers.sh <<'EOF'
set -euo pipefail
head -n -1 install.sh > /tmp/install_no_main.sh
source /tmp/install_no_main.sh

# --- prepend_block_if_missing ---
f="$(mktemp)"
printf "existing content\n" > "$f"
prepend_block_if_missing "$f" "MY_MARKER" "MY_MARKER line 1
MY_MARKER line 2"
[[ "$(head -1 "$f")" == "MY_MARKER line 1" ]] || { echo "FAIL: prepend didn't go to top"; exit 1; }
[[ "$(tail -1 "$f")" == "existing content" ]] || { echo "FAIL: original content lost"; exit 1; }
before="$(cat "$f")"
prepend_block_if_missing "$f" "MY_MARKER" "SHOULD NOT APPEAR"
[[ "$(cat "$f")" == "$before" ]] || { echo "FAIL: not idempotent"; exit 1; }
echo "PASS: prepend_block_if_missing"

# --- replace_line_if_present ---
f2="$(mktemp)"
printf "keep this\nOLD LINE\nkeep that\n" > "$f2"
replace_line_if_present "$f2" "OLD LINE" "NEW LINE"
grep -Fqx "NEW LINE" "$f2" || { echo "FAIL: replace didn't apply"; exit 1; }
! grep -Fqx "OLD LINE" "$f2" || { echo "FAIL: old line still present"; exit 1; }
echo "PASS: replace_line_if_present"

# --- remove_line_if_present ---
f3="$(mktemp)"
printf "keep this\nDELETE ME\nkeep that\n" > "$f3"
remove_line_if_present "$f3" "DELETE ME"
! grep -Fqx "DELETE ME" "$f3" || { echo "FAIL: line not removed"; exit 1; }
grep -Fqx "keep this" "$f3" || { echo "FAIL: unrelated line lost"; exit 1; }
echo "PASS: remove_line_if_present"

rm -f "$f" "$f2" "$f3"
EOF
bash /tmp/test_helpers.sh
```
Expected output:
```
PASS: prepend_block_if_missing
PASS: replace_line_if_present
PASS: remove_line_if_present
```

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
✨ [install] Add prepend/replace/remove line-patching helpers

Generic file-patching primitives needed to guard common.sh against
double-sourcing and repair already-provisioned hosts' dotfiles.
EOF
)"
```

---

### Task 2: `common.sh` include-guard + `--no-use`

**Files:**
- Modify: `install.sh:303` (`setup_shared_shell_config()`)

**Interfaces:**
- Consumes: `prepend_block_if_missing()`, `replace_line_if_present()` from Task 1.
- Produces: fresh `common.sh` files are guarded + use `--no-use` from creation; pre-existing `common.sh` files get patched on next run.

- [ ] **Step 1: Read current function**

```bash
sed -n '/^setup_shared_shell_config() {/,/^}/p' install.sh
```
Expected: matches the function shown in the spec's "Purpose" section — an `if [[ ! -f "$common_file" ]]` branch that heredocs the file, an `else` branch that just logs "leaving as-is", then three `append_if_missing` calls for `.bash_profile`/`.profile`/`.bashrc`.

- [ ] **Step 2: Update the fresh-install heredoc**

Change the heredoc body from:
```bash
    cat > "$common_file" <<'EOF'
# Shared shell config sourced by both bash and zsh.

# user local bins (uv installs here by default)
export PATH="$HOME/.local/bin:$PATH"

# pnpm (standalone install location)
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac

# nvm (installed by this script)
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
fi
EOF
```
to:
```bash
    cat > "$common_file" <<'EOF'
# Shared shell config sourced by both bash and zsh.

# ---- COMMON_SH_GUARD ----
# Avoid double-sourcing: this file is sourced directly by zsh, and again via
# the bash-compat shim when zsh sources ~/.bashrc. Re-running the nvm block
# below on every duplicate source is expensive (nvm's default auto-use).
if [ -n "${_ONESHOT_COMMON_SH_LOADED:-}" ]; then
  return
fi
_ONESHOT_COMMON_SH_LOADED=1
# ---- /COMMON_SH_GUARD ----

# user local bins (uv installs here by default)
export PATH="$HOME/.local/bin:$PATH"

# pnpm (standalone install location)
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac

# nvm (installed by this script)
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh" --no-use
fi
EOF
```

- [ ] **Step 3: Add repair calls in the `else` branch**

Change:
```bash
  else
    log "Shared shell config exists: $common_file (leaving as-is)"
  fi
```
to:
```bash
  else
    log "Shared shell config exists: $common_file (patching known issues)"
    prepend_block_if_missing "$common_file" "COMMON_SH_GUARD" "$(cat <<'BLOCK'
# ---- COMMON_SH_GUARD ----
if [ -n "${_ONESHOT_COMMON_SH_LOADED:-}" ]; then
  return
fi
_ONESHOT_COMMON_SH_LOADED=1
# ---- /COMMON_SH_GUARD ----
BLOCK
)"
    replace_line_if_present "$common_file" '  . "$NVM_DIR/nvm.sh"' '  . "$NVM_DIR/nvm.sh" --no-use'
  fi
```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Functional check — fresh-install path**

```bash
head -n -1 install.sh > /tmp/install_no_main.sh
rm -f /tmp/test_common.sh
bash -c '
source /tmp/install_no_main.sh
HOME=/tmp/fake_home_fresh
mkdir -p "$HOME"
setup_shared_shell_config
grep -c "COMMON_SH_GUARD" "$HOME/.config/shell/common.sh"
grep -F "nvm.sh\" --no-use" "$HOME/.config/shell/common.sh"
'
```
Expected: `grep -c` prints `2` (open + close marker comments), and the `--no-use` grep prints the matching line — no errors.

- [ ] **Step 6: Functional check — repair path (simulates an already-provisioned host)**

```bash
bash -c '
source /tmp/install_no_main.sh
HOME=/tmp/fake_home_existing
mkdir -p "$HOME/.config/shell"
cat > "$HOME/.config/shell/common.sh" <<EOF
# Shared shell config sourced by both bash and zsh.

export PATH="\$HOME/.local/bin:\$PATH"
export NVM_DIR="\$HOME/.nvm"
if [ -s "\$NVM_DIR/nvm.sh" ]; then
  . "\$NVM_DIR/nvm.sh"
fi
EOF
setup_shared_shell_config
head -1 "$HOME/.config/shell/common.sh"
grep -F "nvm.sh\" --no-use" "$HOME/.config/shell/common.sh"
'
```
Expected: `head -1` prints `# ---- COMMON_SH_GUARD ----` (guard successfully prepended to the *top*, above the pre-existing first line), and the `--no-use` grep matches — confirming the pre-existing file got patched in place, not skipped.

- [ ] **Step 7: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
🐛 [install] Guard common.sh against double-sourcing, add nvm --no-use

common.sh gets sourced directly by zsh AND again via the bash-compat
shim (no include-guard existed). Combined with nvm's default per-shell
auto-use behavior, this cost ~900ms-1.2s per interactive shell on a
remote host (diagnosed via zprof). Also repairs already-existing
common.sh files on re-run.
EOF
)"
```

---

### Task 3: `PROFILE=/dev/null` + `.bashrc` repair

**Files:**
- Modify: `install.sh:1345` (`install_nvm_and_node()`)

**Interfaces:**
- Consumes: `remove_line_if_present()` from Task 1.
- Produces: fresh installs no longer get nvm's self-appended `.bashrc` block; already-provisioned hosts get it stripped on re-run.

- [ ] **Step 1: Read current function**

```bash
sed -n '/^install_nvm_and_node() {/,/^}/p' install.sh
```
Expected: matches the version shown in this plan's Global Constraints research — a `download_and_run` call with no `PROFILE` override.

- [ ] **Step 2: Add `PROFILE=/dev/null` to the installer invocation**

Change:
```bash
    # Use pinned NVM_VERSION and download_and_run (P1-#15, P1-#9)
    download_and_run "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  fi
```
to:
```bash
    # Use pinned NVM_VERSION and download_and_run (P1-#15, P1-#9)
    # PROFILE=/dev/null: skip nvm's own rc-file modification — common.sh
    # (sourced by both bash and zsh) already loads nvm; letting nvm's
    # installer also append its own block to ~/.bashrc double-sources it
    # every shell. Verified against nvm v0.40.4's install.sh source: this
    # is the officially-documented mechanism to skip profile modification.
    PROFILE=/dev/null download_and_run "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  fi
```

- [ ] **Step 3: Add `.bashrc` repair calls after the install-or-skip block**

Change:
```bash
  export NVM_DIR="$nvm_dir"
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
```
to:
```bash
  # Repair: strip nvm's self-appended block from ~/.bashrc if a prior
  # install (or manual nvm install) added it before this fix existed.
  # Exact-match against nvm v0.40.4's literal SOURCE_STR/COMPLETION_STR
  # output — runs on every install.sh execution, not just fresh installs.
  remove_line_if_present "${HOME}/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
  remove_line_if_present "${HOME}/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm'
  remove_line_if_present "${HOME}/.bashrc" '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion'

  export NVM_DIR="$nvm_dir"
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
```

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Functional check — `.bashrc` repair**

```bash
head -n -1 install.sh > /tmp/install_no_main.sh
bash -c '
source /tmp/install_no_main.sh
HOME=/tmp/fake_home_bashrc_repair
mkdir -p "$HOME/.nvm"
touch "$HOME/.nvm/nvm.sh"
cat > "$HOME/.bashrc" <<EOF
some existing line
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"  # This loads nvm bash_completion
another existing line
EOF
remove_line_if_present "$HOME/.bashrc" "export NVM_DIR=\"\$HOME/.nvm\""
remove_line_if_present "$HOME/.bashrc" "[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"  # This loads nvm"
remove_line_if_present "$HOME/.bashrc" "[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"  # This loads nvm bash_completion"
cat "$HOME/.bashrc"
'
```
Expected output — only the two unrelated lines remain:
```
some existing line
another existing line
```

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
🐛 [install] Stop nvm installer self-appending to .bashrc, repair existing hosts

PROFILE=/dev/null on the upstream nvm installer prevents the redundant
.bashrc block on fresh installs; remove_line_if_present strips it from
hosts that already have it (one of the 3x sources of the nvm slowdown).
EOF
)"
```

---

### Task 4: Completion-directory permission repair

**Files:**
- Modify: `install.sh:1198` (`install_p10k_and_plugins()` — its nested `_ensure_clone()` helper)
- Modify: `install.sh:1593` (`main()` — add a new call)
- New function: `fix_completion_dir_perms()`, added directly before `install_oh_my_tmux()` (currently at line 1277)

**Interfaces:**
- Produces: `fix_completion_dir_perms()` — no-argument function, no-ops if `zsh` isn't present or nothing is flagged.

- [ ] **Step 1: Read current `_ensure_clone`**

```bash
sed -n '/_ensure_clone() {/,/^  }/p' install.sh
```
Expected: matches the version shown in the spec (clones via `git -c core.autocrlf=false clone`, no chmod).

- [ ] **Step 2: Add chmod after the clone**

Change:
```bash
    local clone_args=(--depth=1)
    [[ -n "$tag" ]] && clone_args+=(--branch "$tag")
    git -c core.autocrlf=false clone "${clone_args[@]}" "$repo" "$dir"
  }
```
to:
```bash
    local clone_args=(--depth=1)
    [[ -n "$tag" ]] && clone_args+=(--branch "$tag")
    git -c core.autocrlf=false clone "${clone_args[@]}" "$repo" "$dir"
    # zsh's compaudit refuses to load completions from group/other-writable
    # directories — don't inherit a permissive ambient umask.
    chmod g-w,o-w "$dir" 2>/dev/null || true
  }
```

- [ ] **Step 3: Add `fix_completion_dir_perms()` before `install_oh_my_tmux()`**

Insert directly before the `install_oh_my_tmux() {` line:

```bash
# zsh refuses to load completions from group/other-writable directories in
# $fpath — a real, recurring nuisance on shared servers with permissive
# umasks. Mirror oh-my-zsh's own suggested remedy (compaudit | xargs chmod).
fix_completion_dir_perms() {
  need_cmd zsh || return 0
  local insecure
  insecure="$(zsh -ic 'autoload -Uz compaudit; compaudit' 2>/dev/null || true)"
  [[ -n "$insecure" ]] || return 0
  log "Fixing group/other-writable zsh completion directories"
  while IFS= read -r d; do
    [[ -n "$d" ]] && chmod g-w,o-w "$d" 2>/dev/null || true
  done <<< "$insecure"
}

```

- [ ] **Step 4: Wire into `main()`**

Change:
```bash
  install_oh_my_zsh
  install_p10k_and_plugins
  install_oh_my_tmux
```
to:
```bash
  install_oh_my_zsh
  install_p10k_and_plugins
  fix_completion_dir_perms
  install_oh_my_tmux
```

- [ ] **Step 5: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 6: Functional check — chmod-after-clone**

```bash
head -n -1 install.sh > /tmp/install_no_main.sh
bash -c '
source /tmp/install_no_main.sh
tmpdir="$(mktemp -d)"
umask 002
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$tmpdir/test-clone" >/dev/null 2>&1
chmod g-w,o-w "$tmpdir/test-clone"
stat -f "%Sp" "$tmpdir/test-clone" 2>/dev/null || stat -c "%A" "$tmpdir/test-clone"
rm -rf "$tmpdir"
'
```
Expected: permission string with no `w` in the group or other positions (e.g. `drwxr-xr-x`), confirming `chmod g-w,o-w` does what `_ensure_clone` now does automatically after every clone.

- [ ] **Step 7: Functional check — `fix_completion_dir_perms` no-ops safely when nothing is flagged**

```bash
bash -c '
source /tmp/install_no_main.sh
fix_completion_dir_perms
echo "exit code: $?"
'
```
Expected: `exit code: 0` (on this machine, either `zsh` finds nothing insecure, or the function's `need_cmd zsh` / empty-result early-returns cleanly either way — no error, no crash).

- [ ] **Step 8: Commit**

```bash
git add install.sh
git commit -m "$(cat <<'EOF'
🐛 [install] Fix group-writable zsh completion directories

_ensure_clone now chmods g-w,o-w after every clone (prevents recurrence
on fresh installs); fix_completion_dir_perms mirrors oh-my-zsh's own
compaudit-based remedy to repair already-provisioned hosts and catch
the lazily-created ~/.oh-my-zsh/cache/completions directory too.
EOF
)"
```

---

### Task 5: Version bump and CHANGELOG entry

**Files:**
- Modify: `install.sh:18` (`INSTALL_VERSION`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Check whether the ffmpeg plan already bumped the version**

The `2026-07-13-ffmpeg-installer.md` plan also claims a version bump. Run:
```bash
grep -n "^INSTALL_VERSION" install.sh
head -20 CHANGELOG.md
```
- If `INSTALL_VERSION` is still `"1.4.0"` → this plan is executing first. Use **`1.5.0`** below.
- If `INSTALL_VERSION` is already `"1.5.0"` (ffmpeg plan landed first) → use **`1.6.0`** below instead.

The steps below assume the second case (`1.6.0`, ffmpeg landed first) since it lists `1.5.0` as already taken; substitute `1.5.0` throughout (and adjust "previous entry" references) if this plan executes first instead.

- [ ] **Step 2: Bump `INSTALL_VERSION`**

If ffmpeg's plan already bumped to `1.5.0`, change:
```bash
INSTALL_VERSION="1.5.0"
```
to:
```bash
INSTALL_VERSION="1.6.0"
```
(If this plan runs first instead, change `"1.4.0"` directly to `"1.5.0"`.)

- [ ] **Step 3: Add CHANGELOG entry**

Insert after the `All notable changes...` line and before whatever the current top entry is (`## [1.5.0]` if ffmpeg landed first, `## [1.4.0]` otherwise):

```markdown
## [1.6.0] - 2026-07-13

### Fixed

- **Critical**: nvm sourced up to 3x per interactive shell (common.sh direct + bash-compat shim + nvm's own self-appended .bashrc block), each run paying nvm's default per-shell auto-use cost — measured ~900ms-1.2s of ~1.25s total shell startup on a remote host via zprof
- `common.sh` now has an include-guard (`COMMON_SH_GUARD`) preventing double-sourcing via the zsh bash-compat shim
- nvm sourced with `--no-use` — skips per-shell version auto-activation (run `nvm use default` once if you need it active)
- `install_nvm_and_node()` now installs nvm with `PROFILE=/dev/null`, so nvm's upstream installer no longer self-appends a redundant block to `~/.bashrc`
- Already-provisioned hosts get repaired on re-run: `common.sh` gets the guard + `--no-use` patched in, and nvm's legacy `.bashrc` block is stripped
- Group/other-writable zsh completion directories (a recurring "Insecure completion-dependent directories" warning on shared servers with permissive umasks) are now fixed after every plugin clone and repaired on existing hosts via a `compaudit`-based sweep

```
(Use `## [1.5.0]` as the heading instead if this plan executes before the ffmpeg plan.)

- [ ] **Step 4: Syntax check**

Run: `bash -n install.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add install.sh CHANGELOG.md
git commit -m "$(cat <<'EOF'
🔧 [install] Bump version for remote shell startup fix
EOF
)"
```

---

### Task 6 (manual QA, not a hard gate): Confirm the fix on the real host that motivated it

Tasks 1-5's functional checks all run against fake `$HOME` sandboxes on the local machine. The actual regression — ~900ms-1.2s of nvm overhead — was measured on `ib-vm-70`, so the fix should be confirmed there.

- [ ] **Step 1: Sync and re-run install.sh**

```bash
python3 ~/.claude/scripts/remote_sync.py sync /Users/lym/PycharmProjects/one-shot-install ib-vm-70 ~/one-shot-install-test
```
```bash
ssh ib-vm-70 'cd ~/one-shot-install-test && bash install.sh --force'
```
Expected: log lines showing `common.sh` being patched ("Block already present" if run twice, or the patch messages on first run), the `.bashrc` repair removing the legacy nvm lines, and `fix_completion_dir_perms` reporting fixed directories (or no-op if already clean).

- [ ] **Step 2: Verify the dotfiles actually changed**

```bash
ssh ib-vm-70 'grep -c COMMON_SH_GUARD ~/.config/shell/common.sh'
ssh ib-vm-70 'grep -F "nvm.sh\" --no-use" ~/.config/shell/common.sh'
ssh ib-vm-70 'grep -c "This loads nvm" ~/.bashrc'
```
Expected: `2` (guard open+close), the `--no-use` line present, and `0` matches for `"This loads nvm"` in `.bashrc` (the legacy block is gone) — **do not** run this against the real `~/.bashrc`/`~/.config/shell/common.sh` without having already run Step 1's `install.sh --force`, since these are in-place edits to the user's actual dotfiles on a shared host.

- [ ] **Step 3: Re-run the same zprof benchmark used to diagnose the bug**

```bash
ssh ib-vm-70 "cat > /tmp/zprof_run.sh" <<'SCRIPT'
#!/bin/bash
mkdir -p /tmp/zprof-zdotdir-verify
cp ~/.zshrc /tmp/zprof-zdotdir-verify/.zshrc
sed -i '1i zmodload zsh/zprof' /tmp/zprof-zdotdir-verify/.zshrc
echo 'zprof' >> /tmp/zprof-zdotdir-verify/.zshrc
cp ~/.zcompdump-ib-vm-70-5.8.1 ~/.zcompdump-ib-vm-70-5.8.1.zwc /tmp/zprof-zdotdir-verify/ 2>/dev/null
ZDOTDIR=/tmp/zprof-zdotdir-verify zsh -i -c exit
SCRIPT
```
```bash
ssh ib-vm-70 'bash /tmp/zprof_run.sh' 2>&1 | grep -A 15 "^num"
```
Expected: `nvm`/`nvm_auto` no longer appear in the top few entries (or drop to a single-digit-ms, single-call presence instead of the prior 3-call/~900ms+ showing) — the previous top line was `nvm 6 898.41 ... 69.05% ...`; after the fix, `_omz_source` and `compinit` should be back to being the largest entries, similar in magnitude to the local baseline (~20-30ms range) established during diagnosis.

- [ ] **Step 4: Wall-clock sanity check**

```bash
ssh ib-vm-70 "cat > /tmp/zsh_bench_verify.sh" <<'SCRIPT'
#!/bin/bash
for i in 1 2 3; do
  S=$(date +%s%N)
  zsh -i -c exit
  E=$(date +%s%N)
  echo "run $i: $(( (E-S)/1000000 ))ms"
done
SCRIPT
```
```bash
ssh ib-vm-70 'bash /tmp/zsh_bench_verify.sh'
```
Expected: each run well under the original ~1250ms — ideally in the 100-300ms range (some of the ~500ms unaccounted-for gap between the local ~100ms baseline and remote's post-fix number may remain, e.g. from slower disk I/O for `_omz_source`'s file reads on this host's filesystem — that's expected and not a regression, just this host's inherent I/O characteristics).

- [ ] **Step 5: Confirm `nvm`/`node`/`npm` still work under `--no-use`**

`--no-use` only skips the automatic per-shell activation — `nvm` itself and manual activation must still work:

```bash
ssh ib-vm-70 'zsh -ic "which nvm"'
ssh ib-vm-70 'zsh -ic "nvm use default && node -v && npm -v"'
```
Expected: `which nvm` prints a function definition (not "not found"), and the second command prints a node version and an npm version with no errors — confirming `--no-use` disabled only the automatic activation, not `nvm` itself.

- [ ] **Step 6: Clean up test artifacts**

```bash
ssh ib-vm-70 'rm -rf ~/one-shot-install-test /tmp/zprof-zdotdir-verify /tmp/zprof_run.sh /tmp/zsh_bench_verify.sh'
```
