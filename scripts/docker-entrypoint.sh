#!/bin/sh
set -e

# If running as root, do the UID/GID remapping and use gosu
if [ "$(id -u)" = "0" ]; then
    PUID=${USER_UID:-1000}
        PGID=${USER_GID:-1000}

            changed=0
                if [ "$(id -u node)" -ne "$PUID" ]; then
                        echo "Updating node UID to $PUID"
                                usermod -o -u "$PUID" node
                                        changed=1
                                            fi

                                                if [ "$(id -g node)" -ne "$PGID" ]; then
                                                        echo "Updating node GID to $PGID"
                                                                groupmod -o -g "$PGID" node
                                                                        usermod -g "$PGID" node
                                                                                changed=1
                                                                                    fi

                                                                                        if [ "$changed" = "1" ]; then
                                                                                                chown -R node:node /paperclip
                                                                                                    fi
                                                                                                    
                                                                                                        exec gosu node "$@"
                                                                                                        else
                                                                                                            # Already running as non-root (USER node in Dockerfile)
                                                                                                                # Ensure /paperclip directory structure exists
                                                                                                                    mkdir -p /paperclip/instances 2>/dev/null || true
                                                                                                                        exec "$@"
                                                                                                                        fi
