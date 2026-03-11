#!/usr/bin/env bash
# Auto Installation Script
#
# Usage: ./install.sh [--check] [--force]
#   --check   Dry-run: show what would be done without making changes
#   --force   Re-run even if the current version is already installed
#
# Config files (p10k.zsh, tmux.config.local) are loaded from the same
# directory as this script by default. Override with env vars:
#   P10K_CONFIG_PATH / P10K_CONFIG_URL
#   TMUX_LOCAL_CONFIG_PATH / TMUX_LOCAL_CONFIG_URL
#
# File permissions: this script should be chmod 0755 (rwxr-xr-x)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_VERSION="1.2.0"
INSTALL_STATE_DIR="${HOME}/.config/shell"
INSTALL_STATE_FILE="${INSTALL_STATE_DIR}/install-version"

# Default config paths: use repo-local files if env vars not set
P10K_CONFIG_PATH="${P10K_CONFIG_PATH:-${SCRIPT_DIR}/p10k.zsh}"
TMUX_LOCAL_CONFIG_PATH="${TMUX_LOCAL_CONFIG_PATH:-${SCRIPT_DIR}/tmux.config.local}"

# Pinned tool versions
NVM_VERSION="v0.40.4"
P10K_TAG="v1.20.0"
ZSH_AUTOSUGG_TAG="v0.7.1"
ZSH_SYNTAX_HL_TAG="0.8.0"
YAZI_VERSION="v26.1.22"
WEZTERM_VERSION="20240203-110809-5046fc22"
CHAFA_VERSION="1.18.1"

# Flags (set by parse_args)
CHECK_MODE=false
FORCE_MODE=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)  CHECK_MODE=true ;;
      --force)  FORCE_MODE=true ;;
      *)        warn "Unknown argument: $1" ;;
    esac
    shift
  done
}

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Strip carriage returns from a file in-place (fixes CRLF on WSL)
strip_cr() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if LC_ALL=C grep -q $'\r' "$file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    tr -d '\r' < "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

# Set core.autocrlf=false in a git repo and re-checkout to fix CRLF files
fix_git_autocrlf() {
  local repo_dir="$1"
  [[ -d "$repo_dir/.git" || -f "$repo_dir/.git" ]] || return 0
  local current
  current="$(git -C "$repo_dir" config --local core.autocrlf 2>/dev/null || echo "")"
  [[ "$current" == "false" ]] && return 0
  log "Fixing CRLF line endings in $repo_dir"
  git -C "$repo_dir" config core.autocrlf false
  git -C "$repo_dir" rm --cached -r . >/dev/null 2>&1 || true
  git -C "$repo_dir" reset --hard HEAD >/dev/null 2>&1 || true
}

append_if_missing() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  grep -Fqx "$line" "$file" || printf "\n%s\n" "$line" >> "$file"
}

# Append a multi-line block once, guarded by a marker string
append_block_if_missing() {
  local file="$1"
  local marker="$2"
  local block="$3"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  if grep -Fq "$marker" "$file"; then
    log "Block already present in $file ($marker)"
    return 0
  fi
  printf "\n%s\n" "$block" >> "$file"
}

# Replace a marker-delimited block in a file (P0-#6)
replace_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local new_block="$4"

  if [[ ! -f "$file" ]]; then
    return 1
  fi
  if ! grep -Fq "$start_marker" "$file"; then
    return 1
  fi

  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  local inside=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"$start_marker"* ]]; then
      inside=true
      printf "%s\n" "$new_block"
      continue
    fi
    if $inside; then
      if [[ "$line" == *"$end_marker"* ]]; then
        inside=false
      fi
      continue
    fi
    printf "%s\n" "$line"
  done < "$file" > "$tmp"

  mv "$tmp" "$file"
  trap - RETURN
}

download_to() {
  local url="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")" 2>/dev/null || true

  # Treat as local file if:
  #  - file:// URL
  #  - path exists as given
  #  - or exists after expanding ~
  if [[ "$url" == file://* ]]; then
    local src="${url#file://}"
    if [[ -f "$src" ]]; then
      cp -f "$src" "$dest"
      strip_cr "$dest"
      return 0
    fi
    err "Local file not found: $src"
    return 1
  fi

  local expanded="$url"
  [[ "$expanded" == "~"* ]] && expanded="${expanded/#\~/$HOME}"

  if [[ -f "$url" || -f "$expanded" ]]; then
    cp -f "${expanded:-$url}" "$dest"
    strip_cr "$dest"
    return 0
  fi

  # Remote URL — download to temp file first, then mv on success (P1-#8)
  local tmpfile
  tmpfile="$(mktemp "$(dirname "$dest")/.dl.XXXXXX")"
  trap 'rm -f "$tmpfile"' RETURN

  if need_cmd curl; then
    curl -fsSL "$url" -o "$tmpfile"
  elif need_cmd wget; then
    wget -qO "$tmpfile" "$url"
  else
    err "Need curl or wget to download: $url"
    rm -f "$tmpfile"
    trap - RETURN
    return 1
  fi

  mv "$tmpfile" "$dest"
  trap - RETURN
}

# Download a remote script to a temp file and execute it (P1-#9)
# Replaces all curl | sh patterns for safety.
download_and_run() {
  local url="$1"
  shift
  local tmpscript
  tmpscript="$(mktemp "${TMPDIR:-/tmp}/install-script.XXXXXX")"
  trap 'rm -f "$tmpscript"' RETURN

  if need_cmd curl; then
    curl -fsSL "$url" -o "$tmpscript"
  elif need_cmd wget; then
    wget -qO "$tmpscript" "$url"
  else
    err "Need curl or wget to download: $url"
    rm -f "$tmpscript"
    trap - RETURN
    return 1
  fi

  bash "$tmpscript" "$@" < /dev/null
  local rc=$?
  rm -f "$tmpscript"
  trap - RETURN
  return $rc
}

have_passwordless_sudo() { need_cmd sudo && sudo -n true >/dev/null 2>&1; }

try_install_pkgs_no_password() {
  local pkgs=("$@")

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if need_cmd brew; then
      log "brew detected. Installing: ${pkgs[*]}"
      brew install "${pkgs[@]}" >/dev/null || warn "brew install failed (continuing)."
    else
      warn "Homebrew not found. Skipping system package installs."
    fi
    return 0
  fi

  if have_passwordless_sudo; then
    if need_cmd apt-get; then
      log "Installing via apt (passwordless sudo): ${pkgs[*]}"
      sudo -n apt-get update -y >/dev/null 2>&1 || true
      sudo -n apt-get install -y "${pkgs[@]}" || warn "apt install failed (continuing)."
    elif need_cmd dnf; then
      log "Installing via dnf (passwordless sudo): ${pkgs[*]}"
      sudo -n dnf install -y "${pkgs[@]}" || warn "dnf install failed (continuing)."
    elif need_cmd pacman; then
      log "Installing via pacman (passwordless sudo): ${pkgs[*]}"
      sudo -n pacman -Sy --noconfirm "${pkgs[@]}" || warn "pacman install failed (continuing)."
    else
      warn "No supported package manager detected (apt/dnf/pacman)."
    fi
  else
    warn "No passwordless sudo. Skipping system package installs."
  fi
}

# ------------------------------------------------------------------------------
# CRITICAL FIX: bashrc compatibility shim
# This prevents "command shopt not found" (and similar) when zsh sources ~/.bashrc.
# ------------------------------------------------------------------------------
add_bashrc_zsh_compat_shim() {
  local bashrc="${HOME}/.bashrc"
  touch "$bashrc"

  if grep -q 'BASHRC_ZSH_COMPAT_SHIM' "$bashrc"; then
    log "bashrc zsh-compat shim already present."
    return 0
  fi

  log "Adding bashrc zsh-compat shim to avoid shopt/complete/bind errors in zsh."
  # mktemp on same filesystem for atomic mv (P1-#13)
  local tmp
  tmp="$(mktemp "${HOME}/.bashrc.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  cat > "$tmp" <<'EOF'
# ---- BASHRC_ZSH_COMPAT_SHIM ----
# This file is sometimes sourced by zsh for compatibility.
# Bash-only builtins (shopt/complete/bind/...) will error in zsh unless we guard them.
if [ -z "${BASH_VERSION:-}" ]; then
  shopt()    { :; }
  complete() { :; }
  bind()     { :; }
fi
# ---- /BASHRC_ZSH_COMPAT_SHIM ----

EOF
  cat "$bashrc" >> "$tmp"
  mv "$tmp" "$bashrc"
  trap - RETURN
}

set_timezone() {
  # Use a marker comment instead of empty string for append_if_missing (P2-#20)
  append_if_missing "${HOME}/.config/shell/common.sh" "# -- timezone config --"
  append_if_missing "${HOME}/.config/shell/common.sh" 'export TZ="Asia/Singapore"'
  log 'Timezone set: export TZ="Asia/Singapore"'
}

setup_git_credential_store() {
  if git config --global credential.helper | grep -q store; then
    log "git credential.helper already set to store."
    return
  fi
  git config --global credential.helper store
  log "git credential.helper set to store."
}

setup_shared_shell_config() {
  local common_dir="${HOME}/.config/shell"
  local common_file="${common_dir}/common.sh"
  mkdir -p "$common_dir"

  if [[ ! -f "$common_file" ]]; then
    log "Creating shared shell config: $common_file"
    cat > "$common_file" <<'EOF'
# Shared shell config sourced by both bash and zsh.

# user local bins (uv installs here by default)
export PATH="$HOME/.local/bin:$PATH"

# nvm (installed by this script)
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
fi
EOF
  else
    log "Shared shell config exists: $common_file (leaving as-is)"
  fi

  append_if_missing "${HOME}/.bash_profile" '[[ -f ~/.bashrc ]] && . ~/.bashrc'
  append_if_missing "${HOME}/.profile"      '[[ -f ~/.bashrc ]] && . ~/.bashrc'
  append_if_missing "${HOME}/.bashrc"       '[[ -f ~/.config/shell/common.sh ]] && . ~/.config/shell/common.sh'

  log "Configured bash to source ~/.config/shell/common.sh"
}

setup_uv_aliases() {
  local common_file="${HOME}/.config/shell/common.sh"
  local marker="UV_VENV_ALIASES"
  local block
  block="$(cat <<'BLOCK'
# ---- UV_VENV_ALIASES ----
# uv venv base directory
UV_VENV_BASE="/local/${USER}/.uv_venv"

# Helper: list available uv venvs
_uv_env_list() {
  if [[ ! -d "$UV_VENV_BASE" ]]; then
    echo "(no venvs — $UV_VENV_BASE does not exist)"
    return 1
  fi
  for d in "$UV_VENV_BASE"/*/bin/activate; do
    [[ -f "$d" ]] && basename "$(dirname "$(dirname "$d")")"
  done
}

# Validate venv name: no path traversal (P1-#11)
_uv_validate_name() {
  local name="$1"
  if [[ "$name" == */* || "$name" == ..* ]]; then
    echo "Invalid venv name: $name"
    return 1
  fi
}

# Wrapper: intercept custom subcommands, pass the rest to real uv
uv() {
  case "${1:-}" in
    activate)
      local name="${2:-}"
      if [[ -z "$name" ]]; then
        echo "Usage: uv activate <venv_name>"
        echo "Available:"
        _uv_env_list 2>/dev/null | sed 's/^/  /'
        return 1
      fi
      _uv_validate_name "$name" || return 1
      local activate="${UV_VENV_BASE}/${name}/bin/activate"
      if [[ -f "$activate" ]]; then
        source "$activate"
      else
        echo "No venv found: $activate"
        return 1
      fi
      ;;
    deactivate)
      if typeset -f deactivate >/dev/null 2>&1; then
        deactivate
      else
        echo "No venv is currently active"
        return 1
      fi
      ;;
    create)
      local name="${2:-}"
      if [[ -z "$name" ]]; then
        echo "Usage: uv create <venv_name> [python_version]"
        return 1
      fi
      _uv_validate_name "$name" || return 1
      local venv_dir="${UV_VENV_BASE}/${name}"
      if [[ -d "$venv_dir" ]]; then
        echo "Venv already exists: $venv_dir"
        return 1
      fi
      mkdir -p "$UV_VENV_BASE"
      local py_flag=()
      [[ -n "${3:-}" ]] && py_flag=(--python "$3")
      command uv venv "${py_flag[@]}" "$venv_dir"
      ;;
    rm)
      local name="${2:-}"
      if [[ -z "$name" ]]; then
        echo "Usage: uv rm <venv_name>"
        echo "Available:"
        _uv_env_list 2>/dev/null | sed 's/^/  /'
        return 1
      fi
      _uv_validate_name "$name" || return 1
      local venv_dir="${UV_VENV_BASE}/${name}"
      if [[ ! -d "$venv_dir" ]]; then
        echo "No venv found: $venv_dir"
        return 1
      fi
      echo -n "Remove $venv_dir? [y/N] "
      read -r reply
      if [[ "$reply" =~ ^[Yy]$ ]]; then
        rm -rf "$venv_dir"
        echo "Removed $name"
      else
        echo "Cancelled"
      fi
      ;;
    env)
      case "${2:-}" in
        list) _uv_env_list ;;
        path)
          local name="${3:-}"
          if [[ -z "$name" ]]; then
            echo "Usage: uv env path <venv_name>"
            return 1
          fi
          local venv_dir="${UV_VENV_BASE}/${name}"
          if [[ -d "$venv_dir" ]]; then
            echo "$venv_dir"
          else
            echo "No venv found: $venv_dir"
            return 1
          fi
          ;;
        *) command uv "$@" ;;
      esac
      ;;
    *)
      command uv "$@"
      ;;
  esac
}

# Tab completion for custom uv subcommands
if [[ -n "${ZSH_VERSION:-}" ]]; then
  _uv_custom_complete() {
    case "${words[2]}" in
      activate|rm) compadd -- $(_uv_env_list 2>/dev/null) ;;
      env)
        case "${words[3]}" in
          path) compadd -- $(_uv_env_list 2>/dev/null) ;;
          *)    compadd -- list path ;;
        esac ;;
      *) return 1 ;;
    esac
  }
  compdef _uv_custom_complete uv
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _uv_custom_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local sub="${COMP_WORDS[1]}"
    case "$sub" in
      activate|rm) COMPREPLY=($(compgen -W "$(_uv_env_list 2>/dev/null)" -- "$cur")) ;;
      env)
        if [[ "${COMP_WORDS[2]}" == "path" ]]; then
          COMPREPLY=($(compgen -W "$(_uv_env_list 2>/dev/null)" -- "$cur"))
        else
          COMPREPLY=($(compgen -W "list path" -- "$cur"))
        fi ;;
    esac
  }
  complete -F _uv_custom_complete uv
fi

# In zsh, `which` is a builtin that shows function bodies instead of binary
# paths. Wrap it so `which uv` (and any other function that shadows a binary)
# prints the binary path like users expect.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  which() {
    local arg
    for arg in "$@"; do
      if [[ "$(whence -w "$arg" 2>/dev/null)" == *function* ]]; then
        whence -p "$arg" 2>/dev/null || { echo "$arg not found"; return 1; }
      else
        builtin which "$arg"
      fi
    done
  }
fi
# ---- /UV_VENV_ALIASES ----
BLOCK
)"
  append_block_if_missing "$common_file" "$marker" "$block"
}

setup_ray_alias() {
  local common_file="${HOME}/.config/shell/common.sh"
  local marker="RAY_ALIASES"
  local block
  block="$(cat <<'BLOCK'
# ---- RAY_ALIASES ----
# Default Ray prod address (NOT exported — only used by ray-* helpers below)
RAY_PROD="http://data-ray-dev:8265"

# ray-submit: upload code + submit with standard boilerplate
#
# Usage: ray-submit [options] -- <command...>
#
# Options:
#   -n, --name NAME       Job name (sets --submission-id NAME-TIMESTAMP and NAME=NAME env prefix)
#   --pip FILE            pip requirements lock file
#   --uv FILE             uv requirements lock file
#   --dotenv              Prefix command with `dotenv run --`
#   --env KEY=VAL         Extra env_vars in runtime env (repeatable)
#   --exclude PATTERN     Extra exclude pattern (repeatable, .git always included)
#   --no-upload           Skip upload_codes.py, use --working-dir . instead
#   Any unrecognized flags before -- are passed through to `ray job submit`
#
# Examples:
#   ray-submit -n pret_optflow --pip ray_workflow/video_pretraining/pip_reqs/requirements.lock --dotenv \
#     -- python ray_pipeline/ray_actor_runner_v2.py \
#       --actors pret_db_reader,pret_optical_flow \
#       --workspace_dir /mnt/jfsweu/video_dataset/pretrain/v=20260303/subset=ytb_a2v_batch02102025 \
#       --run_reader_on_head --level segment --input_checker_batch_size 100
#
#   ray-submit -n AUD_diar --pip ray_workflow/audio_generation/requirements.lock --dotenv \
#     -- python ray_workflow/ray_actor_runner.py \
#       --actors hybrid_lance_reader,videotts_speaker_diarization \
#       --workspace_dir /mnt/jfsweu/audio_training_dataset_Nov2025/ytb/v251215
ray-submit() {
  local name="" reqs_key="" reqs_file="" use_dotenv=false no_upload=false
  local -a env_pairs=() extra_excludes=() passthrough=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)     name="$2"; shift 2 ;;
      --pip)         reqs_key="pip"; reqs_file="$2"; shift 2 ;;
      --uv)          reqs_key="uv";  reqs_file="$2"; shift 2 ;;
      --dotenv)      use_dotenv=true; shift ;;
      --env)         env_pairs+=("$2"); shift 2 ;;
      --exclude)     extra_excludes+=("$2"); shift 2 ;;
      --no-upload)   no_upload=true; shift ;;
      --)            shift; break ;;
      *)             passthrough+=("$1"); shift ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    echo "Usage: ray-submit [options] -- <command...>"
    echo "Run 'ray-submit --help' or see comments in ~/.config/shell/common.sh"
    return 1
  fi

  # Upload code
  local workdir
  if $no_upload; then
    workdir="."
  else
    echo "Uploading code via upload_codes.py..."
    workdir=$(python upload_codes.py) || { echo "upload_codes.py failed"; return 1; }
  fi

  # Build runtime-env-json
  local excludes='".git"'
  for ex in "${extra_excludes[@]}"; do
    excludes="${excludes}, \"${ex}\""
  done

  local runtime_env="{"
  # env_vars (add PYTHONPATH=. by default)
  local env_json='"PYTHONPATH": "."'
  for pair in "${env_pairs[@]}"; do
    local k="${pair%%=*}" v="${pair#*=}"
    env_json="${env_json}, \"${k}\": \"${v}\""
  done
  runtime_env="${runtime_env}\"env_vars\": {${env_json}}, \"excludes\": [${excludes}]"
  # pip or uv requirements
  if [[ -n "$reqs_key" ]]; then
    runtime_env="${runtime_env}, \"${reqs_key}\": \"${reqs_file}\""
  fi
  runtime_env="${runtime_env}}"

  # Build ray job submit args
  local addr="${RAY_PROD}"
  local -a submit_args=(
    ray job submit
    --address "$addr"
    --working-dir "$workdir"
    --runtime-env-json "$runtime_env"
  )
  [[ -n "$name" ]] && submit_args+=(--submission-id "${name}-$(date +%s)")
  submit_args+=("${passthrough[@]}")
  submit_args+=(--)

  # Build command prefix
  [[ -n "$name" ]] && submit_args+=("NAME=${name}")
  $use_dotenv && submit_args+=(dotenv run --)

  submit_args+=("$@")

  echo "+ ${submit_args[*]}"
  "${submit_args[@]}"
}

# Convenience wrappers for remote ray commands (never pollute RAY_ADDRESS)
ray-log()  { ray job logs  --address "$RAY_PROD" "$@"; }
ray-stop() { ray job stop  --address "$RAY_PROD" "$@"; }
ray-list() { ray job list  --address "$RAY_PROD" "$@"; }
# ---- /RAY_ALIASES ----
BLOCK
)"
  append_block_if_missing "$common_file" "$marker" "$block"
}

install_uv() {
  if need_cmd uv; then
    log "uv already installed: $(uv --version || true)"
    return 0
  fi
  log "Installing uv (user-space)"
  need_cmd curl || try_install_pkgs_no_password curl
  need_cmd curl || { err "curl not available; cannot install uv."; return 1; }
  download_and_run "https://astral.sh/uv/install.sh"
}

install_yazi() {
  if need_cmd yazi; then
    log "yazi already installed: $(yazi --version 2>/dev/null || true)"
    return 0
  fi

  # Required dependency: file(1)
  if ! need_cmd file; then
    try_install_pkgs_no_password file
    if ! need_cmd file; then
      warn "'file' command required by yazi but not available. Skipping yazi."
      return 0
    fi
  fi

  # Optional dependencies for media preview
  local yazi_opt_deps=(ffmpeg chafa)
  local missing_opt=()
  for dep in "${yazi_opt_deps[@]}"; do
    need_cmd "$dep" || missing_opt+=("$dep")
  done
  if [[ ${#missing_opt[@]} -gt 0 ]]; then
    log "yazi optional deps missing: ${missing_opt[*]}"
    try_install_pkgs_no_password "${missing_opt[@]}"
  fi

  # chafa: fall back to static binary if package manager didn't work (x86_64 only)
  if ! need_cmd chafa && [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
    log "Installing chafa ${CHAFA_VERSION} static binary"
    local chafa_url="https://hpjansson.org/chafa/releases/static/chafa-${CHAFA_VERSION}-1-x86_64-linux-gnu.tar.gz"
    local chafa_tmp
    chafa_tmp="$(mktemp -d "${TMPDIR:-/tmp}/chafa-install.XXXXXX")"
    if download_to "$chafa_url" "${chafa_tmp}/chafa.tar.gz"; then
      tar -xzf "${chafa_tmp}/chafa.tar.gz" -C "$chafa_tmp"
      mkdir -p "${HOME}/.local/bin"
      cp "${chafa_tmp}/chafa-${CHAFA_VERSION}-1-x86_64-linux-gnu/chafa" "${HOME}/.local/bin/chafa"
      chmod +x "${HOME}/.local/bin/chafa"
      log "chafa ${CHAFA_VERSION} installed to ~/.local/bin/"
    else
      warn "Failed to download chafa static binary (continuing)"
    fi
    rm -rf "$chafa_tmp"
  fi

  for dep in "${yazi_opt_deps[@]}"; do
    need_cmd "$dep" || warn "Optional: '$dep' not installed (yazi media preview may be limited)"
  done

  # macOS: prefer brew
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if need_cmd brew; then
      log "Installing yazi via brew"
      brew install yazi >/dev/null || warn "brew install yazi failed (continuing)."
      return 0
    fi
  fi

  # Linux with sudo: try package manager first
  if [[ "$(uname -s)" != "Darwin" ]] && have_passwordless_sudo; then
    if need_cmd apt-get; then
      sudo -n apt-get install -y yazi >/dev/null 2>&1 && { log "yazi installed via apt."; return 0; } || true
    elif need_cmd dnf; then
      sudo -n dnf install -y yazi >/dev/null 2>&1 && { log "yazi installed via dnf."; return 0; } || true
    fi
  fi

  # Binary download (works on both macOS and Linux without sudo)
  log "Installing yazi ${YAZI_VERSION} from GitHub release"

  if ! need_cmd unzip; then
    try_install_pkgs_no_password unzip
    if ! need_cmd unzip; then
      warn "unzip not available. Cannot extract yazi. Skipping."
      return 0
    fi
  fi

  local os arch target_arch target
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$arch" in
    x86_64)         target_arch="x86_64" ;;
    aarch64|arm64)  target_arch="aarch64" ;;
    *)              warn "Unsupported architecture for yazi: $arch. Skipping."; return 0 ;;
  esac

  case "$os" in
    Linux)  target="${target_arch}-unknown-linux-musl" ;;
    Darwin) target="${target_arch}-apple-darwin" ;;
    *)      warn "Unsupported OS for yazi: $os. Skipping."; return 0 ;;
  esac

  local url="https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-${target}.zip"
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/yazi-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN

  download_to "$url" "${tmpdir}/yazi.zip"
  unzip -q "${tmpdir}/yazi.zip" -d "$tmpdir"

  mkdir -p "${HOME}/.local/bin"
  cp "${tmpdir}/yazi-${target}/yazi" "${HOME}/.local/bin/yazi"
  cp "${tmpdir}/yazi-${target}/ya" "${HOME}/.local/bin/ya"
  chmod +x "${HOME}/.local/bin/yazi" "${HOME}/.local/bin/ya"

  rm -rf "$tmpdir"
  trap - RETURN
  log "yazi ${YAZI_VERSION} installed to ~/.local/bin/"
}

install_wezterm() {
  if need_cmd wezterm; then
    log "wezterm already installed: $(wezterm --version 2>/dev/null || true)"
    return 0
  fi

  # macOS: brew
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if need_cmd brew; then
      log "Installing wezterm via brew"
      brew install --cask wezterm >/dev/null || warn "brew install --cask wezterm failed (continuing)."
    else
      warn "Homebrew not found. Skipping wezterm."
    fi
    return 0
  fi

  # Linux with sudo: try package manager first
  if have_passwordless_sudo; then
    if need_cmd apt-get; then
      sudo -n apt-get install -y wezterm >/dev/null 2>&1 && { log "wezterm installed via apt."; return 0; } || true
    elif need_cmd dnf; then
      sudo -n dnf install -y wezterm >/dev/null 2>&1 && { log "wezterm installed via dnf."; return 0; } || true
    fi
  fi

  # AppImage download (self-contained, no system deps needed)
  log "Installing wezterm ${WEZTERM_VERSION} (AppImage)"
  mkdir -p "${HOME}/.local/bin"
  local url="https://github.com/wezterm/wezterm/releases/download/${WEZTERM_VERSION}/WezTerm-${WEZTERM_VERSION}-Ubuntu20.04.AppImage"
  download_to "$url" "${HOME}/.local/bin/wezterm"
  chmod +x "${HOME}/.local/bin/wezterm"
  log "wezterm AppImage installed to ~/.local/bin/wezterm"
}

# ---------------------------------------------------------------------------
# Cache symlink management
# Local drive is small (128G). Move heavy caches to /local and symlink back.
# ---------------------------------------------------------------------------
SHARED_LOCAL_BASE="/local/${USER}"

# Generic helper: link a single directory to /local.
#   link_cache_to_local <local_path> <shared_path>
# - If <local_path> is already the correct symlink → skip.
# - If <local_path> is a real dir with data → move contents to <shared_path>.
# - Creates <shared_path> and symlinks <local_path> → <shared_path>.
link_cache_to_local() {
  local local_path="$1"
  local shared_path="$2"

  # Verify /local is usable before touching anything
  if ! mkdir -p "$shared_path" 2>/dev/null; then
    warn "Cannot create $shared_path (skipping)"
    return 0
  fi
  if [[ ! -w "$shared_path" ]]; then
    warn "Not writable: $shared_path (skipping)"
    return 0
  fi

  # Already correct
  if [[ -L "$local_path" ]] && [[ "$(readlink "$local_path")" == "$shared_path" ]]; then
    return 0
  fi

  # local_path is a real directory with data → migrate first
  if [[ -d "$local_path" && ! -L "$local_path" ]]; then
    log "Migrating existing data: $local_path -> $shared_path"
    # rsync preserves permissions; trailing / means "contents of"
    if need_cmd rsync; then
      rsync -a "$local_path/" "$shared_path/"
    else
      cp -a "$local_path/." "$shared_path/"
    fi
    rm -rf "$local_path"
  fi

  mkdir -p "$(dirname "$local_path")"
  ln -sfn "$shared_path" "$local_path"
  log "Linked: $local_path -> $shared_path"
}

# Ensure all heavy cache / data dirs live on /local.
# Called unconditionally from main() so links stay correct across re-runs.
ensure_cache_symlinks() {
  log "Ensuring caches are symlinked to /local ..."

  # Quick check: is /local available at all?
  if [[ ! -d "/local" ]]; then
    warn "/local does not exist — skipping cache symlinks."
    return 0
  fi

  # ~/.cache/<tool>
  local cache_dirs=(
    uv
    pip
    huggingface
    torch
    npm
    yarn
    go-build
    go/mod
  )
  for d in "${cache_dirs[@]}"; do
    link_cache_to_local "${HOME}/.cache/${d}" "${SHARED_LOCAL_BASE}/.cache/${d}"
  done

  # Standalone data dirs that grow large
  link_cache_to_local "${HOME}/.local/share/uv"    "${SHARED_LOCAL_BASE}/.local/share/uv"
  link_cache_to_local "${HOME}/.conda"              "${SHARED_LOCAL_BASE}/.conda"
  link_cache_to_local "${HOME}/.triton"             "${SHARED_LOCAL_BASE}/.triton"
}

ensure_zsh_exists() {
  if need_cmd zsh; then
    log "zsh found: $(command -v zsh)"
    return 0
  fi
  warn "zsh not found. Trying to install without password..."
  try_install_pkgs_no_password zsh
  need_cmd zsh || { err "zsh is required but couldn't be installed without admin rights."; return 1; }
}

install_oh_my_zsh() {
  local omz_dir="${HOME}/.oh-my-zsh"
  local sentinel="${omz_dir}/oh-my-zsh.sh"

  # Validate installation health: directory must exist AND contain sentinel (P0-#3)
  if [[ -d "$omz_dir" ]]; then
    if [[ -f "$sentinel" ]]; then
      log "Oh My Zsh already installed."
      return 0
    fi
    warn "Oh My Zsh directory exists but sentinel missing ($sentinel). Re-installing."
    rm -rf "$omz_dir"
  fi

  log "Installing Oh My Zsh (unattended, no chsh)"
  export RUNZSH=no CHSH=no KEEP_ZSHRC=yes
  need_cmd curl || try_install_pkgs_no_password curl
  need_cmd curl || { err "curl not available; cannot install Oh My Zsh."; return 1; }
  download_and_run "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
}

# Add tmux + JetBrains/JediTerm fix block to ~/.zshrc (once)
add_tmux_jediterm_fix_to_zshrc() {
  local zshrc="${HOME}/.zshrc"
  local marker="ZSH_TMUX_JEDITERM_FIX"
  touch "$zshrc"

  local block
  block="$(cat <<'EOF'
# ---- ZSH_TMUX_JEDITERM_FIX ----
# tmux configuration - fix intellij terminal bug
# WezTerm adaptive leader key: signal tmux state via OSC 1337 user var
if [[ -n "$TMUX" ]]; then
  tmux set -g status-position top 2>/dev/null

  # Emit in_tmux=1 on startup (new sessions) and on every prompt (reattach)
  _wez_notify_tmux() {
    printf '\033Ptmux;\033\033]1337;SetUserVar=%s=%s\007\033\\' in_tmux "$(printf '1' | base64)"
  }
  _wez_notify_tmux
  precmd_functions+=(_wez_notify_tmux)

  # Fix JediTerm DA1 response leak (prints "6c" in prompt)
  # Only applies to IntelliJ/JediTerm terminal
  if [[ "$TERMINAL_EMULATOR" == "JetBrains-JediTerm" ]]; then
    while read -t 0.01 -k discard; do :; done
    clear
  fi
  # tmux set -g status-position bottom 2>/dev/null
else
  # Outer shell: detect tmux launch and clear on detach/exit
  _wez_detect_tmux() {
    case "$1" in
      tmux|tmux\ *) printf '\033]1337;SetUserVar=%s=%s\007' in_tmux "$(printf '1' | base64)" ;;
    esac
  }
  _wez_clear_tmux() {
    printf '\033]1337;SetUserVar=%s=%s\007' in_tmux "$(printf '0' | base64)"
  }
  preexec_functions+=(_wez_detect_tmux)
  precmd_functions+=(_wez_clear_tmux)
fi
# ---- /ZSH_TMUX_JEDITERM_FIX ----
EOF
)"
  append_block_if_missing "$zshrc" "$marker" "$block"
}

install_p10k_and_plugins() {
  local zsh_custom="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
  mkdir -p "$zsh_custom/plugins" "$zsh_custom/themes"

  need_cmd git || try_install_pkgs_no_password git
  need_cmd git || { err "git not available; cannot install OMZ plugins/themes."; return 1; }

  # Helper: clone or verify health of a git repo (P0-#3, P1-#10)
  _ensure_clone() {
    local dir="$1"
    local repo="$2"
    local tag="${3:-}"

    if [[ -d "$dir" ]]; then
      # Health check: verify the clone is intact
      if git -C "$dir" rev-parse HEAD >/dev/null 2>&1; then
        log "Already cloned: $dir"
        return 0
      fi
      warn "Broken clone detected at $dir — removing and re-cloning."
      rm -rf "$dir"
    fi

    local clone_args=(--depth=1)
    [[ -n "$tag" ]] && clone_args+=(--branch "$tag")
    git -c core.autocrlf=false clone "${clone_args[@]}" "$repo" "$dir"
  }

  _ensure_clone "$zsh_custom/themes/powerlevel10k" \
    "https://github.com/romkatv/powerlevel10k.git" "$P10K_TAG"

  _ensure_clone "$zsh_custom/plugins/zsh-autosuggestions" \
    "https://github.com/zsh-users/zsh-autosuggestions" "$ZSH_AUTOSUGG_TAG"

  _ensure_clone "$zsh_custom/plugins/zsh-syntax-highlighting" \
    "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$ZSH_SYNTAX_HL_TAG"

  local zshrc="${HOME}/.zshrc"
  touch "$zshrc"

  append_if_missing "$zshrc" '[[ -f ~/.config/shell/common.sh ]] && source ~/.config/shell/common.sh'
  append_if_missing "$zshrc" 'export ZSH="$HOME/.oh-my-zsh"'
  append_if_missing "$zshrc" 'ZSH_THEME="powerlevel10k/powerlevel10k"'
  append_if_missing "$zshrc" 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)'
  append_if_missing "$zshrc" 'source "$ZSH/oh-my-zsh.sh"'

  if ! grep -q 'ZSH_BASHRC_COMPAT' "$zshrc"; then
    cat >> "$zshrc" <<'EOF'

# ---- ZSH_BASHRC_COMPAT ----
# Some installers only append exports/PATH to ~/.bashrc. Keep zsh in sync.
if [[ -z "${ZSH_BASHRC_COMPAT:-}" ]]; then
  export ZSH_BASHRC_COMPAT=1
  [[ -f ~/.bashrc ]] && source ~/.bashrc
fi
EOF
  fi

  # p10k config — only overwrite if file doesn't already exist (P1-#12)
  if [[ -f "${HOME}/.p10k.zsh" ]]; then
    log "p10k config already exists (~/.p10k.zsh); leaving as-is."
  elif [[ -n "${P10K_CONFIG_PATH:-}" && -f "${P10K_CONFIG_PATH}" ]]; then
    cp "${P10K_CONFIG_PATH}" "${HOME}/.p10k.zsh"
  elif [[ -n "${P10K_CONFIG_URL:-}" ]]; then
    download_to "${P10K_CONFIG_URL}" "${HOME}/.p10k.zsh"
  else
    cat > "${HOME}/.p10k.zsh" <<'EOF'
# Minimal placeholder; replace with your own or run `p10k configure`
typeset -g POWERLEVEL9K_MODE=nerdfont-complete
EOF
  fi

  # Keep the p10k sourcing line
  append_if_missing "$zshrc" '[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh'

  # Add tmux + JetBrains/JediTerm fix block to ~/.zshrc
  add_tmux_jediterm_fix_to_zshrc
}

install_oh_my_tmux() {
  # Modern oh-my-tmux installs to ~/.local/share/tmux/oh-my-tmux/
  # and symlinks ~/.config/tmux/tmux.conf -> there.
  # Legacy installs used ~/.tmux/.tmux.conf.
  local sentinel="${HOME}/.config/tmux/tmux.conf"
  local legacy_sentinel="${HOME}/.tmux/.tmux.conf"

  # Validate: either modern or legacy sentinel must exist
  if [[ -f "$sentinel" ]] || [[ -f "$legacy_sentinel" ]]; then
    log "oh-my-tmux already installed."
    return 0
  fi

  # Directory exists but sentinel missing — broken install
  if [[ -d "${HOME}/.local/share/tmux/oh-my-tmux" ]]; then
    warn "oh-my-tmux data dir exists but sentinel missing. Re-installing."
    rm -rf "${HOME}/.local/share/tmux/oh-my-tmux"
  fi

  log "Installing oh-my-tmux (official installer)"
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to install oh-my-tmux"
    return 1
  fi

  # Use download_and_run instead of curl | bash; no cache-bust fragment (P2-#16, P1-#9)
  download_and_run "https://github.com/gpakosz/.tmux/raw/refs/heads/master/install.sh"
}

install_tmux_local_config() {
  local dest="${HOME}/.config/tmux/tmux.conf.local"

  if [[ -n "${TMUX_LOCAL_CONFIG_PATH:-}" && -f "${TMUX_LOCAL_CONFIG_PATH}" ]]; then
    log "Installing tmux local config from file"
    mkdir -p "$(dirname "$dest")"
    cp "$TMUX_LOCAL_CONFIG_PATH" "$dest"

  elif [[ -n "${TMUX_LOCAL_CONFIG_URL:-}" ]]; then
    log "Installing tmux local config from URL"
    download_to "$TMUX_LOCAL_CONFIG_URL" "$dest"

  else
    log "No tmux local config provided; leaving default."
    return 0
  fi

  chmod 0644 "$dest"

  # Set tmux default shell to zsh (resolved at install time)
  local zsh_path
  zsh_path="$(command -v zsh 2>/dev/null || echo "/bin/zsh")"
  local marker="TMUX_DEFAULT_SHELL"
  local block
  block="$(cat <<BLOCK
# ---- TMUX_DEFAULT_SHELL ----
# use zsh inside tmux (login shell may still be bash)
set -g default-shell "$zsh_path"
set -g default-command "$zsh_path"
# ---- /TMUX_DEFAULT_SHELL ----
BLOCK
)"
  append_block_if_missing "$dest" "$marker" "$block"

  # Removed destructive ln -sf that overwrote tmux.conf (P0-#2)
  # oh-my-tmux auto-sources tmux.conf.local; reload from correct path
  tmux source-file "${HOME}/.config/tmux/tmux.conf.local" 2>/dev/null || true
}

install_nvm_and_node() {
  local nvm_dir="${HOME}/.nvm"
  local sentinel="${nvm_dir}/nvm.sh"

  # Validate: directory AND sentinel must exist (P0-#3)
  if [[ -d "$nvm_dir" ]] && [[ ! -s "$sentinel" ]]; then
    warn "nvm directory exists but sentinel missing ($sentinel). Re-installing."
    rm -rf "$nvm_dir"
  fi

  if [[ ! -d "$nvm_dir" ]]; then
    need_cmd curl || try_install_pkgs_no_password curl
    need_cmd curl || { err "curl not available; cannot install nvm."; return 1; }
    # Use pinned NVM_VERSION and download_and_run (P1-#15, P1-#9)
    download_and_run "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  fi

  export NVM_DIR="$nvm_dir"
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"

  if need_cmd nvm; then
    nvm install --lts >/dev/null || warn "nvm install --lts failed (continuing)."
    nvm alias default 'lts/*' >/dev/null || true
  else
    warn "nvm not available in this session; open a new shell and run: nvm install --lts"
  fi
}

enable_bash_to_zsh_handoff() {
  local bashrc="${HOME}/.bashrc"
  touch "$bashrc"

  if grep -q 'BASH_TO_ZSH_HANDOFF' "$bashrc"; then
    log "bash->zsh handoff already configured."
    return 0
  fi

  log "Configuring bash to exec into zsh for interactive terminals (no chsh)"
  cat >> "$bashrc" <<'EOF'

# ---- BASH_TO_ZSH_HANDOFF ----
if [[ -z "${BASH_TO_ZSH_HANDOFF:-}" ]]; then
  export BASH_TO_ZSH_HANDOFF=1
  case $- in
    *i*)
      if command -v zsh >/dev/null 2>&1; then
        # Avoid loops if zsh sources bashrc
        if [[ -z "${ZSH_BASHRC_COMPAT:-}" ]]; then
          exec zsh -l
        fi
      fi
      ;;
  esac
fi
EOF
}

# --check mode: describe what would be done without making changes (P0-#6)
run_check_mode() {
  log "Running in --check mode (dry run)"
  echo
  echo "Installed version: $(cat "$INSTALL_STATE_FILE" 2>/dev/null || echo 'none')"
  echo "Script  version:   $INSTALL_VERSION"
  echo

  local checks=(
    "git:git"
    "curl:curl"
    "shared shell config:${HOME}/.config/shell/common.sh"
    "bashrc zsh-compat shim:BASHRC_ZSH_COMPAT_SHIM in ${HOME}/.bashrc"
    "timezone:TZ in ${HOME}/.config/shell/common.sh"
    "git credential store:cmd:git config --global credential.helper | grep -q store"
    "uv:uv"
    "zsh:zsh"
    "oh-my-zsh:${HOME}/.oh-my-zsh/oh-my-zsh.sh"
    "powerlevel10k:${HOME}/.oh-my-zsh/custom/themes/powerlevel10k"
    "zsh-autosuggestions:${HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    "zsh-syntax-highlighting:${HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
    "oh-my-tmux:${HOME}/.config/tmux/tmux.conf"
    "nvm:${HOME}/.nvm/nvm.sh"
    "yazi:yazi"
    "wezterm:wezterm"
  )

  for entry in "${checks[@]}"; do
    local label="${entry%%:*}"
    local target="${entry#*:}"

    local found=false
    if need_cmd "$label" 2>/dev/null; then
      found=true
    elif [[ "$target" == cmd:* ]]; then
      eval "${target#cmd:}" 2>/dev/null && found=true
    elif [[ "$target" == *" in "* ]]; then
      local marker="${target%% in *}"
      local file="${target#* in }"
      [[ -f "$file" ]] && grep -q "$marker" "$file" && found=true
    elif [[ -e "$target" ]]; then
      found=true
    fi
    if "$found"; then
      printf "  %-35s %s\n" "$label" "[OK]"
    else
      printf "  %-35s %s\n" "$label" "[MISSING — would install]"
    fi
  done

  # Cache symlink status
  echo
  echo "  Cache symlinks (/local):"
  local cache_dirs=(uv pip huggingface torch npm yarn go-build go/mod)
  for d in "${cache_dirs[@]}"; do
    local p="${HOME}/.cache/${d}"
    if [[ -L "$p" ]]; then
      printf "    %-33s %s\n" "~/.cache/$d" "[OK -> $(readlink "$p")]"
    elif [[ -d "$p" ]]; then
      printf "    %-33s %s\n" "~/.cache/$d" "[EXISTS — would migrate & link]"
    else
      printf "    %-33s %s\n" "~/.cache/$d" "[absent]"
    fi
  done
  local extra_dirs=("${HOME}/.local/share/uv" "${HOME}/.conda" "${HOME}/.triton")
  for p in "${extra_dirs[@]}"; do
    local short="${p/#"$HOME"/~}"
    if [[ -L "$p" ]]; then
      printf "    %-33s %s\n" "$short" "[OK -> $(readlink "$p")]"
    elif [[ -d "$p" ]]; then
      printf "    %-33s %s\n" "$short" "[EXISTS — would migrate & link]"
    else
      printf "    %-33s %s\n" "$short" "[absent]"
    fi
  done

  # CRLF check
  echo
  echo "  CRLF line endings (WSL fix):"
  local crlf_found=false
  local crlf_configs=(
    "${HOME}/.bashrc"
    "${HOME}/.zshrc"
    "${HOME}/.p10k.zsh"
    "${HOME}/.config/shell/common.sh"
  )
  for f in "${crlf_configs[@]}"; do
    local short="${f/#"$HOME"/~}"
    if [[ -f "$f" ]] && LC_ALL=C grep -q $'\r' "$f" 2>/dev/null; then
      printf "    %-33s %s\n" "$short" "[HAS CRLF — would fix]"
      crlf_found=true
    elif [[ -f "$f" ]]; then
      printf "    %-33s %s\n" "$short" "[OK]"
    fi
  done
  local zsh_custom="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
  local crlf_repos=(
    "${HOME}/.oh-my-zsh"
    "$zsh_custom/themes/powerlevel10k"
    "$zsh_custom/plugins/zsh-autosuggestions"
    "$zsh_custom/plugins/zsh-syntax-highlighting"
  )
  for r in "${crlf_repos[@]}"; do
    local short="${r/#"$HOME"/~}"
    if [[ -d "$r" ]] && [[ "$(git -C "$r" config --local core.autocrlf 2>/dev/null)" != "false" ]]; then
      printf "    %-33s %s\n" "$short" "[autocrlf not fixed — would fix]"
      crlf_found=true
    elif [[ -d "$r" ]]; then
      printf "    %-33s %s\n" "$short" "[OK]"
    fi
  done
  if ! $crlf_found; then
    echo "    (no CRLF issues detected)"
  fi

  echo
  if [[ -f "$INSTALL_STATE_FILE" ]] && [[ "$(cat "$INSTALL_STATE_FILE")" == "$INSTALL_VERSION" ]]; then
    log "Version $INSTALL_VERSION is already installed. Use --force to re-run."
  else
    log "Would run full install (version $INSTALL_VERSION)."
  fi
}

# ---------------------------------------------------------------------------
# CRLF fix: on WSL with git core.autocrlf=true, cloned files get \r\n line
# endings which break zsh init scripts (^M errors). This step:
#   1) strips \r from all managed shell config files
#   2) sets core.autocrlf=false in cloned zsh plugin repos and re-checks out
# Safe to run on any platform — LF-only files are left unchanged.
# ---------------------------------------------------------------------------
fix_line_endings() {
  log "Ensuring LF line endings in shell configs and plugins (CRLF/WSL fix) ..."

  # 1) Fix shell config files
  local configs=(
    "${HOME}/.bashrc"
    "${HOME}/.bash_profile"
    "${HOME}/.profile"
    "${HOME}/.zshrc"
    "${HOME}/.p10k.zsh"
    "${HOME}/.config/shell/common.sh"
    "${HOME}/.config/tmux/tmux.conf.local"
  )
  for f in "${configs[@]}"; do
    strip_cr "$f"
  done

  # 2) Fix git repos sourced by zsh
  local zsh_custom="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
  local repos=(
    "${HOME}/.oh-my-zsh"
    "$zsh_custom/themes/powerlevel10k"
    "$zsh_custom/plugins/zsh-autosuggestions"
    "$zsh_custom/plugins/zsh-syntax-highlighting"
  )
  for r in "${repos[@]}"; do
    fix_git_autocrlf "$r"
  done
}

main() {
  parse_args "$@"

  # Warn if running as root (P2-#19)
  [[ ${EUID:-$(id -u)} -eq 0 ]] && warn "Running as root is not recommended."

  # --check: dry-run mode (P0-#6)
  if $CHECK_MODE; then
    run_check_mode
    return 0
  fi

  # Version tracking: skip if already up-to-date unless --force (P0-#6)
  mkdir -p "$INSTALL_STATE_DIR"
  if [[ -f "$INSTALL_STATE_FILE" ]] && ! $FORCE_MODE; then
    local installed_version
    installed_version="$(cat "$INSTALL_STATE_FILE")"
    if [[ "$installed_version" == "$INSTALL_VERSION" ]]; then
      log "Already at version $INSTALL_VERSION. Use --force to re-run."
      return 0
    fi
    log "Upgrading from $installed_version to $INSTALL_VERSION"
  fi

  log "No-password setup: bash stays default; interactive terminals jump into zsh."

  need_cmd git  || try_install_pkgs_no_password git
  need_cmd curl || try_install_pkgs_no_password curl

  setup_shared_shell_config
  add_bashrc_zsh_compat_shim
  set_timezone
  setup_git_credential_store
  install_uv
  ensure_cache_symlinks
  setup_uv_aliases
  setup_ray_alias

  ensure_zsh_exists
  install_oh_my_zsh
  install_p10k_and_plugins
  install_oh_my_tmux
  install_tmux_local_config
  install_nvm_and_node
  install_yazi
  install_wezterm
  enable_bash_to_zsh_handoff
  fix_line_endings

  # Write version marker after successful completion (P0-#6)
  printf "%s" "$INSTALL_VERSION" > "$INSTALL_STATE_FILE"

  log "Done. (version $INSTALL_VERSION)"
  echo
  echo "What changes were made:"
  echo "  - bash remains your login shell (no chsh / no password)"
  echo "  - interactive bash now execs into: zsh -l"
  echo "  - both bash and zsh source: ~/.config/shell/common.sh"
  echo "  - zsh also sources ~/.bashrc (guarded) so installers that edit bashrc still apply"
  echo "  - zsh adds tmux + JetBrains/JediTerm fix (guarded, no duplicates)"
  echo
  echo "Next steps:"
  echo "  1) Open a NEW terminal (or run: source ~/.bashrc)"
  echo "  2) Verify:"
  echo "     - uv --version"
  echo "     - node -v && npm -v"
  echo "     - zsh --version"
  echo "     - tmux -V (if installed)"
  echo "     - yazi --version"
  echo "     - wezterm --version"
  echo "  3) If you didn't provide a p10k config, run: p10k configure"
}

main "$@"
