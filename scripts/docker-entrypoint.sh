#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Without root we can neither remap the node user (usermod/groupmod/chown)
# nor switch users (gosu needs CAP_SETUID/CAP_SETGID), so exec directly.
# This covers Kubernetes restricted PodSecurity (runAsNonRoot + runAsUser)
# as well as platforms that assign arbitrary UIDs (e.g. OpenShift); for the
# latter a UID/GID mismatch is unfixable here, so warn instead of letting
# usermod fail cryptically and keep volume-permission issues diagnosable.
if [ "$(id -u)" -ne 0 ]; then
    if [ "$(id -u)" -ne "$PUID" ] || [ "$(id -g)" -ne "$PGID" ]; then
        echo "docker-entrypoint.sh: running unprivileged as $(id -u):$(id -g); cannot remap to requested ${PUID}:${PGID}" >&2
    fi
    exec "$@"
fi

# Adjust the node user's UID/GID if they differ from the runtime request
if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
fi

# Ensure the app home is owned by the runtime user BEFORE dropping
# privileges -- not only after a UID/GID remap. A freshly mounted volume
# (Docker named volume, Railway volume, Kubernetes PV) arrives root-owned
# and shadows the image's build-time chown, so with the default UID the old
# remap-only condition dropped privileges onto an unwritable home and the
# server crashed on its first mkdir. The probe is a first-mismatch find
# over the WHOLE tree (uid and gid): a root-owned mount or descendant
# (init containers, backup restores, files written before a remap) is
# found immediately and repaired recursively, a GID-only remap is caught,
# and a fully-correct tree costs one metadata-only walk with no chown.
home_dir="${PAPERCLIP_HOME:-/paperclip}"
if [ -d "$home_dir" ] && [ -n "$(find "$home_dir" \( ! -user node -o ! -group node \) -print -quit 2>/dev/null)" ]; then
    chown -R node:node "$home_dir"
fi

# --- Fork-local: disk-exhaustion prevention (Railway volume is fixed-size) ---
# Retained across the 2026-08 upstream sync. Upstream has no equivalent, and
# this container previously filled its volume and hit ENOSPC. The Paperclip
# backup-retention routines that would otherwise cover this are PAUSED under
# the cost hold, so this entrypoint is the only active disk protection.
# Runs as root, before dropping privileges, so it can remove node-owned files.

# Prune run logs older than 7 days, for every instance
for instance_dir in "$home_dir"/instances/*; do
    RUN_LOG_DIR="${instance_dir}/data/run-logs"
    if [ -d "$RUN_LOG_DIR" ]; then
        echo "Cleaning logs in $RUN_LOG_DIR"
        find "$RUN_LOG_DIR" -type f -mtime +7 -delete 2>/dev/null || true
    fi
done

# Prune oversized Claude Code caches (>50MB) that accumulate per agent
for AGENT_DIR in "$home_dir"/instances/*/agents/*/; do
    if [ -d "${AGENT_DIR}.claude" ]; then
        CACHE_SIZE=$(du -sm "${AGENT_DIR}.claude" 2>/dev/null | cut -f1)
        if [ "${CACHE_SIZE:-0}" -gt 50 ]; then
            echo "Pruning large .claude cache (${CACHE_SIZE}MB) in $AGENT_DIR"
            rm -rf "${AGENT_DIR}.claude/cache" 2>/dev/null || true
        fi
    fi
done

USED=$(du -sm "$home_dir" 2>/dev/null | cut -f1)
echo "Volume $home_dir usage: ${USED}MB"

# --- Fork-local: cortex-brains reconcile loop (replaces the dead cron) ---
# The image ships no cron daemon, so the 60s brains sync has no runner: agent
# write-backs push themselves, but edits made in Obsidian/GitHub never reach the
# container, and agents boot on stale instructions. This backgrounds the same
# reconcile script the old crontab called. It survives redeploys because it
# lives in the image, not in a hand-installed crontab (which is what silently
# disappeared when the container was rebuilt).
#
# Runs as `node`: the script writes to the repo and uses the repo-local git
# credential helper. flock inside the script prevents ticks from stacking.
BRAINS_DIR="$home_dir/cortex-brains"
RECONCILE_SH="$BRAINS_DIR/scripts/cortex-reconcile.sh"
if [ -x "$RECONCILE_SH" ]; then
    RECONCILE_LOG="$BRAINS_DIR/.cron-logs/reconcile.log"
    mkdir -p "$BRAINS_DIR/.cron-logs" 2>/dev/null || true
    chown node:node "$BRAINS_DIR/.cron-logs" 2>/dev/null || true
    (
        while true; do
            sleep 60
            # Keep the log bounded — nothing else rotates it.
            if [ -f "$RECONCILE_LOG" ] && \
               [ "$(wc -c < "$RECONCILE_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
                : > "$RECONCILE_LOG"
            fi
            gosu node "$RECONCILE_SH" "$BRAINS_DIR" >> "$RECONCILE_LOG" 2>&1 || true
        done
    ) &
    echo "docker-entrypoint.sh: cortex-brains reconcile loop started (every 60s)"
else
    echo "docker-entrypoint.sh: no cortex-brains reconcile script at $RECONCILE_SH; sync loop NOT started" >&2
fi
# --- end fork-local ---

exec gosu node "$@"
