#!/usr/bin/env bash
# Macro IME offline bundle installer.
#
# This script is included only in the offline distribution bundle. It verifies
# the bundled language model, then delegates the actual installation to the
# existing install.sh without changing that installer.
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LM_FILE="${SRC}/offline-model/zh_CN.lm"
LM_PREDICT_FILE="${LM_FILE}.predict"
LM_SHA256="db220323580ea69aa8efce1b6e5752db6ae847b3e13f65a22195b37d9f710132"
LM_PREDICT_SHA256="087c3d65016a633fcd61e302a4c7724948b669f34cb5d3448da1b822b7370d7c"

die() {
  printf 'macro-ime offline bundle: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# *//'
  printf '\nUsage: %s [--help|--undo]\n' "$0"
}

case "${1:-}" in
  "") ;;
  --help|-h)
    usage
    exit 0
    ;;
  --undo)
    [[ -x "${SRC}/install.sh" ]] || die "install.sh is missing from this bundle"
    exec "${SRC}/install.sh" --undo
    ;;
  *)
    die "only --help and --undo are supported; run ./install.sh --help for advanced options"
    ;;
esac

[[ -x "${SRC}/install.sh" ]] || die "install.sh is missing from this bundle"
[[ -f "$LM_FILE" ]] || die "bundled language model is missing: $LM_FILE"
[[ -f "$LM_PREDICT_FILE" ]] || die "bundled prediction index is missing: $LM_PREDICT_FILE"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

verify_asset() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || {
    printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
    die "bundled ${label} failed SHA-256 verification"
  }
}

printf 'macro-ime: verifying offline language model…\n'
verify_asset "$LM_FILE" "$LM_SHA256" "${LM_FILE##*/}"
verify_asset "$LM_PREDICT_FILE" "$LM_PREDICT_SHA256" "${LM_PREDICT_FILE##*/}"
printf 'macro-ime: bundled model verified\n'
printf 'macro-ime: starting offline installation (no network required)\n'

# --lm-file makes the existing installer use the bundled files. --offline is
# retained as a guard against any unexpected fallback to a network download.
exec "${SRC}/install.sh" --lm-file "$LM_FILE" --offline
