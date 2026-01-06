# ADR-003: Separation of Identity (Keycloak) and Secrets (OpenBao)

## Status
**Accepted** - 2026-01-06

## Context

We need to manage two distinct but related concerns:
1. **Identity**: Who is this person/service? What roles do they have?
2. **Secrets**: Passwords, API keys, credentials that need to be stored and retrieved

Some platforms (like Azure AD + Key Vault, or AWS IAM + Secrets Manager) separate these. Others try to do both. We need to decide our approach.

## Decision

**Keycloak for Identity, OpenBao for Secrets.**

### Keycloak Handles
- User authentication (OIDC, SAML)
- Role assignments
- Group memberships
- SSO tokens
- SSH certificate claims (via step-ca OIDC provisioner)

### OpenBao Handles
- Breakglass passwords
- API keys and tokens
- Database credentials
- Service account secrets
- Any credential that needs to be retrieved and used

### Access Control
- OpenBao authenticates users via Keycloak OIDC
- Keycloak roles map to OpenBao policies
- "Can david.tyler read secrets/servers/sec001/sysadmin?" → Keycloak role → OpenBao policy

## Rationale

### Why Not Store Secrets in Keycloak?
- Keycloak is designed for authentication, not secret storage
- No API to retrieve stored credentials
- No audit trail for secret access
- Not designed for machine-to-machine credential retrieval

### Why Not Store Identity in OpenBao?
- OpenBao is designed for secrets, not user management
- Limited OIDC/SAML capabilities
- No group hierarchy or role composition
- Not designed for SSO flows

### Why This Separation Works
- Each system does what it's designed for
- Clear audit boundaries (Keycloak: who authenticated, OpenBao: who accessed secrets)
- Keycloak can be exposed for user login; OpenBao stays internal
- Failure isolation: Keycloak down ≠ secrets inaccessible (cached tokens)

## Consequences

### Positive
- Each system optimized for its purpose
- Clear security boundaries
- Separate audit logs for identity vs secret access
- Can scale/upgrade independently

### Negative
- Two systems to maintain
- Integration complexity (OIDC auth from Keycloak to OpenBao)
- Users must understand which system to use for what

### Implementation

```
User Login Flow:
  Browser → Keycloak → OIDC Token → Application

Secret Retrieval Flow:
  User/Service → Keycloak Auth → OpenBao → Secret

SSH Certificate Flow:
  User → Keycloak OIDC → step-ca → SSH Certificate
```

## References
- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [OpenBao Documentation](https://openbao.org/docs/)

