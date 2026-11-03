
#!/usr/bin/env bash

set -Eeuo pipefail

STRFRY_BIN="${STRFRY_BIN:-/usr/local/bin/strfry}"
STRFRY_CONFIG="${STRFRY_CONFIG:-/etc/strfry.conf}"
ROUTER_CONFIG="${ROUTER_CONFIG:-/etc/strfry-router.conf}"

SYNC_PEERS="${SYNC_PEERS:-}"
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-900}"

RELAY_PID=""
ROUTER_PID=""
SYNC_PID=""
SCHEDULER_PID=""

log() {
    echo "[$(date -Iseconds)] $*"
}

shutdown() {
    log "Stopping relay node..."

    trap - EXIT SIGTERM SIGINT

    for pid in "$SCHEDULER_PID" "$SYNC_PID" "$ROUTER_PID" "$RELAY_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    for pid in "$SCHEDULER_PID" "$SYNC_PID" "$ROUTER_PID" "$RELAY_PID"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null || true
        fi
    done

    log "Relay node stopped."
}

trap shutdown EXIT
trap 'exit 143' SIGTERM
trap 'exit 130' SIGINT

# Validate configuration.
[[ -x "$STRFRY_BIN" ]] || {
    log "ERROR: strfry binary not executable: $STRFRY_BIN"
    exit 1
}

[[ -r "$STRFRY_CONFIG" ]] || {
    log "ERROR: relay config not found: $STRFRY_CONFIG"
    exit 1
}

[[ -r "$ROUTER_CONFIG" ]] || {
    log "ERROR: router config not found: $ROUTER_CONFIG"
    exit 1
}

export STRFRY_CONFIG

# Start local relay.
log "Starting strfry relay..."
"$STRFRY_BIN" relay &
RELAY_PID=$!

# Wait for local WebSocket listener.
wait_for_tcp() {
    local host="$1"
    local port="$2"
    local timeout="$3"
    local start=$SECONDS

    while (( SECONDS - start < timeout )); do
        kill -0 "$RELAY_PID" 2>/dev/null || return 1

        if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    return 1
}

log "Waiting for local relay..."

if ! wait_for_tcp 127.0.0.1 7777 60; then
    log "ERROR: local relay did not become ready."
    exit 1
fi

log "Local relay is ready."

# Run initial synchronization.
sync_peers() {
    local peer

    for peer in "${PEERS[@]}"; do
        log "Synchronizing with $peer"

        if "$STRFRY_BIN" sync "$peer" --dir=both; then
            log "Synchronization completed: $peer"
        else
            local status=$?
            log "WARNING: Synchronization failed: $peer (status: $status)"
        fi
    done
}

read -r -a PEERS <<< "$SYNC_PEERS"

# Initial reconciliation.
if [[ -n "$SYNC_PEERS" ]]; then
    sync_peers
fi

# Start continuous router.
log "Starting strfry router..."
"$STRFRY_BIN" router "$ROUTER_CONFIG" &
ROUTER_PID=$!

# Periodic synchronization.
periodic_sync() {
    while true; do
        sleep "$SYNC_INTERVAL_SECONDS"

        log "Starting periodic reconciliation..."

        sync_peers

        log "Periodic reconciliation completed."
    done
}

if [[ -n "$SYNC_PEERS" ]]; then
    log "Starting periodic sync scheduler (${SYNC_INTERVAL_SECONDS}s)"
    periodic_sync &
    SCHEDULER_PID=$!
fi

log "Relay PID: $RELAY_PID"
log "Router PID: $ROUTER_PID"
log "Scheduler PID: ${SCHEDULER_PID:-disabled}"
log "Relay node is running."

# Stop the node if a critical process exits.
set +e
wait -n "$RELAY_PID" "$ROUTER_PID"
STATUS=$?
set -e

log "Relay or router exited (status: $STATUS)."
exit "$STATUS"
