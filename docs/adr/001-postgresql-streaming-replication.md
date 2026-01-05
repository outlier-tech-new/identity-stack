# ADR-001: PostgreSQL Streaming Replication with Manual Failover

## Status
**Accepted** - 2026-01-05

## Context

The Keycloak identity service requires a highly available database backend. We evaluated several options for PostgreSQL HA:

1. **Shared Storage (SAN/NFS)** - Single PostgreSQL with shared storage
2. **Logical Replication** - Table-level replication for multi-master
3. **Streaming Replication** - WAL-based physical replication
4. **Patroni/Stolon** - Automated HA with consensus
5. **Citus/CockroachDB** - Distributed databases

## Decision

We chose **PostgreSQL Streaming Replication with Manual Failover**.

### Configuration
- PRIMARY node: Accepts writes, streams WAL to standby
- STANDBY node: Receives WAL, read-only, can be promoted
- Manual promotion triggered by operator scripts
- No automatic failover to prevent split-brain

## Rationale

### Why Streaming Replication
- **Simplicity**: Native PostgreSQL feature, no external dependencies
- **Low latency**: Synchronous or near-synchronous replication
- **Full fidelity**: Physical replication captures everything
- **Keycloak compatibility**: Works with any PostgreSQL client

### Why Manual Failover
- **Split-brain prevention**: No risk of two primaries
- **DR-focused**: Minutes of downtime acceptable vs. complexity of HA
- **Controlled recovery**: Operator verifies state before promotion
- **Lower complexity**: No quorum, no consensus protocols

### Why Not Automatic HA (Patroni/Stolon)
- Requires etcd/consul cluster (3+ nodes)
- Additional operational complexity
- Potential for split-brain in network partitions
- Overkill for current scale

### Why Not Logical Replication
- Doesn't replicate schema changes automatically
- Higher complexity for setup
- Potential for replication conflicts

## Consequences

### Positive
- Simple to understand and operate
- No external dependencies (etcd, consul)
- Scripts handle all common scenarios
- Easy to test and verify

### Negative
- Manual intervention required for failover
- Potential for longer recovery time
- Operator must be available for failures

### Mitigations
- Comprehensive operator scripts reduce human error
- Traefik health checks route around failures automatically
- Monitoring (future) will alert on failures quickly

## Implementation

### Scripts Created
- `idp-failover.sh` - Emergency failover when primary fails
- `idp-reinstate.sh` - Reinstate failed node as standby
- `idp-role-switch.sh` - Planned role switch between healthy nodes
- `lib/idp-promote-db.sh` - Promote standby to primary
- `lib/idp-rebuild-standby.sh` - Rebuild node as standby
- `lib/idp-enable-replication.sh` - Configure port forwarding and pg_hba.conf

### Key Configuration
- WAL level: `replica`
- Max WAL senders: 3
- Replication user: `replicator` with REPLICATION privilege
- pg_hba.conf entries for cross-node replication

## Future Considerations

1. **WAL Archiving**: Add for point-in-time recovery
2. **Monitoring Integration**: Alert on replication lag
3. **Automatic Failover**: Consider Patroni if scale demands it
4. **Read Replicas**: Add more standbys for read scaling

## References

- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html)
- [High Availability Design Doc](./postgres-ha-design.md)

