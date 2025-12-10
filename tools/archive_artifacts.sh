#!/usr/bin/env bash
# Tarball everything under out/artifacts and optionally scp it back to your SSH
# client. If you pass a target, that is used verbatim (user@host or
# user@host:/path). With no arg, the script requires $SSH_CLIENT to infer the
# host and will ask for the remote username unless $SCP_USER is set. Port is
# derived from $SSH_CLIENT when available.
# Usage: archive_artifacts.sh [user@host|user@host:/dest/path/artifacts.tar.gz]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT/out/artifacts"}"
OUT_TAR="${OUT_TAR:-"$ROOT/out/artifacts.tar.gz"}"
DEST_INPUT="${1:-}"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "artifact dir not found: $ARTIFACT_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_TAR")"
echo "[tar] $ARTIFACT_DIR -> $OUT_TAR"
tar -czf "$OUT_TAR" -C "$ARTIFACT_DIR" .

DEST_TARGET=""
if [[ -n "$DEST_INPUT" ]]; then
  if [[ "$DEST_INPUT" == *:* ]]; then
    DEST_TARGET="$DEST_INPUT"
  else
    DEST_TARGET="${DEST_INPUT}:~/artifacts.tar.gz"
  fi
else
  if [[ -z "${SSH_CLIENT:-}" ]]; then
    echo "[warn] SSH_CLIENT not set; no auto-scp target. Provide user@host or set SSH_CLIENT/SCP_USER." >&2
  else
    client_host="${SSH_CLIENT%% *}"
    client_port="$(echo "$SSH_CLIENT" | awk '{print $2}')"
    dest_user="${SCP_USER:-}"
    if [[ -z "$dest_user" ]]; then
      read -r -p "[prompt] remote username for ${client_host} (blank to skip scp): " dest_user
    fi
    if [[ -n "$dest_user" ]]; then
      DEST_TARGET="${dest_user}@${client_host}:~/artifacts.tar.gz"
      SCP_OPTS=()
      if [[ -n "$client_port" ]]; then
        SCP_OPTS+=("-P" "$client_port")
      fi
    fi
  fi
fi

if [[ -n "$DEST_TARGET" ]]; then
  echo "[scp] $OUT_TAR -> $DEST_TARGET"
  if scp "${SCP_OPTS[@]:-}" "$OUT_TAR" "$DEST_TARGET"; then
    echo "[scp] complete"
  else
    echo "[scp] failed" >&2
    exit 2
  fi
fi
