# LXD Setup Scripts (Identity Stack)

Scripts to initialize LXD for the identity stack on idp001/idp002.

## Network Configuration

- **Bridge**: lxdbr0
- **Subnet**: 172.22.0.0/24 (different from security-stack's 172.21.x.x)
- **Gateway**: 172.22.0.1
- **DHCP Range**: 172.22.0.50-200

## Container IPs

| Container | Static IP |
|-----------|-----------|
| keycloak-lxc | 172.22.0.10 |
| postgres-lxc | 172.22.0.11 |
| openbao-lxc | 172.22.0.12 |

## Execution Order

Run these scripts in order on each idp node:

```bash
# 1. Initialize LXD (creates local database)
sudo ./setup-lxd-init.sh

# 2. Create network bridge
sudo ./setup-lxd-network.sh

# 3. Create storage pool
sudo ./setup-lxd-storage.sh

# 4. Configure default profile
sudo ./setup-lxd-profile.sh
```

## Verification

After running all scripts:

```bash
lxc network list
lxc storage list
lxc profile show default
```

