# Keycloak Automation & RBAC Implementation Plan

## Date: 2026-01-06 (Tomorrow)

## Executive Summary

With Keycloak HA now operational, the next phase is to:
1. Automate Keycloak configuration (realms, clients, roles, groups)
2. Implement a scalable RBAC model
3. Potentially replace Authelia with Keycloak for SSO/ForwardAuth
4. Create low-friction user onboarding

---

## Part 1: Keycloak Automation Infrastructure

### Goal
Infrastructure-as-Code for Keycloak configuration - all realms, clients, roles, groups defined in files and applied via scripts.

### Approach: Keycloak Admin CLI + Terraform Provider

#### Option A: Keycloak Admin CLI (Recommended for Start)
```bash
# kcadm.sh is bundled with Keycloak
# Can create realms, clients, roles, users, groups

# Example: Create a realm
kcadm.sh create realms -s realm=infrastructure -s enabled=true

# Example: Create a client
kcadm.sh create clients -r infrastructure \
  -s clientId=traefik-forwardauth \
  -s enabled=true \
  -s protocol=openid-connect
```

**Pros:**
- Built into Keycloak
- No additional dependencies
- Shell script friendly

**Cons:**
- Imperative (run commands), not declarative
- Need to handle idempotency ourselves

#### Option B: Terraform Keycloak Provider (Future)
```hcl
resource "keycloak_realm" "infrastructure" {
  realm   = "infrastructure"
  enabled = true
}

resource "keycloak_openid_client" "traefik" {
  realm_id  = keycloak_realm.infrastructure.id
  client_id = "traefik-forwardauth"
}
```

**Pros:**
- Declarative
- State management
- Drift detection

**Cons:**
- Additional tooling
- Learning curve

### Recommended Implementation

Create a `keycloak-config/` directory structure:

```
identity-stack/
├── keycloak-config/
│   ├── apply-config.sh           # Master script
│   ├── realms/
│   │   ├── master.json           # Master realm tweaks
│   │   └── infrastructure.json   # Infrastructure realm
│   ├── clients/
│   │   ├── traefik-forwardauth.json
│   │   ├── grafana.json
│   │   └── vault.json
│   ├── roles/
│   │   └── infrastructure/
│   │       ├── realm-roles.json
│   │       └── composite-roles.json
│   ├── groups/
│   │   └── infrastructure/
│   │       └── groups.json
│   └── templates/
│       ├── service-client.json.tmpl
│       └── user-federation.json.tmpl
```

---

## Part 2: RBAC Model Design

### Goal
A scalable permission model that avoids "1000 groups" while providing granular control.

### Recommended: Hierarchical Roles with Composite Permissions

```
┌─────────────────────────────────────────────────────────────┐
│                    REALM: infrastructure                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  REALM ROLES (coarse-grained, user-facing)                  │
│  ├── platform-admin     (god mode)                          │
│  ├── platform-ops       (operational access)                │
│  ├── platform-readonly  (view only)                         │
│  ├── service-account    (for automated systems)             │
│  └── developer          (dev environment access)            │
│                                                              │
│  CLIENT ROLES (fine-grained, per-service)                   │
│  ├── grafana/                                                │
│  │   ├── admin          (full grafana admin)                │
│  │   ├── editor         (can edit dashboards)               │
│  │   └── viewer         (read-only)                         │
│  ├── traefik/                                                │
│  │   ├── admin          (full traefik access)               │
│  │   └── viewer         (dashboard view only)               │
│  ├── vault/                                                  │
│  │   ├── admin          (manage vault)                      │
│  │   ├── secrets-reader (read secrets)                      │
│  │   └── secrets-writer (write secrets)                     │
│  └── monitoring/                                             │
│      ├── admin          (manage monitoring stack)           │
│      ├── alerter        (manage alerts)                     │
│      └── viewer         (view dashboards/metrics)           │
│                                                              │
│  COMPOSITE ROLES (combine realm + client roles)             │
│  ├── platform-admin includes:                               │
│  │   ├── grafana/admin                                      │
│  │   ├── traefik/admin                                      │
│  │   ├── vault/admin                                        │
│  │   └── monitoring/admin                                   │
│  ├── platform-ops includes:                                 │
│  │   ├── grafana/editor                                     │
│  │   ├── traefik/viewer                                     │
│  │   ├── vault/secrets-reader                               │
│  │   └── monitoring/alerter                                 │
│  └── platform-readonly includes:                            │
│      ├── grafana/viewer                                     │
│      ├── traefik/viewer                                     │
│      └── monitoring/viewer                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **Users get realm roles** (simple assignment)
2. **Realm roles are composites** (bundle client roles)
3. **Client roles are granular** (per-service permissions)
4. **Services check client roles** (via token claims)

### Benefits
- Add a user to `platform-ops` → gets all ops permissions
- Add new service → create client roles, add to composites
- Override specific permissions → directly assign client roles
- Service accounts get only what they need

---

## Part 3: Service Account Pattern (Monitoring Example)

### Problem
A monitoring service needs:
- Read metrics from various systems
- Access Grafana API
- Query Prometheus
- Access health endpoints

### Solution: Service Account with Scoped Roles

```json
{
  "clientId": "monitoring-agent",
  "serviceAccountsEnabled": true,
  "clientAuthenticatorType": "client-secret",
  "defaultClientScopes": ["monitoring-access"],
  "roles": [
    "monitoring/collector",
    "grafana/viewer",
    "prometheus/reader"
  ]
}
```

### Creating Service Accounts

```bash
# Create the client with service account
kcadm.sh create clients -r infrastructure \
  -s clientId=monitoring-agent \
  -s serviceAccountsEnabled=true \
  -s clientAuthenticatorType=client-secret

# Get the service account user
SERVICE_USER=$(kcadm.sh get clients -r infrastructure -q clientId=monitoring-agent --fields serviceAccountUserId)

# Assign roles to service account
kcadm.sh add-roles -r infrastructure \
  --uusername service-account-monitoring-agent \
  --cclientid monitoring \
  --rolename collector
```

---

## Part 4: Authelia vs Keycloak ForwardAuth

### Current State: Authelia
- File-based user database
- ForwardAuth for Traefik
- TOTP 2FA
- Simple access control rules

### Option 1: Keep Authelia, Integrate with Keycloak
```
User → Traefik → Authelia → Keycloak (OIDC) → Backend
```

**Pros:**
- Authelia already working
- Authelia has nice SSO features
- Gradual migration

**Cons:**
- Two auth systems to maintain
- User management split

### Option 2: Replace Authelia with Keycloak ForwardAuth

Keycloak doesn't have native ForwardAuth, but solutions exist:

#### Option 2a: OAuth2-Proxy
```
User → Traefik → OAuth2-Proxy → Keycloak OIDC → Backend
```

**Pros:**
- Mature, widely used
- Full OIDC support
- Group/role-based access

**Cons:**
- Another container to manage

#### Option 2b: Traefik Enterprise (paid) or custom middleware

#### Option 2c: Keycloak Gatekeeper (deprecated but patterns exist)

### Recommendation

**Phase 1: Hybrid (Tomorrow)**
- Keep Authelia for existing services
- Add Keycloak OIDC as Authelia backend
- Users authenticate via Keycloak, Authelia does ForwardAuth

**Phase 2: Evaluate OAuth2-Proxy (Next Week)**
- Deploy OAuth2-Proxy alongside Authelia
- Test with one service
- Compare UX and maintenance burden

**Phase 3: Decision (After Testing)**
- If OAuth2-Proxy works well → migrate away from Authelia
- If not → keep hybrid with Keycloak-backed Authelia

---

## Part 5: User Onboarding Friction Reduction

### Current Pain Points
1. Manual user creation in Authelia file
2. Manual group assignment
3. No self-service

### Improved Flow with Keycloak

```
                    ┌─────────────────────────┐
                    │   Admin creates user    │
                    │   (or LDAP/AD sync)     │
                    └───────────┬─────────────┘
                                │
                    ┌───────────▼─────────────┐
                    │   Assign realm role     │
                    │   (e.g., platform-ops)  │
                    └───────────┬─────────────┘
                                │
                    ┌───────────▼─────────────┐
                    │   User gets email       │
                    │   - Set password link   │
                    │   - 2FA setup required  │
                    └───────────┬─────────────┘
                                │
                    ┌───────────▼─────────────┐
                    │   User can access all   │
                    │   services in their role│
                    └─────────────────────────┘
```

### Automation Scripts to Create

```bash
# scripts/kc-add-user.sh
# Creates user + assigns role + triggers password email

./scripts/kc-add-user.sh \
  --realm infrastructure \
  --username jsmith \
  --email jsmith@company.com \
  --role platform-ops

# scripts/kc-add-service-account.sh
# Creates service account with specific permissions

./scripts/kc-add-service-account.sh \
  --realm infrastructure \
  --name monitoring-agent \
  --roles "monitoring/collector,grafana/viewer"
```

---

## Part 6: Tomorrow's Tasks (Prioritized)

### Morning: Foundation (2-3 hours)

1. **Create Keycloak config structure**
   ```bash
   mkdir -p keycloak-config/{realms,clients,roles,groups,scripts}
   ```

2. **Create `infrastructure` realm**
   - Separate from `master` for security
   - Configure email settings (for password reset)
   - Enable required actions (2FA setup)

3. **Define base realm roles**
   - `platform-admin`
   - `platform-ops`
   - `platform-readonly`
   - `service-account`

4. **Create apply-config.sh script**
   - Idempotent configuration application
   - Uses kcadm.sh under the hood

### Afternoon: Service Integration (2-3 hours)

5. **Create Traefik OIDC client**
   - For dashboard protection
   - Test with existing Authelia or new OAuth2-Proxy

6. **Create Grafana OIDC client** (if Grafana deployed)
   - Grafana has native OIDC support
   - Map Keycloak roles → Grafana roles

7. **Document the pattern**
   - How to add new services
   - How to add new users
   - How to create service accounts

### Evening: User Management (1-2 hours)

8. **Create user management scripts**
   - `kc-add-user.sh`
   - `kc-list-users.sh`
   - `kc-assign-role.sh`

9. **Migrate test user**
   - Create your user in Keycloak
   - Assign `platform-admin`
   - Test SSO to Keycloak-protected service

---

## Part 7: Cleanup & Improvements Identified

### Identity Stack
| Item | Priority | Description |
|------|----------|-------------|
| Remove old scripts | Low | `failover-to-standby.sh`, `rebuild-as-standby.sh` already deleted |
| Add README updates | Medium | Update main README with new script locations |
| Test full failover cycle | High | idp01→standby complete, verify idp02 shows 1 standby |
| Document replication password | Medium | Add to secrets management docs |

### Security Stack
| Item | Priority | Description |
|------|----------|-------------|
| Clean scratch/ folder | Low | Contains old diagnostic files |
| Update Authelia docs | Medium | Document Keycloak integration path |
| Remove docker-diagnostic log | Low | 1310 lines of old debug output |
| Consolidate ADRs | Medium | Some decisions in docs/ need ADR format |
| Review add-authelia-user.sh | Medium | May be deprecated if moving to Keycloak |

### Cross-Stack
| Item | Priority | Description |
|------|----------|-------------|
| SSH keys between IDP nodes | High | Scripts expect SSH access (currently using pg_isready workaround) |
| sec→idp SSH access | Medium | Status script can't check Traefik config remotely |
| Centralize secrets | High | Replication password, admin creds need proper management |

---

## Appendix: Keycloak Client Role Mapping Examples

### Grafana Integration
```json
{
  "clientId": "grafana",
  "rootUrl": "https://grafana.outliertechnology.co.uk",
  "redirectUris": ["https://grafana.outliertechnology.co.uk/*"],
  "protocolMappers": [{
    "name": "grafana-roles",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-client-role-mapper",
    "config": {
      "claim.name": "roles",
      "multivalued": "true",
      "usermodel.clientRoleMapping.clientId": "grafana"
    }
  }]
}
```

Grafana config:
```ini
[auth.generic_oauth]
enabled = true
client_id = grafana
client_secret = ${GRAFANA_OAUTH_SECRET}
auth_url = https://idp.outliertechnology.co.uk/realms/infrastructure/protocol/openid-connect/auth
token_url = https://idp.outliertechnology.co.uk/realms/infrastructure/protocol/openid-connect/token
api_url = https://idp.outliertechnology.co.uk/realms/infrastructure/protocol/openid-connect/userinfo
role_attribute_path = contains(roles[*], 'admin') && 'Admin' || contains(roles[*], 'editor') && 'Editor' || 'Viewer'
```

### Monitoring Service Account
```json
{
  "clientId": "monitoring-agent",
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": false,
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountRoles": [
    "monitoring/collector",
    "prometheus/reader"
  ]
}
```


---

## Part 8: Revised Approach Based on Review

> See: [Access Governance Framework](./access-governance-framework.md) for full design

### Key Decisions

1. **Source of Truth**: Keycloak is the source of truth for actual accounts/roles. We document the *design* and *schema* but don't store user data in Git.

2. **Provider-Agnostic Model**: Configuration should be logical (realms, roles, permissions) not Keycloak-specific. Adapters translate to provider.

3. **Unified Onboarding**: Single command creates accounts in Keycloak, Authelia, SSH, GitHub, VPN - everything.

4. **DARTIP Governance**: Every role has defined Decider, Approver, Reviewer, Tracker, Inputter, Performer.

5. **Access Fingerprints**: Every entity (person, service, system) has a queryable profile of what it can access.

6. **Self-Governing Loop**: Exceptions trigger role creation when threshold reached.

7. **Business Ownership**: Team leads own their team's permission profile, not IT.

### Revised Tomorrow's Tasks

#### Morning: Governance Foundation
1. Define DARTIP for initial roles (platform-admin, platform-ops, platform-readonly)
2. Create logical model schema (provider-agnostic YAML)
3. Build first adapter: keycloak/apply-role.sh

#### Afternoon: Fingerprint System
4. Design fingerprint schema for individuals and services
5. Create fingerprint generator for existing admin user
6. Document the exception workflow

#### Evening: Onboarding Skeleton
7. Create iam-onboard.sh skeleton (Keycloak + Authelia initially)
8. Test with mock onboarding request
9. Document the pattern for adding more adapters

### What This Means for the Stack

- **identity-stack**: Logical model, fingerprints, adapters
- **security-stack**: Authelia adapter, SSH adapter, firewall rules
- **Separate repo (future)**: `access-governance/` with model and all adapters

The key insight: **IT owns the process, business owns the permissions.**