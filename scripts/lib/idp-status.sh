#!/bin/bash
# =============================================================================
# IDP Status Check (Granular)
# =============================================================================
# Shows the current status of all IDP stack components.
#
# Usage: ./idp-status.sh [--remote <host>]
# =============================================================================

set -euo pipefail

KC_CONTAINER="keycloak-lxc"
PG_CONTAINER="postgres-lxc"
REMOTE_HOST=""

[[ "${1:-}" == "--remote" ]] && REMOTE_HOST="${2:-}"

run_cmd() {
    if [[ -n "${REMOTE_HOST}" ]]; then
        ssh sysadmin@${REMOTE_HOST} "$1"
    else
        eval "$1"
    fi
}

THIS_HOST="${REMOTE_HOST:-$(hostname -s)}"

echo "=============================================="
echo "    IDP Stack Status: ${THIS_HOST}"
echo "=============================================="

# PostgreSQL status
echo ""
echo "=== PostgreSQL ==="
# Check if container exists first
if ! lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    PG_RUNNING="container-missing"
elif lxc exec ${PG_CONTAINER} -- pg_isready >/dev/null 2>&1; then
    PG_RUNNING="running"
else
    PG_RUNNING="stopped"
fi

if [[ "${PG_RUNNING}" == "running" ]]; then
    echo "  Service:  RUNNING"
    PG_ROLE=$(run_cmd "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;\"" 2>/dev/null || echo "unknown")
    echo "  Role:     ${PG_ROLE}"
    
    if [[ "${PG_ROLE}" == "STANDBY" ]]; then
        run_cmd "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT pg_last_wal_receive_lsn() as receive, pg_last_wal_replay_lsn() as replay;\"" 2>/dev/null | sed 's/^/  Replication: /'
    elif [[ "${PG_ROLE}" == "PRIMARY" ]]; then
        REPL_COUNT=$(run_cmd "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT count(*) FROM pg_stat_replication;\"" 2>/dev/null || echo "0")
        echo "  Standbys: ${REPL_COUNT}"
    fi
elif [[ "${PG_RUNNING}" == "container-missing" ]]; then
    echo "  Status:   CONTAINER NOT FOUND"
else
    echo "  Service:  STOPPED"
fi

# Keycloak status
echo ""
echo "=== Keycloak ==="
KC_RUNNING=$(run_cmd "lxc exec ${KC_CONTAINER} -- systemctl is-active keycloak 2>/dev/null || echo 'stopped'" 2>/dev/null || echo "container-missing")

if [[ "${KC_RUNNING}" == "active" ]]; then
    echo "  Service:  RUNNING"
    DB_URL=$(run_cmd "lxc exec ${KC_CONTAINER} -- grep 'db-url' /opt/keycloak/conf/keycloak.conf 2>/dev/null | sed 's/db-url=//' " 2>/dev/null || echo "unknown")
    echo "  Database: ${DB_URL}"
elif [[ "${KC_RUNNING}" == "container-missing" ]]; then
    echo "  Status:   CONTAINER NOT FOUND"
else
    echo "  Service:  STOPPED"
fi

# Traefik status (check if in load balancer)
# Note: Requires SSH keys from this host to sec nodes
echo ""
echo "=== Traefik Load Balancer ==="
case "${THIS_HOST}" in
    idp001|idp01) CHECK_FQDN="idp01.outliertechnology.co.uk" ;;
    idp002|idp02) CHECK_FQDN="idp02.outliertechnology.co.uk" ;;
    *) CHECK_FQDN="" ;;
esac

if [[ -n "${CHECK_FQDN}" ]]; then
    for TN in sec001 sec002; do
        # Try SSH, skip if no connectivity
        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no sysadmin@${TN} "test -f /srv/security-stack/systems/traefik/dynamic/keycloak.yml" 2>/dev/null; then
            if ssh -o ConnectTimeout=3 -o BatchMode=yes sysadmin@${TN} "grep -q '${CHECK_FQDN}' /srv/security-stack/systems/traefik/dynamic/keycloak.yml" 2>/dev/null; then
                echo "  ${TN}: YES (in load balancer)"
            else
                echo "  ${TN}: NO (not in load balancer)"
            fi
        else
            echo "  ${TN}: (no SSH access - check manually)"
        fi
    done
fi

echo ""
echo "=============================================="

