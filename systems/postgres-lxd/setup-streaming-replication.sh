#!/bin/bash
# =============================================================================
# PostgreSQL Streaming Replication Setup
# =============================================================================
# This script configures streaming replication between two PostgreSQL nodes.
#
# Usage:
#   On PRIMARY (idp001): ./setup-streaming-replication.sh --primary
#   On STANDBY (idp002): ./setup-streaming-replication.sh --standby
#
# Prerequisites:
#   - PostgreSQL running in LXD container (postgres-lxc)
#   - Network connectivity between nodes
#   - Run PRIMARY setup first, then STANDBY
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
CONTAINER_NAME="postgres-lxc"
PG_VERSION="16"  # Adjust if different
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_CONF="/etc/postgresql/${PG_VERSION}/main"
REPL_USER="replicator"
REPL_PASSWORD="${REPL_PASSWORD:-$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)}"

# Network - adjust these to match your environment
PRIMARY_HOST="idp01.outliertechnology.co.uk"
STANDBY_HOST="idp02.outliertechnology.co.uk"
PRIMARY_IP="192.168.1.13"
STANDBY_IP="192.168.1.14"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--primary | --standby]

Configure PostgreSQL streaming replication.

Options:
    --primary       Configure this node as the PRIMARY (run first)
    --standby       Configure this node as the STANDBY (run second)
    --check         Check replication status
    --promote       Promote standby to primary (failover)
    -h, --help      Show this help

Environment Variables:
    REPL_PASSWORD   Password for replication user (generated if not set)

EOF
    exit 1
}

# =============================================================================
# PRIMARY SETUP
# =============================================================================
setup_primary() {
    log "Configuring PRIMARY node for streaming replication..."
    
    # Check we're on the right node
    if ! lxc info ${CONTAINER_NAME} >/dev/null 2>&1; then
        error "Container ${CONTAINER_NAME} not found. Are you on the primary node?"
        exit 1
    fi
    
    # Step 1: Create replication user
    log "Creating replication user '${REPL_USER}'..."
    lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -c \
        "DO \$\$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
                CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
            ELSE
                ALTER ROLE ${REPL_USER} WITH PASSWORD '${REPL_PASSWORD}';
            END IF;
        END \$\$;"
    log "Replication user created/updated"
    
    # Step 2: Configure postgresql.conf for replication
    log "Configuring postgresql.conf..."
    
    # Check current settings
    CURRENT_WAL_LEVEL=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SHOW wal_level;")
    
    if [[ "${CURRENT_WAL_LEVEL}" != "replica" && "${CURRENT_WAL_LEVEL}" != "logical" ]]; then
        log "Setting wal_level = replica (currently: ${CURRENT_WAL_LEVEL})"
        lxc exec ${CONTAINER_NAME} -- bash -c "cat >> ${PG_CONF}/conf.d/replication.conf << 'PGCONF'
# Streaming Replication Configuration
# Added by setup-streaming-replication.sh

wal_level = replica
max_wal_senders = 5
wal_keep_size = 1GB
hot_standby = on
synchronous_commit = on

# Allow standby to handle queries
hot_standby_feedback = on
PGCONF"
        RESTART_REQUIRED=1
    else
        log "wal_level already set to ${CURRENT_WAL_LEVEL}"
        RESTART_REQUIRED=0
    fi
    
    # Step 3: Configure pg_hba.conf for replication connections
    log "Configuring pg_hba.conf for replication access..."
    
    # Check if replication entry exists
    if ! lxc exec ${CONTAINER_NAME} -- grep -q "replication.*${REPL_USER}" ${PG_CONF}/pg_hba.conf; then
        lxc exec ${CONTAINER_NAME} -- bash -c "cat >> ${PG_CONF}/pg_hba.conf << 'PGHBA'

# Streaming Replication - allow standby to connect
# Added by setup-streaming-replication.sh
host    replication     ${REPL_USER}    ${STANDBY_IP}/32    scram-sha-256
host    replication     ${REPL_USER}    172.22.0.0/24       scram-sha-256
PGHBA"
        RESTART_REQUIRED=1
        log "Added replication entries to pg_hba.conf"
    else
        log "Replication entries already exist in pg_hba.conf"
    fi
    
    # Step 4: Ensure listen_addresses allows remote connections
    CURRENT_LISTEN=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SHOW listen_addresses;")
    if [[ "${CURRENT_LISTEN}" == "localhost" ]]; then
        log "Updating listen_addresses to allow remote connections..."
        lxc exec ${CONTAINER_NAME} -- bash -c "echo \"listen_addresses = '*'\" >> ${PG_CONF}/conf.d/replication.conf"
        RESTART_REQUIRED=1
    fi
    
    # Step 5: Restart PostgreSQL if needed
    if [[ "${RESTART_REQUIRED:-0}" -eq 1 ]]; then
        log "Restarting PostgreSQL to apply changes..."
        lxc exec ${CONTAINER_NAME} -- systemctl restart postgresql
        sleep 3
    fi
    
    # Step 6: Verify PostgreSQL is running
    if lxc exec ${CONTAINER_NAME} -- pg_isready -q; then
        log "PostgreSQL is running and ready"
    else
        error "PostgreSQL failed to start. Check logs:"
        error "lxc exec ${CONTAINER_NAME} -- journalctl -u postgresql -n 50"
        exit 1
    fi
    
    echo ""
    echo "=============================================="
    echo "    PRIMARY SETUP COMPLETE"
    echo "=============================================="
    echo ""
    echo "Replication user: ${REPL_USER}"
    echo "Replication password: ${REPL_PASSWORD}"
    echo ""
    echo "IMPORTANT: Save this password! You'll need it for standby setup."
    echo ""
    echo "Next step: Run on STANDBY node (idp002):"
    echo "  export REPL_PASSWORD='${REPL_PASSWORD}'"
    echo "  ./setup-streaming-replication.sh --standby"
    echo ""
}

# =============================================================================
# STANDBY SETUP
# =============================================================================
setup_standby() {
    log "Configuring STANDBY node for streaming replication..."
    
    if [[ -z "${REPL_PASSWORD:-}" ]]; then
        error "REPL_PASSWORD environment variable not set!"
        error "Get the password from the primary setup output and run:"
        error "  export REPL_PASSWORD='<password>'"
        error "  ./setup-streaming-replication.sh --standby"
        exit 1
    fi
    
    # Check we're on the right node
    if ! lxc info ${CONTAINER_NAME} >/dev/null 2>&1; then
        error "Container ${CONTAINER_NAME} not found. Are you on the standby node?"
        exit 1
    fi
    
    # Step 1: Test connection to primary
    log "Testing connection to primary (${PRIMARY_HOST})..."
    if ! lxc exec ${CONTAINER_NAME} -- pg_isready -h ${PRIMARY_HOST} -p 5432; then
        error "Cannot connect to primary PostgreSQL at ${PRIMARY_HOST}:5432"
        error "Ensure:"
        error "  1. Primary is running"
        error "  2. Firewall allows connections"
        error "  3. pg_hba.conf on primary allows this host"
        exit 1
    fi
    log "Primary is reachable"
    
    # Step 2: Stop PostgreSQL on standby
    log "Stopping PostgreSQL on standby..."
    lxc exec ${CONTAINER_NAME} -- systemctl stop postgresql
    
    # Step 3: Backup existing data directory (just in case)
    log "Backing up existing data directory..."
    lxc exec ${CONTAINER_NAME} -- bash -c "
        if [[ -d ${PG_DATA} ]]; then
            mv ${PG_DATA} ${PG_DATA}.backup.\$(date +%Y%m%d%H%M%S)
        fi
    "
    
    # Step 4: Take base backup from primary
    log "Taking base backup from primary (this may take a while)..."
    lxc exec ${CONTAINER_NAME} -- sudo -u postgres bash -c "
        PGPASSWORD='${REPL_PASSWORD}' pg_basebackup \
            -h ${PRIMARY_HOST} \
            -U ${REPL_USER} \
            -D ${PG_DATA} \
            -Fp -Xs -P -R
    "
    
    if [[ $? -ne 0 ]]; then
        error "Base backup failed!"
        exit 1
    fi
    log "Base backup completed"
    
    # Step 5: The -R flag creates standby.signal and postgresql.auto.conf
    # Verify the configuration
    log "Verifying standby configuration..."
    if lxc exec ${CONTAINER_NAME} -- test -f ${PG_DATA}/standby.signal; then
        log "standby.signal exists"
    else
        error "standby.signal not created. Creating manually..."
        lxc exec ${CONTAINER_NAME} -- touch ${PG_DATA}/standby.signal
        lxc exec ${CONTAINER_NAME} -- chown postgres:postgres ${PG_DATA}/standby.signal
    fi
    
    # Step 6: Ensure hot_standby is on
    lxc exec ${CONTAINER_NAME} -- bash -c "
        mkdir -p ${PG_CONF}/conf.d
        cat > ${PG_CONF}/conf.d/standby.conf << 'PGCONF'
# Standby Configuration
# Added by setup-streaming-replication.sh

hot_standby = on
hot_standby_feedback = on
PGCONF
    "
    
    # Step 7: Start PostgreSQL
    log "Starting PostgreSQL in standby mode..."
    lxc exec ${CONTAINER_NAME} -- systemctl start postgresql
    sleep 5
    
    # Step 8: Verify replication status
    log "Checking replication status..."
    if lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" | grep -q "t"; then
        log "PostgreSQL is running in STANDBY mode"
    else
        warn "PostgreSQL may not be in standby mode. Check logs."
    fi
    
    echo ""
    echo "=============================================="
    echo "    STANDBY SETUP COMPLETE"
    echo "=============================================="
    echo ""
    echo "This node is now replicating from ${PRIMARY_HOST}"
    echo ""
    echo "Verify replication on PRIMARY:"
    echo "  lxc exec postgres-lxc -- sudo -u postgres psql -c 'SELECT * FROM pg_stat_replication;'"
    echo ""
    echo "Verify replication on STANDBY:"
    echo "  lxc exec postgres-lxc -- sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
    echo "  lxc exec postgres-lxc -- sudo -u postgres psql -c 'SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();'"
    echo ""
}

# =============================================================================
# CHECK REPLICATION STATUS
# =============================================================================
check_status() {
    log "Checking replication status..."
    
    IS_RECOVERY=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    
    if [[ "${IS_RECOVERY}" == "t" ]]; then
        echo ""
        echo "=== STANDBY NODE STATUS ==="
        echo ""
        lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -c "
            SELECT 
                pg_is_in_recovery() as is_standby,
                pg_last_wal_receive_lsn() as receive_lsn,
                pg_last_wal_replay_lsn() as replay_lsn,
                pg_last_xact_replay_timestamp() as last_replay_time;
        "
    elif [[ "${IS_RECOVERY}" == "f" ]]; then
        echo ""
        echo "=== PRIMARY NODE STATUS ==="
        echo ""
        lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -c "
            SELECT 
                client_addr,
                state,
                sent_lsn,
                write_lsn,
                flush_lsn,
                replay_lsn,
                sync_state
            FROM pg_stat_replication;
        "
        
        REPL_COUNT=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SELECT count(*) FROM pg_stat_replication;")
        if [[ "${REPL_COUNT}" -eq 0 ]]; then
            warn "No standby nodes connected!"
        else
            log "${REPL_COUNT} standby node(s) connected"
        fi
    else
        error "Could not determine node status"
    fi
}

# =============================================================================
# PROMOTE STANDBY TO PRIMARY
# =============================================================================
promote_standby() {
    log "Promoting standby to primary..."
    
    IS_RECOVERY=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
    
    if [[ "${IS_RECOVERY}" != "t" ]]; then
        error "This node is not a standby. Cannot promote."
        exit 1
    fi
    
    warn "WARNING: This will promote the standby to a new primary."
    warn "The old primary (if still running) will need to be reconfigured."
    read -p "Are you sure? (yes/no): " CONFIRM
    
    if [[ "${CONFIRM}" != "yes" ]]; then
        log "Aborted."
        exit 0
    fi
    
    log "Promoting..."
    lxc exec ${CONTAINER_NAME} -- sudo -u postgres pg_ctl promote -D ${PG_DATA}
    
    sleep 3
    
    IS_RECOVERY=$(lxc exec ${CONTAINER_NAME} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
    
    if [[ "${IS_RECOVERY}" == "f" ]]; then
        log "Promotion successful! This node is now PRIMARY."
        echo ""
        echo "Next steps:"
        echo "1. Update Keycloak connection strings to point to this node"
        echo "2. Reconfigure old primary as standby (or rebuild)"
        echo ""
    else
        error "Promotion may have failed. Check PostgreSQL logs."
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi
    
    case "$1" in
        --primary)
            setup_primary
            ;;
        --standby)
            setup_standby
            ;;
        --check)
            check_status
            ;;
        --promote)
            promote_standby
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
}

main "$@"

