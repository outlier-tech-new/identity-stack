# Access Governance Framework

## Vision

A self-governing identity and access framework where:

1. **Business owns permissions** - Team leads define what their teams need, not IT
2. **Day-one productivity** - New joiners have everything from hour one
3. **Exceptions drive improvement** - Ad-hoc permissions become formal roles
4. **Provider-agnostic** - Logical model, not tied to Keycloak/Authelia/etc
5. **Fingerprints, not lists** - Every entity has a queryable access profile

---

## Part 1: The Problem with Traditional IAM

### What Usually Happens

```
Day 1:  New joiner arrives
Day 2:  IT creates AD account
Day 3:  Manager remembers they need Jira access
Day 5:  "Can you give them what Sarah has?"
Day 8:  Someone notices they can't access the shared drive
Day 14: They finally get VPN working
Day 30: Half their permissions are wrong, half are missing
```

### Why This Happens

| Issue | Root Cause |
|-------|------------|
| Slow onboarding | IT owns the process but doesn't know what's needed |
| "Copy Sarah's access" | No formal roles, just accumulated permissions |
| Permission creep | No regular reviews, no ownership |
| Over-privileged service accounts | "Just give it admin, we'll fix it later" |
| Orphaned accounts | No link between HR events and system access |

### What We Want

```
HR Event: "Jane starts Monday as Senior Engineer in Platform Team"
          ↓
Automated: Platform-Engineer role is applied
          ↓
Result:   - Keycloak account created
          - SSH certificate principals: ops, readonly
          - Grafana: Editor access
          - Vault: secrets/platform/* read
          - GitHub: platform-team repos
          - VPN: engineering profile
          - All tooling configured
          ↓
Day 1:    Jane is productive
```

---

## Part 2: Core Concepts

### The Entity Model

```
┌─────────────────────────────────────────────────────────────┐
│                         ENTITIES                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  INDIVIDUALS (humans)                                        │
│  ├── identity: email, employee ID                           │
│  ├── attributes: team, department, location, manager        │
│  ├── roles: assigned role memberships                       │
│  └── exceptions: individual permissions + justification     │
│                                                              │
│  SERVICE ACCOUNTS (automated systems)                        │
│  ├── identity: service name, owner                          │
│  ├── attributes: environment, criticality, data class       │
│  ├── roles: what the service needs                          │
│  └── secrets: credentials, API keys (via OpenBao)           │
│                                                              │
│  SYSTEMS (infrastructure)                                    │
│  ├── identity: hostname, IP, certificates                   │
│  ├── attributes: network zone, role, services hosted        │
│  ├── connectivity: what can connect to it                   │
│  └── dependencies: what it connects to                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### The Access Fingerprint

Every entity has a **fingerprint** - a complete view of what it can access:

```yaml
# Example: Jane's fingerprint
entity:
  type: individual
  id: jane.smith@company.com
  employee_id: EMP-1234
  
attributes:
  team: platform
  department: engineering
  manager: bob.jones@company.com
  location: remote-uk
  start_date: 2026-01-15

roles:
  - platform-engineer          # Primary role
  - oncall-responder           # Additional duty

effective_permissions:
  keycloak:
    realm: infrastructure
    roles: [platform-ops]
    clients:
      grafana: [editor]
      vault: [secrets-reader]
      monitoring: [alerter]
  
  ssh:
    principals: [ops, readonly]
    servers: [*.platform.internal]
  
  github:
    teams: [platform-team, oncall-rotation]
    repos: 
      - platform-*: write
      - infrastructure-*: read
  
  vpn:
    profile: engineering
    networks: [10.0.0.0/8]

exceptions:
  - permission: vault/secrets/legacy-app/*
    reason: "Migration project - legacy app credentials"
    approved_by: security@company.com
    expires: 2026-03-01
    ticket: PLAT-1234

last_review:
  date: 2026-01-01
  reviewer: bob.jones@company.com
  next_due: 2026-04-01
```

### Fingerprint Benefits

| Use Case | How Fingerprint Helps |
|----------|----------------------|
| Onboarding | "Apply the Platform-Engineer fingerprint" |
| Access review | "Show me Jane's effective permissions" |
| Offboarding | "Revoke everything in Jane's fingerprint" |
| Audit | "Who has access to vault/secrets/production/*?" |
| Role gap | "Jane has permissions no role covers - create one" |
| Service migration | "What does monitoring-agent access? Transfer it." |

---

## Part 3: DARTIP Governance Model

Every role, realm, and system has defined accountabilities:

### The DARTIP Roles

| Role | Responsibility | Example |
|------|----------------|---------|
| **D**ecider | Defines what's needed, what a role should contain | Team Lead |
| **A**pprover | Security sign-off, risk assessment | Security Team |
| **R**eviewer | Periodic review of assignments and roles | Security + Manager |
| **T**racker | Automated monitoring of exceptions/drift | System/Automation |
| **I**nputter | Raises requests, provides information | Team Members |
| **P**erformer | Executes the change (ideally automated) | IAM Scripts |

### DARTIP in Practice

```yaml
# Example: platform-engineer role DARTIP
role: platform-engineer
realm: infrastructure

dartip:
  decider:
    primary: platform-team-lead
    delegates: [senior-platform-engineers]
    
  approver:
    security: security-team
    budget: null  # No cost implications
    
  reviewer:
    schedule: quarterly
    participants:
      - platform-team-lead
      - security-team
    checklist:
      - Are all permissions still needed?
      - Are there permissions that should be in a role but aren't?
      - Are there service accounts that need review?
      
  tracker:
    monitors:
      - exception_count_for_role
      - last_review_overdue
      - permission_creep_score
    alerts_to: [platform-team-lead, security-team]
    
  inputter:
    allowed: [platform-team-members]
    request_types:
      - new_permission_request
      - role_modification_request
      - exception_request
      
  performer:
    type: automated
    script: iam-apply-role.sh
    fallback: infrastructure-team
```

### The Self-Governing Loop

```
┌─────────────────────────────────────────────────────────────┐
│                    SELF-GOVERNING CYCLE                      │
└─────────────────────────────────────────────────────────────┘

     ┌──────────────────┐
     │   Need arises    │ ← Team member needs access
     └────────┬─────────┘
              │
              ▼
     ┌──────────────────┐
     │  Check: Is there │
     │  a role for this?│
     └────────┬─────────┘
              │
       Yes ───┴─── No
        │          │
        ▼          ▼
┌──────────────┐  ┌──────────────────┐
│ Assign role  │  │ Grant exception  │
│ (Performer)  │  │ with justification│
└──────────────┘  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Tracker monitors │
                  │ exception count  │
                  └────────┬─────────┘
                           │
                  Threshold reached
                           │
                           ▼
                  ┌──────────────────┐
                  │ Alert: "5 people │
                  │ have this excep- │
                  │ tion - create a  │
                  │ role?"           │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Decider creates  │
                  │ new role         │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Approver reviews │
                  │ security impact  │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Performer applies│
                  │ role to all who  │
                  │ had exception    │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Exceptions       │
                  │ removed, role    │
                  │ now standard     │
                  └──────────────────┘
```

---

## Part 4: The "Copy Bob's Access" Problem

### The Anti-Pattern

> "Just give the new person what Bob has"

This is:
- **A signal** that roles aren't well-defined
- **A risk** because Bob's accumulated cruft gets copied
- **A governance failure** because no one owns "Bob's access"

### The Solution: Fingerprint Diff + Role Creation

```
Request: "Give Sarah what Bob has"
                │
                ▼
┌──────────────────────────────────────┐
│ System generates fingerprint diff    │
│                                       │
│ Bob has:                             │
│   - platform-engineer role ✓         │
│   - Exception: vault/legacy-app (OK) │
│   - Exception: grafana/special-dash  │ ← Not in any role
│   - Exception: github/private-repo   │ ← Not in any role
└──────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────┐
│ Tracker flags:                        │
│                                       │
│ "Bob has 2 exceptions not in a role. │
│  If Sarah also needs these, consider │
│  creating a role."                    │
│                                       │
│ Options:                              │
│ [1] Grant Sarah platform-engineer    │
│     (no exceptions)                   │
│ [2] Grant + same exceptions (review) │
│ [3] Create new role from Bob's       │
│     fingerprint                       │
└──────────────────────────────────────┘
                │
         Option 3 chosen
                │
                ▼
┌──────────────────────────────────────┐
│ New role proposed:                    │
│                                       │
│ platform-engineer-plus:               │
│   includes: platform-engineer         │
│   adds:                               │
│     - grafana/special-dash: view     │
│     - github/private-repo: read      │
│                                       │
│ DARTIP assigned:                      │
│   Decider: Bob's manager              │
│   Approver: Security                  │
└──────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────┐
│ Bob's exceptions → role membership    │
│ Sarah gets role (no exceptions)       │
│ Future: anyone can request this role  │
└──────────────────────────────────────┘
```

---

## Part 5: System & Service Fingerprints

### System Fingerprint

```yaml
# Example: sec001 (Traefik node) fingerprint
entity:
  type: system
  id: sec001.outliertechnology.co.uk
  hostname: sec001
  ip: 192.168.1.11

attributes:
  role: security-gateway
  zone: dmz
  environment: production
  criticality: high

services_hosted:
  - traefik
  - keepalived
  - crowdsec

connectivity:
  inbound:
    - source: internet
      ports: [80, 443]
      purpose: public web traffic
      
    - source: 192.168.1.0/24
      ports: [8080]
      purpose: internal dashboard
      
  outbound:
    - destination: idp001, idp002
      ports: [8080, 9000]
      purpose: keycloak backend
      
    - destination: ca001
      ports: [8443]
      purpose: ACME certificate requests

dns_records:
  - sec.outliertechnology.co.uk (VIP)
  - sec001.outliertechnology.co.uk
  - traefik.outliertechnology.co.uk

certificates:
  - issuer: step-ca
    cn: "*.outliertechnology.co.uk"
    expires: 2026-03-15
    
health_checks:
  - url: http://localhost:8080/ping
    interval: 10s
    
firewall_rules:
  - rule_id: FW-SEC-001
    source: internet
    dest: sec-vip
    ports: [80, 443]
    action: allow
```

### Service Account Fingerprint

```yaml
# Example: monitoring-agent fingerprint
entity:
  type: service_account
  id: monitoring-agent
  owner: platform-team

attributes:
  environment: production
  data_classification: internal
  criticality: medium

credentials:
  keycloak:
    client_id: monitoring-agent
    client_secret_path: vault:secrets/services/monitoring-agent
    
  api_keys:
    - name: grafana-api
      path: vault:secrets/services/monitoring-agent/grafana
      permissions: viewer
      
secrets_managed_by: openbao
rotation_policy: 90d

permissions:
  keycloak:
    realm: infrastructure
    client_roles:
      monitoring: [collector]
      grafana: [viewer]
      
  network:
    allowed_destinations:
      - prometheus:9090
      - grafana:3000
      - alertmanager:9093
      
  ssh: null  # No SSH access

dartip:
  decider: platform-team-lead
  approver: security-team
  reviewer: platform-team-lead
  review_schedule: quarterly
```

---

## Part 6: Provider-Agnostic Design

### The Abstraction Layer

```
┌─────────────────────────────────────────────────────────────┐
│                    LOGICAL MODEL                             │
│  (Provider-agnostic, the source of design truth)            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  realms/                                                     │
│  ├── infrastructure.yml     # Realm definition               │
│  └── customers.yml          # Future customer-facing realm   │
│                                                              │
│  roles/                                                      │
│  ├── platform-admin.yml                                      │
│  ├── platform-ops.yml                                        │
│  └── platform-readonly.yml                                   │
│                                                              │
│  clients/                                                    │
│  ├── grafana.yml           # Client + role definitions       │
│  ├── vault.yml                                               │
│  └── traefik.yml                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   PROVIDER ADAPTERS                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  adapters/                                                   │
│  ├── keycloak/             # Keycloak-specific translation   │
│  │   ├── apply-realm.sh                                      │
│  │   ├── apply-client.sh                                     │
│  │   └── apply-role.sh                                       │
│  │                                                           │
│  ├── authelia/             # Authelia user sync              │
│  │   └── sync-users.sh                                       │
│  │                                                           │
│  ├── ssh/                  # SSH certificate integration     │
│  │   └── generate-principals.sh                              │
│  │                                                           │
│  ├── github/               # GitHub team sync                │
│  │   └── sync-teams.sh                                       │
│  │                                                           │
│  └── openbao/              # Vault policy generation         │
│      └── generate-policies.sh                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Logical Role Definition (Provider-Agnostic)

```yaml
# roles/platform-ops.yml
# This is NOT Keycloak config - it's logical design

role:
  name: platform-ops
  description: "Operational access to platform systems"
  realm: infrastructure
  
dartip:
  decider: platform-team-lead
  approver: security-team
  reviewer: platform-team-lead
  
inherits:
  - platform-readonly  # Gets all readonly permissions too

grants:
  # Identity/SSO
  identity:
    type: human
    mfa_required: true
    
  # SSH access
  ssh:
    principals: [ops]
    allowed_hosts: "*.platform.internal"
    
  # Application-specific
  grafana:
    role: editor
    
  traefik:
    role: viewer
    
  vault:
    paths:
      - secrets/platform/*: read
      - secrets/shared/*: read
      
  monitoring:
    role: alerter
    
  # Network
  vpn:
    profile: engineering
    networks: [10.0.0.0/8]
    
  # Source control
  github:
    teams: [platform-team]
    repo_access:
      - "platform-*": write
      - "infrastructure-*": read
```

### Keycloak Adapter Translates This

```bash
# adapters/keycloak/apply-role.sh
# Reads platform-ops.yml, outputs Keycloak API calls

# Create realm role
kcadm.sh create roles -r infrastructure \
  -s name=platform-ops \
  -s composite=true

# Add client role mappings
kcadm.sh add-roles -r infrastructure \
  --rname platform-ops \
  --cclientid grafana --rolename editor

# ... etc
```

---

## Part 7: The Onboarding Flow

### Trigger: HR Event

```yaml
# onboarding-request.yml (attached to HR ticket)
request:
  type: onboarding
  ticket: HR-2026-0142
  
individual:
  name: Jane Smith
  email: jane.smith@company.com
  employee_id: EMP-1234
  start_date: 2026-01-20
  
assignment:
  team: platform
  manager: bob.jones@company.com
  role: platform-engineer
  
equipment:
  laptop: macbook-pro-16
  monitors: 2
  
notes: |
  Jane is joining from CloudCorp, has AWS and K8s experience.
  Will be working on the data pipeline project.
```

### Execution: iam-onboard.sh

```bash
#!/bin/bash
# iam-onboard.sh --request HR-2026-0142.yml

# 1. Validate request
validate_request "$REQUEST_FILE"

# 2. Check role exists and get fingerprint
ROLE_FINGERPRINT=$(get_role_fingerprint "${ASSIGNMENT_ROLE}")

# 3. Create accounts in all systems
create_keycloak_user "${EMAIL}" "${ROLE}"
create_ssh_principals "${EMAIL}" "${SSH_PRINCIPALS}"
sync_authelia_user "${EMAIL}"
create_github_invite "${EMAIL}" "${GITHUB_TEAMS}"
create_vpn_profile "${EMAIL}" "${VPN_PROFILE}"

# 4. Generate personal fingerprint
generate_fingerprint "${EMAIL}" > "fingerprints/${EMPLOYEE_ID}.yml"

# 5. Send welcome email with all credentials/links
send_welcome_email "${EMAIL}" "${FINGERPRINT}"

# 6. Log for audit
log_onboarding "${TICKET}" "${EMAIL}" "${ROLE}" "${FINGERPRINT}"

echo "✓ ${NAME} onboarded with role ${ROLE}"
echo "✓ Fingerprint: fingerprints/${EMPLOYEE_ID}.yml"
```

### Day One Result

Jane receives:
- Keycloak account with platform-engineer role
- SSH certificate with `ops` principal
- Grafana access (editor)
- Vault access (platform secrets)
- GitHub team membership
- VPN profile
- All documentation links

No tickets, no waiting, no "can you give me what Bob has".

---

## Part 8: The Tracker Automation

### What The Tracker Monitors

```yaml
# tracker/config.yml
monitors:
  
  exception_threshold:
    description: "Alert when same exception granted to N people"
    threshold: 3
    action: "Suggest creating a role"
    notify: [decider, security]
    
  review_overdue:
    description: "Alert when access review is overdue"
    threshold: 30d  # 30 days past due
    action: "Block new permissions until reviewed"
    notify: [reviewer, manager]
    
  orphan_detection:
    description: "Accounts with no recent activity"
    threshold: 90d
    action: "Flag for review, auto-disable at 120d"
    notify: [manager, security]
    
  permission_creep:
    description: "User's permissions exceed role definition"
    action: "Generate exception report"
    notify: [reviewer]
    
  role_coverage:
    description: "% of permissions in formal roles vs exceptions"
    target: "> 90%"
    alert_below: 80%
    notify: [security]
    
  service_account_secrets:
    description: "Service account credentials not rotated"
    threshold: 90d
    action: "Force rotation, alert if fails"
    notify: [service_owner]
```

### Tracker KPIs (Bob's Dashboard)

```
┌─────────────────────────────────────────────────────────────┐
│           Platform Team Access Governance KPIs               │
│           Owner: Bob Jones (Platform Team Lead)              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Role Coverage:         94% ✓ (target: >90%)                │
│  ├── In formal roles:   47 permissions                      │
│  └── Exceptions:        3 permissions                       │
│                                                              │
│  Pending Reviews:       0 ✓                                  │
│  ├── Last review:       2025-12-15                          │
│  └── Next due:          2026-03-15                          │
│                                                              │
│  Exception Age:                                              │
│  ├── <30 days:          2 (OK)                              │
│  ├── 30-60 days:        1 (Review needed)                   │
│  └── >60 days:          0 ✓                                  │
│                                                              │
│  Onboarding Velocity:   Avg 2 hours from request ✓          │
│                                                              │
│  ⚠️  Action Items:                                           │
│  └── Exception "vault/legacy-app" granted to 3 people       │
│      → Consider creating legacy-app-access role             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Part 9: Integration Points

### What Gets Linked to Roles

| System | What's Linked | How |
|--------|--------------|-----|
| **Keycloak** | Realm roles, client roles | Direct mapping |
| **SSH** | Certificate principals | step-ca OIDC claims |
| **Authelia** | Group membership | Sync script |
| **GitHub** | Team membership | API sync |
| **VPN** | Profile assignment | LDAP or API |
| **Firewall** | Network access rules | Rule tagging |
| **DNS** | Access to internal zones | Policy-based |
| **OpenBao** | Secret paths, policies | Policy generation |
| **Certificates** | mTLS client identity | step-ca OIDC |

### Service Fingerprint → Infrastructure

When you add a new service, its fingerprint drives:

```yaml
# services/new-api-service.yml
service:
  name: new-api-service
  owner: platform-team
  
requires:
  network:
    - protocol: tcp
      port: 8080
      source: traefik
      purpose: HTTP traffic
      
    - protocol: tcp
      port: 5432
      destination: postgres-cluster
      purpose: Database access
      
  dns:
    - new-api.outliertechnology.co.uk → 10.0.1.50
    
  certificates:
    - type: server
      cn: new-api.outliertechnology.co.uk
      
  secrets:
    - path: secrets/services/new-api/db-password
    - path: secrets/services/new-api/api-key
      
  health_check:
    endpoint: /health
    port: 8080
    interval: 30s
    
  load_balancer:
    add_to: traefik
    config: backends/new-api.yml
```

The adapters generate:
- Firewall rules (tagged: new-api-service)
- DNS records
- Traefik backend config
- OpenBao policies
- Certificate requests

---

## Part 10: Implementation Phases

### Phase 1: Foundation (Week 1-2)
- [ ] Create logical model schema (YAML structure)
- [ ] Define DARTIP for existing roles
- [ ] Create fingerprint generator for current users
- [ ] Build Keycloak adapter (apply realm, roles, clients)

### Phase 2: Onboarding (Week 3-4)
- [ ] Create iam-onboard.sh script
- [ ] Integrate with HR ticket system (manual trigger initially)
- [ ] Build welcome email with all access info
- [ ] Test with one new joiner

### Phase 3: Tracker (Week 5-6)
- [ ] Build exception monitoring
- [ ] Create KPI dashboard (simple CLI first)
- [ ] Implement review reminder system
- [ ] Test self-governing loop with simulated exceptions

### Phase 4: Expansion (Week 7+)
- [ ] Add adapters for each system (SSH, GitHub, VPN, etc.)
- [ ] Build service fingerprint generator
- [ ] Integrate firewall rule generation
- [ ] Add OpenBao policy generation

---

## Appendix: Example CLI Commands

```bash
# Onboard new user
iam onboard --request HR-2026-0142.yml

# Show user's access fingerprint
iam fingerprint jane.smith@company.com

# Compare two fingerprints
iam diff bob.jones jane.smith

# Grant exception with justification
iam grant --user jane.smith --permission vault/legacy-app/* \
  --reason "Migration project" --expires 2026-03-01 --ticket PLAT-1234

# List all exceptions for a role
iam exceptions --role platform-engineer

# Trigger access review
iam review --role platform-engineer

# Generate new role from user's fingerprint
iam create-role --from-fingerprint bob.jones --name platform-engineer-plus

# Offboard user
iam offboard jane.smith@company.com --ticket HR-2026-0200

# Show service fingerprint
iam fingerprint --service monitoring-agent

# Apply service to infrastructure
iam apply-service services/new-api-service.yml
```

---

## Summary

This framework addresses your key requirements:

| Requirement | Solution |
|-------------|----------|
| Business owns permissions | DARTIP model with team leads as Deciders |
| Day-one productivity | iam-onboard.sh with role-based provisioning |
| "Copy Bob" problem | Fingerprint diff + automated role creation |
| Exception tracking | Tracker automation with KPIs |
| Provider-agnostic | Logical model + adapters |
| Service provisioning | Service fingerprints → infrastructure as code |
| Security oversight | Approver role + review process |
| Self-governing | Exception thresholds trigger role creation |

The key insight is that **IT doesn't own permissions - IT owns the process**. Business owners define what their teams need; IT provides the infrastructure to make that self-service and auditable.

