# ADR-005: Breakglass Access Model

## Status
**Accepted** - 2026-01-06

## Context

When the normal SSH certificate infrastructure is unavailable (step-ca down, Keycloak unreachable, network partition), we still need emergency access to servers. This is the "breakglass" scenario.

Key constraints:
- Must work when certificate infra is down
- Must be auditable (who accessed what)
- Must be secure (can't be easily compromised)
- Must work for airgapped/console access

## Decision

**Breakglass passwords stored in OpenBao, with retrieval audited.**

### Breakglass Account
- Account: `sysadmin` on each server
- Authentication: Password only (no SSH keys)
- Sudo: Full root access
- Purpose: Emergency recovery only

### Password Storage
- Location: OpenBao at `secrets/servers/{hostname}/sysadmin`
- Access: Controlled by OpenBao policies linked to Keycloak roles
- Rotation: After every use, or quarterly minimum

### Audit Chain
1. User authenticates to OpenBao via Keycloak OIDC
2. OpenBao logs: "david.tyler read secrets/servers/sec001/sysadmin at 14:02:33"
3. User connects to server via SSH or console
4. sshd logs: "Accepted password for sysadmin from 192.168.1.x at 14:05:12"
5. Correlation: OpenBao retrieval time + source IP matches SSH login

### Access Workflow
```
1. User opens OpenBao UI (or CLI)
2. Authenticates via Keycloak SSO
3. Navigates to: secrets/servers/{hostname}/sysadmin
4. Clicks "Reveal" → password displayed
5. Copies password
6. SSHes or uses console with password
7. After use: triggers password rotation
```

## Rationale

### Why Passwords (Not SSH Keys)?
- **Works on console**: Can type password on KVM/IPMI
- **No local storage**: Password retrieved on-demand, not stored on laptop
- **Easier rotation**: Change password, done
- **Audit at source**: Know who got the password (impossible with shared SSH key)

### Why OpenBao (Not Password Manager)?
- **OIDC integration**: Uses Keycloak for auth
- **Fine-grained policies**: Per-server, per-role access
- **Audit logging**: Built-in audit trail
- **API access**: Can build automation around retrieval

### Why Not Eliminate Breakglass?
- **Bootstrap problem**: How do you fix step-ca if you can't SSH?
- **Network isolation**: Server might be unreachable by normal means
- **Disaster recovery**: After major outage, need guaranteed access
- **Console access**: Some scenarios require physical/IPMI access

## Consequences

### Positive
- Works when everything else is down
- Full audit trail via OpenBao
- No credentials stored on client devices
- Password rotation built into workflow

### Negative
- Requires manual correlation for audit (OpenBao log ↔ SSH log)
- Password retrieval requires Keycloak + OpenBao to be up
- If both step-ca AND OpenBao are down, need offline backup

### Offline Backup
For complete infrastructure failure:
- Printed recovery passwords in physical safe
- Used only when OpenBao is also unreachable
- Triggers full infrastructure recovery procedure
- Rotated after use

## Implementation

### OpenBao Policy
```hcl
# Policy: breakglass-sec001
path "secrets/data/servers/sec001/sysadmin" {
  capabilities = ["read"]
}
```

### Keycloak Role Mapping
```
Keycloak Role: breakglass-sec001 
  → OpenBao Policy: breakglass-sec001
  → Access: secrets/servers/sec001/sysadmin
```

### Audit Report (Daily)
```sql
SELECT 
  timestamp,
  user,
  path,
  operation
FROM openbao_audit
WHERE path LIKE 'secrets/data/servers/%/sysadmin'
ORDER BY timestamp DESC
```

## Related ADRs
- ADR-003: Identity/Secrets Separation
- ADR-004: SSH Shared Accounts with Certificate Identity

