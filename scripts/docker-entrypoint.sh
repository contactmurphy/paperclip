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

  # Always fix volume permissions — previous deployments may have written as root
  chown -R node:node /paperclip

  exec gosu node "$@"
else
  # Already running as non-root (USER node in Dockerfile)
  # Ensure /paperclip directory structure exists
  mkdir -p /paperclip/instances 2>/dev/null || true
  exec "$@"
fi
