# Remote shell startup fix design

## Purpose

A user complaint ("omz is too slow starting") led to benchmarking real
interactive zsh startup, first locally then on a remote host provisioned by
this installer (`ib-vm-70`, `install_version 1.2.0`). Findings, in order of
discovery:

1. Local (independent, non-project omz+p10k setup): ~100ms steady-state,
   ~52ms of actual rc-script execution. `zprof` showed the biggest
   configurable cost was `_omz_source` itself (~41% of rc-time) — omz's own
   plugin-loading loop, bigger than `compinit`/`compdump` once the
   completion cache is warm. This established that omz+p10k, by themselves,
   are not egregiously slow.
2. Remote (`ib-vm-70`, this repo's own install output): **~1250ms
   steady-state — 12x the local number.** `zprof` there told a completely
   different story: `nvm`/`nvm_auto` alone account for **~900ms–1.2s (69–96%
   of total)**. `_omz_source` was 18ms (1.4%) — omz is not the bottleneck on
   this host at all.
3. Root cause, confirmed by reading the actual generated dotfiles and nvm's
   pinned-version (`v0.40.4`) upstream installer source:
   - `~/.config/shell/common.sh` (this repo's shared bash+zsh config,
     `install.sh:303` `setup_shared_shell_config()`) sources `nvm.sh` with no
     `--no-use` flag. Per nvm's own source (`nvm_process_parameters` /
     `nvm_auto`), sourcing without `--no-use` runs `nvm_auto use` on *every*
     source — resolves the current version and calls `nvm use --silent
     <default>`, real synchronous work, not free.
   - `install_nvm_and_node()` (`install.sh:1345`) installs nvm by running its
     official upstream installer via `download_and_run`. That installer
     self-appends its own nvm-loading block directly into `~/.bashrc`
     (confirmed exact text in nvm's source: `SOURCE_STR` +
     `COMPLETION_STR`), completely unaware that `common.sh` — which
     `~/.bashrc` already sources — does the same thing. Redundant.
   - `~/.zshrc` sources `common.sh` directly (`install.sh:1238`) **and**
     separately sources `~/.bashrc` for compat (`ZSH_BASHRC_COMPAT` block,
     `install.sh:1247`), and `~/.bashrc` sources `common.sh` again (no
     include-guard) plus runs its own separately-appended nvm block. Net
     result for one interactive zsh shell: `nvm.sh` gets sourced **3
     times**, each paying the `nvm_auto use` tax — matching the "3 calls to
     `nvm_auto`" seen in the remote `zprof` output exactly.
4. Secondary, unrelated finding from the same remote session: oh-my-zsh
   printed an "Insecure completion-dependent directories detected" warning
   every startup, for three group-writable directories
   (`~/.oh-my-zsh/cache/completions`, and the `zsh-autosuggestions` /
   `zsh-syntax-highlighting` plugin dirs cloned by `install_p10k_and_plugins`
   `install.sh:1198`). This is not a performance issue (`compaudit`'s own
   cost is ~7-10ms) — it's noise/security-hygiene, caused by an ambient
   group-writable umask on this shared server. Bundled into this fix at the
   user's request since it surfaced in the same investigation.

## Constraints

- Fix must not just patch the templates for future installs — it must also
  repair already-provisioned hosts (like `ib-vm-70`) on re-run, per this
  project's existing idempotent-block conventions
  (`append_block_if_missing`, `replace_block`).
- Login shell for every machine this installer touches is bash (project
  architecture: "No `chsh` needed"), so nvm's upstream installer always
  targets `~/.bashrc` specifically (confirmed via `nvm_detect_profile`'s
  `$SHELL`-based branch) — repair logic can be scoped to `~/.bashrc` without
  needing to also handle `.zprofile`/`.profile` variants.
- Repair of the legacy nvm `~/.bashrc` block is exact-string-match only
  (matches nvm v0.40.4's literal `SOURCE_STR`/`COMPLETION_STR` output,
  confirmed against ib-vm-70's actual file). Older nvm versions that might
  have appended slightly different text are out of scope — best-effort, not
  exhaustive.
- Disabling nvm's auto-use behavior (`--no-use`) is a real, accepted
  behavior change: a fresh interactive shell will no longer automatically
  have the default/lts node version active on `PATH`. `nvm` itself remains
  fully functional; users who want a version active must run `nvm use
  default` (or `nvm use --lts`) once. Accepted per user decision — `ib-vm-70`
  already separately configures `fnm` (outside this installer's management)
  for that purpose, and `install_nvm_and_node()` already sets `nvm alias
  default 'lts/*'` at install time regardless.

## Design

### 1. `common.sh` include-guard (new `prepend_block_if_missing()` helper)

Add a helper mirroring the existing `append_block_if_missing()` but inserting
a marker-guarded block at the *top* of the file instead of the bottom
(append-only helpers can't prevent re-execution of content that already ran
before them):

```bash
# Prepend a multi-line block once, guarded by a marker string
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

Guard content (marker `COMMON_SH_GUARD`):

```bash
# ---- COMMON_SH_GUARD ----
if [ -n "${_ONESHOT_COMMON_SH_LOADED:-}" ]; then
  return
fi
_ONESHOT_COMMON_SH_LOADED=1
# ---- /COMMON_SH_GUARD ----
```

`return` at top level is safe here because `common.sh` is always sourced
(via `. `/`source`), never executed directly, throughout this project.

### 2. `--no-use` on the nvm source line

In `setup_shared_shell_config()`'s fresh-install heredoc (`install.sh:310`),
change the nvm block to:

```bash
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh" --no-use
fi
```

For already-existing `common.sh` files, add a small exact-line-replace
helper and call it:

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
```

```bash
replace_line_if_present "$common_file" '  . "$NVM_DIR/nvm.sh"' '  . "$NVM_DIR/nvm.sh" --no-use'
```

### 3. `PROFILE=/dev/null` on nvm's upstream installer

In `install_nvm_and_node()` (`install.sh:1359`), change:

```bash
download_and_run "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
```

to:

```bash
# PROFILE=/dev/null: skip nvm's own rc-file modification — common.sh
# (sourced by both bash and zsh) already loads nvm; letting nvm's installer
# also append its own block to ~/.bashrc double-sources it every shell.
PROFILE=/dev/null download_and_run "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
```

Verified against nvm v0.40.4's actual `install.sh` source: `PROFILE=/dev/null`
is the documented, officially-supported mechanism (`nvm_detect_profile` /
`nvm_do_install` both special-case this exact value to skip profile
modification entirely).

### 4. Repair already-provisioned `~/.bashrc`

New exact-line-removal helper, called unconditionally (not just when nvm
itself needs reinstalling) so re-running `install.sh` repairs hosts that
already have the legacy block:

```bash
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

```bash
remove_line_if_present "${HOME}/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
remove_line_if_present "${HOME}/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm'
remove_line_if_present "${HOME}/.bashrc" '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion'
```

Placed in `install_nvm_and_node()`, after the install-or-skip block, so it
runs on every `install.sh` execution regardless of whether nvm itself needed
(re)installing this run.

### 5. Completion-directory permission repair (bundled fix)

- `_ensure_clone()` (`install.sh:1206`, used by `install_p10k_and_plugins()`
  for p10k + both plugins): add `chmod g-w,o-w "$dir" 2>/dev/null || true`
  right after the `git clone` call, so freshly-cloned plugin directories
  don't inherit group-writability from the ambient umask on shared hosts.
- New generic repair function, using oh-my-zsh's own recommended remedy
  (handles the plugin dirs on already-provisioned hosts *and* the
  lazily-created `~/.oh-my-zsh/cache/completions` dir, which
  `install_p10k_and_plugins` doesn't create directly and so can't be fixed
  at clone time):

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

Called from `main()` right after `install_p10k_and_plugins` (needs a
configured `~/.zshrc` + omz + plugins to exist for `compaudit` to find
anything meaningful). Best-effort: if the cache dir doesn't exist yet at
install time (first-ever zsh init on a brand new host), there's nothing for
`compaudit` to flag yet — this is primarily a repair mechanism for
already-provisioned hosts, run again on any future `install.sh --force`.

### Call-site wiring in `main()`

```
setup_shared_shell_config      # now also guards + patches --no-use
...
install_p10k_and_plugins       # _ensure_clone now chmods after clone
fix_completion_dir_perms       # NEW — after plugins/zshrc exist
install_oh_my_tmux
install_tmux_local_config
install_nvm_and_node           # PROFILE=/dev/null + .bashrc repair
```

### 6. Version bump

Bump `INSTALL_VERSION` + add a `CHANGELOG.md` entry. Exact version number
TBD at implementation time — coordinate with the still-pending
`2026-07-13-ffmpeg-installer-design.md` spec, which also claims a version
bump; whichever lands first takes the next minor version, the other takes
the one after.

## Error handling

Consistent with the rest of `install.sh`: every new helper degrades
gracefully (`|| true`, missing-file early-returns) rather than aborting the
install. `fix_completion_dir_perms` no-ops entirely if `zsh` isn't on PATH
yet or `compaudit` finds nothing.

## Testing

- `bash -n install.sh` (syntax check).
- Fresh-install path: run `install.sh --force` on a scratch host with no
  prior `common.sh`/`.bashrc` nvm state; confirm `common.sh` has the guard
  and `--no-use`, and `.bashrc` has no self-appended nvm block.
- Repair path: run `install.sh --force` again on `ib-vm-70` itself (already
  has the legacy triple-sourced state); confirm `common.sh` gets the guard
  + patched line, and the 3 legacy lines disappear from `.bashrc`.
- Re-run the same `zprof` benchmark used to diagnose this
  (`ZDOTDIR=<tmp-copy-with-warm-.zcompdump> zsh -i -c exit`) on `ib-vm-70`
  after the fix; confirm `nvm`/`nvm_auto` drops out of the top of the
  profile and total steady-state startup approaches the ~100ms local
  baseline.
- Confirm `nvm`, `node`, `npm` still work correctly after sourcing with
  `--no-use` (function is defined, `nvm use default` activates a version
  on demand).
- Confirm the completion-directory warning no longer appears on shell
  startup after `fix_completion_dir_perms` runs.
