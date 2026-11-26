#!/bin/sh
# keygen.sh — runs ONCE per `docker compose up` inside the keygen container.
# Writes into the mounted /keys directory (KEYS_DIR, a tmpfs):
#   api_key   — raw key for llama-server (--api-key-file)
#   auth.conf — nginx snippet: proxy_set_header Authorization "Bearer <key>"
# Exits nonzero on any failure so dependents never start with a stale/absent key.
#
# Runs as uid 1000 (compose `user:`) — the same uid that owns the tmpfs and
# the same uid llama-server reads the key as.

set -eu

umask 022

# --- Preflight ------------------------------------------------------------
# The placeholder files must exist BEFORE `docker compose up` creates the
# service containers (single-file bind mounts need their source at creation
# time). If they were created with `sudo touch`, they are root-owned and the
# truncate-write below fails with EACCES — fail here with the fix instead.
for f in /keys/api_key /keys/auth.conf; do
    if [ -e "$f" ] && [ ! -w "$f" ]; then
        echo "keygen: FATAL — $f exists but is not writable by uid $(id -u)" >&2
        echo "  Likely cause: placeholders were created with 'sudo touch' (root-owned)." >&2
        echo "  Fix on the host:  sudo rm $f && touch $f    (second touch WITHOUT sudo)" >&2
        exit 1
    fi
done

# --- Generate ---------------------------------------------------------------
# 32 bytes of entropy, base64, strip non-alphanumerics (busybox base64
# emits no wrapping; tr handles padding and the two non-URL chars).
KEY="$(head -c 32 /dev/urandom | base64 | tr -d '=+/')"

# sanity: a key that came out empty or too short must fail the startup
if [ "${#KEY}" -lt 32 ]; then
    echo "keygen: FATAL — generated key too short (${#KEY} chars)" >&2
    exit 1
fi

# --- Write (truncate, preserving the inode) ---------------------------------
# compose created llama-server/llama-ui with bind mounts pointing at THESE
# files' inodes. Unlinking/recreating would leave those mounts aimed at a
# deleted inode (containers would see empty files). `printf >` truncates in
# place — the mounts stay valid and receive the fresh content.
printf '%s' "$KEY" > /keys/api_key
printf 'proxy_set_header Authorization "Bearer %s";\n' "$KEY" > /keys/auth.conf

# --- Verify -------------------------------------------------------------------
[ -s /keys/api_key ]   || { echo "keygen: FATAL — api_key empty" >&2; exit 1; }
[ -s /keys/auth.conf ] || { echo "keygen: FATAL — auth.conf empty" >&2; exit 1; }

echo "keygen: wrote fresh api_key + auth.conf ($(stat -c%s /keys/api_key) bytes)"
