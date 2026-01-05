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
PG_RUNNING=$(run_cmd "lxc exec ${PG_CONTAINER} -- pg_isready 2>/dev/null && echo 'running' || echo 'stopped'" 2>/dev/null || echo "container-missing")

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
echo ""
echo "=== Traefik Load Balancer ==="
case "${THIS_HOST}" in
    idp001|idp01) CHECK_FQDN="idp01.outliertechnology.co.uk" ;;
    idp002|idp02) CHECK_FQDN="idp02.outliertechnology.co.uk" ;;
    *) CHECK_FQDN="" ;;
esac

if [[ -n "${CHECK_FQDN}" ]]; then
    for TN in sec001 sec002; do
        IN_LB=$(ssh -o ConnectTimeout=3 -o BatchMode=yes sysadmin@${TN} "grep -q '${CHECK_FQDN}' /srv/security-stack/systems/traefik/dynamic/keycloak.yml && echo 'YES' || echo 'NO'" 2>/dev/null || echo "unreachable")
        echo "  ${TN}: ${IN_LB}"
    done
fi

echo ""
echo "=============================================="

