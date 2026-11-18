#!/usr/bin/env bash
# Static test for fan canonical integration
# Verifies wrapper points to canonical component and build script copies source
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

errors=0

# Test 1: Wrapper points to canonical fanctl
echo "Test 1: Verifying wrapper delegates to canonical component..."
WRAPPER="$REPO_ROOT/overlay/usr/local/bin/fanctl"
if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: Wrapper not found at $WRAPPER"
    errors=$((errors + 1))
else
    if ! grep -q '/opt/zelux/current/software/zelux-fan/fanctl' "$WRAPPER"; then
        echo "ERROR: Wrapper does not point to canonical fanctl"
        errors=$((errors + 1))
    else
        echo "PASS: Wrapper correctly delegates to canonical component"
    fi
fi

# Test 2: Build script validates and copies fanctl source
echo "Test 2: Verifying assemble-components.sh handles fan source..."
ASSEMBLER="$REPO_ROOT/tools/assemble-components.sh"
if [ ! -f "$ASSEMBLER" ]; then
    echo "ERROR: Assembler not found at $ASSEMBLER"
    errors=$((errors + 1))
else
    if ! grep -q 'FAN=' "$ASSEMBLER"; then
        echo "ERROR: Assembler does not define FAN variable"
        errors=$((errors + 1))
    elif ! grep -q 'mkdir -p.*zelux-fan' "$ASSEMBLER"; then
        echo "ERROR: Assembler does not create zelux-fan directory"
        errors=$((errors + 1))
    elif ! grep -q 'chmod +x.*zelux-fan/fanctl' "$ASSEMBLER"; then
        echo "ERROR: Assembler does not make fanctl executable"
        errors=$((errors + 1))
    else
        echo "PASS: Assembler validates and copies fanctl source"
    fi
fi

# Test 3: Build script copies systemd service units
echo "Test 3: Verifying assemble-components.sh copies systemd units..."
if [ ! -f "$ASSEMBLER" ]; then
    echo "ERROR: Assembler not found at $ASSEMBLER"
    errors=$((errors + 1))
else
    if ! grep -q 'mkdir -p.*software/systemd' "$ASSEMBLER"; then
        echo "ERROR: Assembler does not create software/systemd directory"
        errors=$((errors + 1))
    elif ! grep -q 'overlay/etc/systemd/system.*\.service' "$ASSEMBLER"; then
        echo "ERROR: Assembler does not copy systemd service files"
        errors=$((errors + 1))
    else
        echo "PASS: Assembler copies systemd service units"
    fi
fi

# Test 4: systemd unit points to canonical fanctl
echo "Test 4: Verifying systemd unit uses canonical path..."
SERVICE="$REPO_ROOT/overlay/etc/systemd/system/zelux-fand.service"
if [ ! -f "$SERVICE" ]; then
    echo "ERROR: Service file not found at $SERVICE"
    errors=$((errors + 1))
else
    if ! grep -q 'ExecStart=/opt/zelux/current/software/zelux-fan/fanctl' "$SERVICE"; then
        echo "ERROR: Service does not use canonical fanctl path"
        errors=$((errors + 1))
    else
        echo "PASS: Service uses canonical fanctl path"
    fi
fi

# Test 5: config has required fan fields
echo "Test 5: Verifying zelux.toml has inventory_file and socket_group..."
CONFIG="$REPO_ROOT/overlay/etc/zelux/zelux.toml"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config not found at $CONFIG"
    errors=$((errors + 1))
else
    if ! grep -q 'inventory_file = "/var/lib/zelux-fan/inventory.json"' "$CONFIG"; then
        echo "ERROR: Config missing inventory_file"
        errors=$((errors + 1))
    else
        echo "PASS: Config has inventory_file"
    fi
    if ! grep -q 'socket_group = "zelux"' "$CONFIG"; then
        echo "ERROR: Config missing socket_group"
        errors=$((errors + 1))
    else
        echo "PASS: Config has socket_group"
    fi
fi

# Test 6: install.sh backs up inventory and allows rollback
echo "Test 6: Verifying install.sh handles inventory backup..."
INSTALL="$REPO_ROOT/install.sh"
if [ ! -f "$INSTALL" ]; then
    echo "ERROR: install.sh not found"
    errors=$((errors + 1))
else
    if ! grep -q 'backup_file "/var/lib/zelux-fan/inventory.json"' "$INSTALL"; then
        echo "ERROR: install.sh does not backup inventory.json"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh backs up inventory.json"
    fi
    if ! grep -q '/var/lib/zelux-fan/\*' "$INSTALL"; then
        echo "ERROR: install.sh does not allow rollback of /var/lib/zelux-fan"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh allows rollback of inventory"
    fi
    if ! grep -q 'mkdir -p /var/lib/zelux-fan' "$INSTALL"; then
        echo "ERROR: install.sh does not create /var/lib/zelux-fan directory"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh creates /var/lib/zelux-fan directory"
    fi
fi

# Test 7: components.lock.yaml has fan entry
echo "Test 7: Verifying components.lock.yaml has fan entry..."
LOCK="$REPO_ROOT/components.lock.yaml"
if [ ! -f "$LOCK" ]; then
    echo "ERROR: components.lock.yaml not found"
    errors=$((errors + 1))
else
    if ! grep -q '^fan: local-snapshot$' "$LOCK"; then
        echo "ERROR: components.lock.yaml missing fan entry or has wrong format"
        errors=$((errors + 1))
    else
        echo "PASS: components.lock.yaml has fan: local-snapshot"
    fi
fi

# Test 8: install.sh excludes zelux.toml from rsync to preserve user config
echo "Test 8: Verifying install.sh excludes zelux.toml from rsync..."
INSTALL="$REPO_ROOT/install.sh"
if [ ! -f "$INSTALL" ]; then
    echo "ERROR: install.sh not found"
    errors=$((errors + 1))
else
    if ! grep -q -- "--exclude 'etc/zelux/zelux.toml'" "$INSTALL"; then
        echo "ERROR: install.sh does not exclude etc/zelux/zelux.toml from rsync"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh excludes zelux.toml from rsync"
    fi
fi

# Test 9: install.sh has conditional logic to preserve existing zelux.toml
echo "Test 9: Verifying install.sh has conditional-preserve logic for zelux.toml..."
INSTALL="$REPO_ROOT/install.sh"
if [ ! -f "$INSTALL" ]; then
    echo "ERROR: install.sh not found"
    errors=$((errors + 1))
else
    # Check for existence test
    if ! grep -q '\[ ! -f "/etc/zelux/zelux.toml" \]' "$INSTALL"; then
        echo "ERROR: install.sh missing existence check for /etc/zelux/zelux.toml"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh checks if zelux.toml exists before overwriting"
    fi
    # Check for conditional install
    if ! grep -q 'install.*zelux.toml.*"/etc/zelux/zelux.toml"' "$INSTALL"; then
        echo "ERROR: install.sh missing conditional install of template config"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh conditionally installs template config"
    fi
    # Check for preservation message
    if ! grep -q '保留现有配置.*zelux.toml' "$INSTALL"; then
        echo "ERROR: install.sh missing preservation message for existing config"
        errors=$((errors + 1))
    else
        echo "PASS: install.sh logs preservation of existing config"
    fi
fi

# Test 10: systemd unit has required Environment variables
echo "Test 10: Verifying systemd unit has Environment variables..."
SERVICE="$REPO_ROOT/overlay/etc/systemd/system/zelux-fand.service"
if [ ! -f "$SERVICE" ]; then
    echo "ERROR: Service file not found at $SERVICE"
    errors=$((errors + 1))
else
    if ! grep -q 'Environment=FANCTL_INVENTORY_FILE=/var/lib/zelux-fan/inventory.json' "$SERVICE"; then
        echo "ERROR: Service missing FANCTL_INVENTORY_FILE Environment"
        errors=$((errors + 1))
    else
        echo "PASS: Service has FANCTL_INVENTORY_FILE Environment"
    fi
    if ! grep -q 'Environment=FANCTL_SOCKET_GROUP=zelux' "$SERVICE"; then
        echo "ERROR: Service missing FANCTL_SOCKET_GROUP Environment"
        errors=$((errors + 1))
    else
        echo "PASS: Service has FANCTL_SOCKET_GROUP Environment"
    fi
fi

# Summary
echo "Test 11: Verifying standalone and image fan services are mutually exclusive..."
if ! grep -q '^Conflicts=fanctl.service$' "$SERVICE"; then
    echo "ERROR: image service must conflict with standalone fanctl.service"
    errors=$((errors + 1))
else
    echo "PASS: standalone fan service cannot run alongside image service"
fi
echo ""
if [ "$errors" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "FAILED: $errors test(s) failed"
    exit 1
fi
