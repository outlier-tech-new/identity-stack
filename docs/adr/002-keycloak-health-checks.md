# ADR-002: Keycloak Native Health Checks for Traefik

## Status
**Accepted** - 2026-01-05

## Context

Traefik needs to determine which Keycloak backends are healthy for load balancing. We considered several health check approaches:

1. **No health checks** - Round-robin regardless of state
2. **Application endpoint** - Use `/realms/master` or similar
3. **Native health endpoints** - Keycloak's built-in `/health/*` endpoints

## Decision

We chose **Keycloak's native health endpoints on port 9000**.

### Configuration
```yaml
# Traefik keycloak.yml
healthCheck:
  path: /health/ready
  port: "9000"
  interval: 10s
  timeout: 3s
```

## Rationale

### Why Native Health Endpoints

1. **Purpose-built**: Designed specifically for health checking
2. **Database awareness**: `/health/ready` checks database connectivity
3. **Separation of concerns**: Port 9000 (management) vs 8080 (application)
4. **Keycloak documentation**: Official recommended approach

### Available Endpoints

| Endpoint | Purpose |
|----------|---------|
| `/health/ready` | Full readiness (includes DB check) |
| `/health/live` | Basic liveness (Keycloak process running) |
| `/health/started` | Startup complete |
| `/health` | Combined health status |

### Why `/health/ready`

- Checks database connectivity
- Returns `DOWN` if database unreachable
- Traefik automatically removes unhealthy backends
- Perfect for detecting database failover scenarios

### Why Port 9000

- Keycloak's management interface
- Not exposed through main application port
- Requires explicit port forwarding configuration
- Keeps health checks separate from user traffic

## Consequences

### Positive
- Automatic failover routing during database issues
- No custom health check logic needed
- Standard Keycloak configuration
- Proper readiness semantics

### Negative
- Requires port 9000 forwarding in iptables
- Additional port to manage/monitor
- Must enable `health-enabled=true` in Keycloak config

### Implementation

1. **Keycloak config** (`keycloak.conf`):
   ```
   health-enabled=true
   ```

2. **Port forwarding** (via `idp-enable-health.sh`):
   ```bash
   iptables -t nat -A PREROUTING -p tcp --dport 9000 -j DNAT --to-destination <container_ip>:9000
   ```

3. **Traefik config** (`keycloak.yml`):
   ```yaml
   healthCheck:
     path: /health/ready
     port: "9000"
   ```

## References

- [Keycloak Health Endpoints](https://www.keycloak.org/observability/health)
- [Traefik Health Checks](https://doc.traefik.io/traefik/routing/services/#health-check)

