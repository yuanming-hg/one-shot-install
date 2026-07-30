#!/usr/bin/env bash
# pack.sh — Bundle install.sh + config files into a single self-extracting script.
#
# Usage: bash pack.sh > install-standalone.sh
#
# The output can be uploaded to a gist and run with:
#   curl -fsSL <url> | bash
#   curl -fsSL <url> | bash -s -- --check
#   curl -fsSL <url> | bash -s -- --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILES=(
  "install.sh"
  "p10k.zsh"
  "tmux.config.local"
)

# Verify all files exist
for f in "${FILES[@]}"; do
  if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
    echo >&2 "Error: ${SCRIPT_DIR}/${f} not found"
    exit 1
  fi
done

# --- Emit the self-extracting script ---
cat <<'HEADER'
#!/usr/bin/env bash
# =============================================================================
# Self-contained installer (packed by pack.sh)
# Works with: curl -fsSL <url> | bash
#             curl -fsSL <url> | bash -s -- --check
#             curl -fsSL <url> | bash -s -- --force
# =============================================================================
set -euo pipefail

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

HEADER

# --- Emit each file as a base64 shell variable ---
for f in "${FILES[@]}"; do
  marker="$(echo "${f}" | tr '[:lower:].' '[:upper:]_' | sed 's/[-.]/_/g')"
  echo "_PAYLOAD_${marker}=\"\\"
  # Normalise line wrapping: GNU base64 wraps at 76, macOS/BSD emits one long
  # line. Without this the packed output churns by ~3000 lines depending on
  # which machine ran pack.sh.
  base64 < "${SCRIPT_DIR}/${f}" | tr -d '\n' | fold -w 76
  echo          # fold emits no trailing newline; keep the closing quote on its own line
  echo "\""
  echo
done

# --- Emit the extraction + run logic ---
cat <<'FOOTER'
# --- Extract embedded files ---
printf '%s' "$_PAYLOAD_INSTALL_SH"      | base64 -d > "$_tmpdir/install.sh"
printf '%s' "$_PAYLOAD_P10K_ZSH"        | base64 -d > "$_tmpdir/p10k.zsh"
printf '%s' "$_PAYLOAD_TMUX_CONFIG_LOCAL" | base64 -d > "$_tmpdir/tmux.config.local"

chmod +x "$_tmpdir/install.sh"

# --- Run the installer ---
bash "$_tmpdir/install.sh" "$@"
FOOTER
