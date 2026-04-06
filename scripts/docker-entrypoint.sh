#!/bin/sh
set -e

# If running as root, do the UID/GID remapping and use gosu
if [ "$(id -u)" = "0" ]; then
  PUID=${USER_UID:-1000}
  PGID=${USER_GID:-1000}

  if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
  fi

  if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
  fi

  # Clean up old run logs to prevent ENOSPC (volume full)
  # Keeps last 24h of logs, removes everything older
  RUN_LOGS="/paperclip/instances/default/data/run-logs"
  if [ -d "$RUN_LOGS" ]; then
    OLD_COUNT=$(find "$RUN_LOGS" -type f -mmin +1440 2>/dev/null | wc -l)
    if [ "$OLD_COUNT" -gt 0 ]; then
      echo "Cleaning up $OLD_COUNT old run log files..."
      find "$RUN_LOGS" -type f -mmin +1440 -delete 2>/dev/null || true
      find "$RUN_LOGS" -type d -empty -delete 2>/dev/null || true
    fi
  fi

  # Clean up Claude Code temp/cache files that accumulate
  for AGENT_DIR in /paperclip/instances/*/agents/*/; do
    if [ -d "${AGENT_DIR}.claude" ]; then
      CACHE_SIZE=$(du -sm "${AGENT_DIR}.claude" 2>/dev/null | cut -f1)
      if [ "${CACHE_SIZE:-0}" -gt 50 ]; then
        echo "Pruning large .claude cache (${CACHE_SIZE}MB) in $AGENT_DIR"
        rm -rf "${AGENT_DIR}.claude/cache" 2>/dev/null || true
      fi
    fi
  done

  # Report disk usage
  USED=$(du -sm /paperclip 2>/dev/null | cut -f1)
  echo "Volume /paperclip usage: ${USED}MB"

  # Always fix volume permissions — previous deployments may have written as root
  chown -R node:node /paperclip

  exec gosu node "$@"
else
  # Already running as non-root (USER node in Dockerfile)
  # Ensure /paperclip directory structure exists
  mkdir -p /paperclip/instances 2>/dev/null || true
  exec "$@"
fi
