# Changelog

All notable changes to this project will be documented in this file.

## [1.4.1] - 2026-07-13

### Added

- `install_ffmpeg()` — ffmpeg CLI with package-manager-first install (brew/apt/dnf/pacman via `try_install_pkgs_no_password`), johnvansickle.com static-binary fallback for sudo-less Linux hosts (amd64/arm64)
- ffmpeg entry in `--check` dry-run mode
- ffmpeg in post-install verification summary
- yazi's `ffmpeg` optional-dep check simplified — `install_ffmpeg` now runs first in `main()`, so yazi's own check is a no-op by the time it runs

### Fixed

- **Critical**: nvm sourced up to 3x per interactive shell (common.sh direct + bash-compat shim + nvm's own self-appended .bashrc block), each run paying nvm's default per-shell auto-use cost — measured ~900ms-1.2s of ~1.25s total shell startup on a remote host via zprof, confirmed fixed on real hardware (~1.5s → ~150ms, ~10x)
- `common.sh` now has an include-guard (`COMMON_SH_GUARD`) preventing double-sourcing via the zsh bash-compat shim
- nvm sourced with `--no-use` — skips per-shell version auto-activation (run `nvm use default` once if you need it active)
- `install_nvm_and_node()` now installs nvm with `PROFILE=/dev/null`, so nvm's upstream installer no longer self-appends a redundant block to `~/.bashrc`
- Already-provisioned hosts get repaired on re-run: `common.sh` gets the guard + `--no-use` patched in, and nvm's legacy `.bashrc` block is stripped
- Group/other-writable zsh completion directories (a recurring "Insecure completion-dependent directories" warning on shared servers with permissive umasks) are now fixed after every plugin clone and repaired on existing hosts via a `compaudit`-based sweep
- Post-install summary's `node -v && npm -v` check updated to `nvm use default && node -v && npm -v` (stale after the `--no-use` change above)
- `install_ffmpeg()`'s static-binary path no longer aborts the whole installer if johnvansickle.com ever changes its tarball layout — warns and skips instead

## [1.4.0] - 2026-07-13

### Added

- `install_gh()` — GitHub CLI with brew (macOS), apt/dnf (Linux), and versioned GitHub release tarball fallback for Linux hosts without sudo
- Pinned version: `GH_VERSION=2.96.0`
- gh entry in `--check` dry-run mode
- gh in post-install verification summary (prompts to run `gh auth login`)

## [1.3.0] - 2026-04-28

### Fixed

- **Critical**: static/musl-linked zsh binary causes broken colors and garbled input (doubled characters) on glibc hosts due to missing terminfo support

### Added

- `_install_zsh_from_deb()` — fallback installer that extracts zsh + zsh-common from Ubuntu jammy `.deb` packages into `~/.local/` when no system zsh or sudo is available
- `_validate_zsh_binary()` — detects and rejects static/musl zsh builds via `file(1)`
- `_write_zsh_local_env()` — generates `~/.zshenv` with `MODULE_PATH` and `fpath` pointing to extracted support files
- Musl zsh binary backed up as `~/.local/bin/zsh.musl.bak` before replacement

## [1.1.0] - 2026-02-23

### Added

- `install_yazi()` — terminal file manager with `file(1)` dependency check, brew/apt/dnf support, and GitHub binary fallback for Linux/macOS without sudo
- `install_wezterm()` — GPU-accelerated terminal emulator with brew (macOS), apt/dnf (Linux), and AppImage fallback without sudo
- Pinned versions: `YAZI_VERSION=v26.1.22`, `WEZTERM_VERSION=20240203-110809-5046fc22`
- yazi and wezterm entries in `--check` dry-run mode
- yazi and wezterm in post-install verification summary

### Fixed

- Use musl (statically linked) build for yazi on Linux to avoid glibc version mismatch

## [1.0.2] - 2026-02-23

### Fixed

- CRLF line endings breaking zsh on WSL (`fix_line_endings()`, `strip_cr()`, `fix_git_autocrlf()`)
- `--check` mode for marker-based targets (file-with-marker pattern)

### Changed

- Set default shell to zsh inside tmux via `TMUX_DEFAULT_SHELL` block in `tmux.conf.local`
- Use gitmoji shortcodes in commit convention examples

## [1.0.1] - 2026-02-20

### Added

- Initial release: full environment installer (`install.sh`)
- zsh + Oh My Zsh + Powerlevel10k + zsh-autosuggestions + zsh-syntax-highlighting
- tmux + oh-my-tmux with local config
- nvm + Node.js LTS
- uv with custom venv aliases (`uv activate/create/rm/env`)
- Bash-to-zsh handoff (no `chsh` required)
- Shared shell config (`~/.config/shell/common.sh`)
- Cache symlinks to `/local` for heavy directories
- `--check` dry-run and `--force` re-run modes
- Version tracking via `~/.config/shell/install-version`
- GitHub Action for auto-pack and release on version bump

[1.1.0]: https://github.com/yuanming-heygen/one-shot-install/releases/tag/v1.1.0
[1.0.2]: https://github.com/yuanming-heygen/one-shot-install/releases/tag/v1.0.2
[1.0.1]: https://github.com/yuanming-heygen/one-shot-install/releases/tag/v1.0.1
