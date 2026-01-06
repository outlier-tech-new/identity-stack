# SSH Certificate Identity Model

## Overview

This document describes the complete identity and access model for SSH access to servers in the Outlier Technology infrastructure. It covers:

1. Normal operations (SSH certificates)
2. Breakglass access (passwords)
3. Certificate lifecycle (issuance, validation, revocation)
4. Audit trail
5. Troubleshooting

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           IDENTITY LAYER                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────┐      OIDC       ┌─────────────┐                          │
│   │  KEYCLOAK   │◄───────────────►│  step-ca    │                          │
│   │             │                  │             │                          │
│   │ - Users     │                  │ - SSH CA    │                          │
│   │ - Roles     │                  │ - OIDC      │                          │
│   │ - Groups    │                  │   Provisioner│                         │
│   └──────┬──────┘                  └──────┬──────┘                          │
│          │                                 │                                 │
│          │ authenticates                   │ issues                          │
│          │                                 │                                 │
│          ▼                                 ▼                                 │
│   ┌─────────────┐                  ┌─────────────┐                          │
│   │  OPENBAO    │                  │ SSH CERT    │                          │
│   │             │                  │             │                          │
│   │ - Breakglass│                  │ - Identity  │                          │
│   │   passwords │                  │ - Validity  │                          │
│   │ - Secrets   │                  │ - Principals│                          │
│   └─────────────┘                  └──────┬──────┘                          │
│                                           │                                  │
└───────────────────────────────────────────┼──────────────────────────────────┘
                                            │
                                            │ presents
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SERVER LAYER                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                          TARGET SERVER                               │   │
│   │                                                                      │   │
│   │   Accounts:                     sshd:                                │   │
│   │   ┌──────────┐                  ┌────────────────────────────────┐  │   │
│   │   │ readonly │◄────────────────►│ TrustedUserCAKeys (SSH CA)     │  │   │
│   │   │ ops      │                  │ AuthorizedPrincipalsFile       │  │   │
│   │   │ admin    │                  │ LogLevel VERBOSE               │  │   │
│   │   │ sysadmin │◄─── password ────│                                │  │   │
│   │   └──────────┘                  └────────────────────────────────┘  │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Normal Operations: SSH Certificates

### 1.1 How It Works

1. **User requests certificate**: Runs `step ssh login` command
2. **Keycloak authentication**: Browser opens, user logs in via SSO
3. **step-ca issues certificate**: Contains user identity, allowed principals, validity period
4. **User SSHes to server**: Presents certificate instead of key
5. **sshd validates**: Checks CA signature, principals, validity
6. **Access granted**: User connects as role account with identity logged

### 1.2 Certificate Contents

```
Certificate:
  Type: user certificate
  Serial: 12345
  Key ID: david.tyler@company.com        # Real identity
  Principals:
    - ops@sec001                          # Allowed: ops on sec001
    - ops@sec002                          # Allowed: ops on sec002
    - admin@idp001                        # Allowed: admin on idp001
  Valid: 2026-01-06T10:00:00 to 2026-01-06T22:00:00 (12 hours)
  Critical Options: (none)
  Extensions:
    permit-pty
    permit-user-rc
```

### 1.3 Role Accounts

| Account | Purpose | Sudo | Use Case |
|---------|---------|------|----------|
| `readonly` | Viewing logs, status | None | Monitoring, triage |
| `ops` | Operational tasks | Limited (service restart, log rotation) | Day-to-day operations |
| `admin` | Full administration | Full | Configuration changes |
| `sysadmin` | Breakglass | Full | Emergency only |

### 1.4 Principal Mapping

Keycloak roles determine which principals appear in the certificate:

```yaml
# Keycloak Role → Certificate Principal Mapping
keycloak-role: platform-ops
  principals:
    - ops@sec001
    - ops@sec002
    - ops@idp001
    - ops@idp002
    - readonly@*            # Wildcard for all servers

keycloak-role: platform-admin
  principals:
    - admin@sec001
    - admin@sec002
    - admin@idp001
    - admin@idp002
    - ops@*                 # Includes all ops access
```

---

## 2. Certificate Lifecycle

### 2.1 Issuance

**Who can get a certificate?**
- Any user authenticated to Keycloak
- With at least one SSH-related role assigned
- During their authenticated session

**How long is it valid?**
- Default: 12 hours (configurable)
- Maximum: 24 hours
- Can be shorter for high-security environments

**What principals are included?**
- Determined by Keycloak roles
- Mapped via step-ca OIDC provisioner claims
- User cannot request principals outside their roles

**Command:**
```bash
# Request certificate
step ssh login david.tyler@company.com --provisioner keycloak

# Check current certificate
step ssh list

# Certificate is stored in ~/.ssh/ and ssh-agent
```

### 2.2 Validation (On Each SSH Connection)

sshd checks:
1. **CA Signature**: Certificate signed by trusted CA?
2. **Validity Period**: Current time within valid range?
3. **Principal Match**: Requested account in certificate principals?
4. **Revocation**: Certificate not on revocation list?

```bash
# sshd_config on each server
TrustedUserCAKeys /etc/ssh/ca-user.pub
AuthorizedPrincipalsFile /etc/ssh/principals/%u
RevokedKeys /etc/ssh/revoked_keys        # Optional: for revocation
LogLevel VERBOSE
```

### 2.3 Revocation

**Three levels of revocation:**

#### Level 1: Role Removal (Preferred)
- Remove user from Keycloak role
- Next certificate request will not include that principal
- Existing certificate still works until expiry (max 12 hours)

**When to use:** User changed teams, reduced responsibility

#### Level 2: Session Termination
- Invalidate all Keycloak sessions for user
- Cannot get new certificates
- Existing certificates work until expiry

**When to use:** User leaving company, suspected compromise

#### Level 3: Certificate Revocation (Immediate)
- Add certificate serial to revocation list
- Pushed to all servers
- Immediate denial of access

**When to use:** Active security incident, immediate access removal needed

**Revocation implementation:**
```bash
# Add certificate to revocation list
step ssh revoke --serial 12345

# Push to all servers (automation)
for server in $(cat /etc/servers.txt); do
  scp /etc/ssh/revoked_keys $server:/etc/ssh/revoked_keys
  ssh $server "systemctl reload sshd"
done
```

### 2.4 Renewal

- Certificates are short-lived (12 hours)
- User runs `step ssh login` again when expired
- Requires fresh Keycloak authentication
- Automatically re-evaluates current roles

---

## 3. Breakglass Access

### 3.1 When to Use

- step-ca or Keycloak is down
- Network partition preventing certificate issuance
- Console access required (KVM, IPMI)
- Emergency recovery scenario

### 3.2 Breakglass Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ BREAKGLASS ACCESS WORKFLOW                                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. AUTHENTICATE TO OPENBAO                                                  │
│     ┌────────────────┐                                                       │
│     │  OpenBao UI    │◄──── OIDC via Keycloak                               │
│     │  or CLI        │      (if available)                                   │
│     └───────┬────────┘      or direct auth                                   │
│             │                                                                │
│  2. RETRIEVE PASSWORD                                                        │
│             │                                                                │
│             ▼                                                                │
│     ┌────────────────┐                                                       │
│     │ secrets/servers│      OpenBao logs:                                    │
│     │ /sec001/       │      "david.tyler read                                │
│     │ sysadmin       │       secrets/.../sysadmin                            │
│     └───────┬────────┘       at 14:02:33"                                    │
│             │                                                                │
│  3. CONNECT TO SERVER                                                        │
│             │                                                                │
│             ▼                                                                │
│     ┌────────────────┐                                                       │
│     │  SSH or        │      sshd logs:                                       │
│     │  Console       │      "Accepted password for                           │
│     │  (password)    │       sysadmin from 192.168.x.x                       │
│     └───────┬────────┘       at 14:05:12"                                    │
│             │                                                                │
│  4. ROTATE PASSWORD                                                          │
│             │                                                                │
│             ▼                                                                │
│     ┌────────────────┐                                                       │
│     │ Change password│      Auto-rotate or                                   │
│     │ on server +    │      manual trigger                                   │
│     │ OpenBao        │                                                       │
│     └────────────────┘                                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Audit Correlation

```
OpenBao Audit Log:
  2026-01-06 14:02:33 | david.tyler | READ | secrets/data/servers/sec001/sysadmin

SSH Auth Log (sec001):
  2026-01-06 14:05:12 | sysadmin | PASSWORD | from 192.168.1.50 | SUCCESS

Correlation:
  → david.tyler retrieved sec001 sysadmin password at 14:02
  → sysadmin login from david's IP (192.168.1.50) at 14:05
  → Conclusion: david.tyler accessed sec001 as sysadmin
```

### 3.4 Offline Backup

For catastrophic scenarios (OpenBao and Keycloak both down):

- Physical safe contains sealed envelopes
- Each envelope: server hostname + sysadmin password
- Opening triggers full security review
- All passwords rotated after use
- Envelope contents updated after rotation

---

## 4. Audit Trail

### 4.1 What Gets Logged Where

| Event | System | Log Location |
|-------|--------|--------------|
| User login to Keycloak | Keycloak | Keycloak events |
| Certificate issued | step-ca | step-ca logs |
| SSH connection (cert) | Target server | /var/log/auth.log |
| Password retrieved | OpenBao | OpenBao audit log |
| SSH connection (password) | Target server | /var/log/auth.log |
| Commands executed | Target server | /var/log/auth.log, auditd |

### 4.2 Sample Log Entries

**Certificate-based login:**
```
Jan  6 14:30:00 sec001 sshd[12345]: Accepted publickey for ops from 192.168.1.50 port 54321 ssh2: 
  ED25519-CERT SHA256:abc123 ID david.tyler@company.com (serial 67890) CA ED25519 SHA256:xyz789
```

**Password-based login (breakglass):**
```
Jan  6 14:35:00 sec001 sshd[12346]: Accepted password for sysadmin from 192.168.1.50 port 54322 ssh2
```

### 4.3 Daily Audit Report

```bash
#!/bin/bash
# Daily SSH access audit

echo "=== Certificate Logins (Normal) ==="
grep "Accepted publickey" /var/log/auth.log | \
  grep "$(date +%Y-%m-%d)" | \
  awk '{print $1, $2, $3, "User:", $11, "Account:", $9, "From:", $11}'

echo "=== Password Logins (Breakglass) ==="
grep "Accepted password" /var/log/auth.log | \
  grep "$(date +%Y-%m-%d)" | \
  awk '{print $1, $2, $3, "Account:", $9, "From:", $11}'

echo "=== Failed Logins ==="
grep "Failed" /var/log/auth.log | \
  grep "$(date +%Y-%m-%d)"
```

---

## 5. Server Configuration

### 5.1 sshd_config

```bash
# /etc/ssh/sshd_config

# Trust the SSH User CA
TrustedUserCAKeys /etc/ssh/ca-user.pub

# Map principals to allowed accounts
AuthorizedPrincipalsFile /etc/ssh/principals/%u

# Optional: Certificate revocation
RevokedKeys /etc/ssh/revoked_keys

# Enable detailed logging for audit
LogLevel VERBOSE

# Password auth only for sysadmin (breakglass)
Match User sysadmin
    PasswordAuthentication yes
    
Match User ops,admin,readonly
    PasswordAuthentication no
    PubkeyAuthentication yes
```

### 5.2 Principal Files

```bash
# /etc/ssh/principals/ops
# Users with these principals can SSH as 'ops'
ops@sec001
platform-ops

# /etc/ssh/principals/admin
admin@sec001
platform-admin

# /etc/ssh/principals/readonly
readonly@sec001
platform-readonly
readonly@*
```

### 5.3 CA Public Key

```bash
# /etc/ssh/ca-user.pub
# This is the step-ca SSH user CA public key
# Obtained from: step ssh config --roots
ssh-ed25519 AAAA... step-ca-user-ca
```

---

## 6. Client Workflow

### 6.1 Initial Setup (One Time)

```bash
# Install step CLI
curl -sL https://dl.step.sm/install.sh | bash

# Bootstrap step-ca (trusts the CA)
step ca bootstrap --ca-url https://ca.outliertechnology.co.uk \
                  --fingerprint <CA_FINGERPRINT>

# Configure SSH
step ssh config --roots > ~/.step/ssh/known_hosts
```

### 6.2 Daily Use

```bash
# Get certificate (opens browser for Keycloak login)
step ssh login david.tyler@company.com --provisioner keycloak

# List current certificates
step ssh list

# SSH to server
ssh ops@sec001.outliertechnology.co.uk

# SSH with explicit identity (if multiple certs)
ssh -o CertificateFile=~/.ssh/id_ecdsa-cert.pub ops@sec001
```

### 6.3 Certificate Expired

```bash
# Check expiry
step ssh list --expired

# Renew (re-authenticates via Keycloak)
step ssh login david.tyler@company.com --provisioner keycloak
```

---

## 7. Troubleshooting

### 7.1 "Permission denied"

**Check 1: Certificate valid?**
```bash
step ssh list
# Look for expiry time
```

**Check 2: Principal included?**
```bash
step ssh inspect ~/.ssh/id_ecdsa-cert.pub
# Look for "Principals:" section
```

**Check 3: Server trusts CA?**
```bash
# On server
cat /etc/ssh/ca-user.pub
# Should match step-ca user CA public key
```

**Check 4: Principal file configured?**
```bash
# On server
cat /etc/ssh/principals/ops
# Should include your certificate's principals
```

### 7.2 "No certificate or key found"

```bash
# Re-login to get new certificate
step ssh login david.tyler@company.com --provisioner keycloak
```

### 7.3 "Certificate has been revoked"

Contact administrator - your certificate was explicitly revoked.
Need investigation before new certificate issuance.

### 7.4 Breakglass Not Working

1. Check OpenBao is accessible
2. Verify Keycloak authentication to OpenBao
3. Check OpenBao policy allows access to secrets path
4. Verify password in OpenBao matches server

---

## 8. Quick Reference

### Access Matrix

| Role | readonly | ops | admin | sysadmin |
|------|----------|-----|-------|----------|
| View logs | ✓ | ✓ | ✓ | ✓ |
| Restart services | ✗ | ✓ | ✓ | ✓ |
| Change config | ✗ | ✗ | ✓ | ✓ |
| Install packages | ✗ | ✗ | ✓ | ✓ |
| User management | ✗ | ✗ | ✓ | ✓ |
| Auth method | Cert | Cert | Cert | Password |
| Normal use | ✓ | ✓ | ✓ | ✗ |
| Breakglass only | ✗ | ✗ | ✗ | ✓ |

### Keycloak Role → Server Access

| Keycloak Role | Server Accounts |
|---------------|-----------------|
| platform-readonly | readonly@* |
| platform-ops | ops@*, readonly@* |
| platform-admin | admin@*, ops@*, readonly@* |
| breakglass-{server} | sysadmin@{server} (via OpenBao) |

### Commands Cheatsheet

```bash
# Get SSH certificate
step ssh login user@company.com --provisioner keycloak

# List certificates
step ssh list

# Inspect certificate
step ssh inspect ~/.ssh/id_ecdsa-cert.pub

# SSH to server
ssh ops@server.company.com

# Revoke certificate (admin)
step ssh revoke --serial 12345
```

---

## 9. Related Documents

- [ADR-003: Identity/Secrets Separation](adr/003-identity-secrets-separation.md)
- [ADR-004: SSH Shared Accounts with Certificate Identity](adr/004-ssh-shared-accounts-certificate-identity.md)
- [ADR-005: Breakglass Access Model](adr/005-breakglass-access-model.md)
- [Operator Manual](operator-manual.md)
- [Access Governance Framework](access-governance-framework.md)

