# ADR-004: SSH Shared Accounts with Certificate-Based Identity

## Status
**Accepted** - 2026-01-06

## Context

For server access, we need to decide between:
1. **Per-user accounts** on every server (traditional)
2. **Shared role accounts** with identity provided by SSH certificates

Both approaches need to support audit requirements: knowing WHO did WHAT on each server.

## Decision

**Use shared role accounts (ops, admin, readonly) with SSH certificates providing real identity.**

### Account Structure
Each server has:
- `readonly` - View access, no sudo
- `ops` - Operational commands, limited sudo
- `admin` - Full administration, full sudo
- `sysadmin` - Breakglass only, password auth

### Identity Mechanism
- Users authenticate via SSH certificate (issued by step-ca)
- Certificate contains real identity (e.g., `david.tyler@company.com`)
- sshd logs both the account AND the certificate identity
- Audit trail: "david.tyler connected as ops"

### sshd Configuration
```bash
# Trust SSH User CA
TrustedUserCAKeys /etc/ssh/ca-user.pub

# Map principals to accounts
AuthorizedPrincipalsFile /etc/ssh/principals/%u

# Log certificate details
LogLevel VERBOSE
```

### Log Output
```
Accepted publickey for ops from 192.168.1.100 port 54321 ssh2: 
ED25519-CERT SHA256:xxxx ID david.tyler@company.com (serial 12345) CA ED25519 SHA256:yyyy
```

## Rationale

### Why Shared Accounts with Certificates?
1. **No user proliferation**: Don't need 100 accounts on 50 servers
2. **Role-based sudo**: Each account has defined sudo permissions
3. **Identity preserved**: Certificate contains real user
4. **Audit complete**: Logs show real identity + role used
5. **Easy revocation**: Remove from Keycloak group, can't get new cert

### Why Not Per-User Accounts?
1. **Management overhead**: Create/delete accounts across fleet
2. **Inconsistency**: Account drift between servers
3. **Sudo complexity**: Per-user sudo files
4. **Still need identity**: Would still want certificates for key management

### Audit Comparison

| Approach | Login Log | Audit Trail |
|----------|-----------|-------------|
| Per-user accounts | "user david logged in" | Clear identity |
| Shared accounts + password | "user ops logged in" | **NO identity** |
| Shared accounts + certificate | "user ops logged in, cert ID: david.tyler" | Clear identity |

## Consequences

### Positive
- Clean role separation (account = role)
- Consistent sudo policies
- No user account management on servers
- Full audit trail via certificates

### Negative
- Requires certificate infrastructure (step-ca)
- Requires sshd configuration on all servers
- Different from traditional per-user model

### Breakglass Exception
The `sysadmin` account uses password authentication for breakglass scenarios:
- Certificate infrastructure unavailable
- Emergency access needed
- Audit provided by OpenBao (who retrieved the password)

## Implementation

### Server Setup
1. Create role accounts: `readonly`, `ops`, `admin`, `sysadmin`
2. Configure sshd with `TrustedUserCAKeys`
3. Create principal mapping files
4. Configure sudo policies per account

### Client Workflow
```bash
# Get SSH certificate (opens Keycloak OIDC login)
step ssh login david@company.com --provisioner keycloak

# SSH to server using role
ssh ops@server.example.com

# Certificate provides identity, account provides role
```

## References
- [SSH Certificates](https://www.openssh.com/txt/release-5.4)
- [step-ca SSH Certificates](https://smallstep.com/docs/ssh/)

