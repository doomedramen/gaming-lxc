#!/bin/bash
# Gaming LXC Setup Script for Proxmox
# Based on the complete guide in README.md
#
# IMPORTANT FIXES INCLUDED (discovered during troubleshooting):
# - Sunshine v0.23.1 (stable) - avoids FFmpeg 7.1 segmentation fault with AMD GPUs
# - GPU driver packages: mesa-opencl-icd, ocl-icd-libopencl1, clinfo for AMD compatibility
# - VAAPI configuration: encoder=vaapi, adapter_name=/dev/dri/renderD128, sw_preset=medium
# - Network configuration: address_family=ipv4 for proper IPv4 binding
# - LightDM default display manager fix: /etc/X11/default-display-manager = /usr/sbin/lightdm
# - Firewall ports: UDP 47998-48000 range for complete Moonlight compatibility
# - Systemd service: pre-created runtime directories and CAP_SYS_ADMIN capability
# - Container capabilities: lxc.cap.keep: sys_admin for Sunshine compatibility
# - Input device passthrough: /dev/input binding and cgroup permissions (c 13:* rwm)
# - User permissions: gamer user added to input group for proper device access

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
CTID=""
GPU_BUS_ID=""
CONTAINER_MEMORY="8192"
CONTAINER_CORES="4"
CONTAINER_STORAGE="32"
GAMER_PASSWORD=""

# Logging
LOG_FILE="/tmp/gaming-lxc-setup.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

print_header() {
    echo -e "\n${BLUE}=================================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=================================================================================${NC}\n"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root on the Proxmox host"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pct &> /dev/null; then
        print_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    
    print_step "Running on Proxmox VE $(pveversion | head -n1)"
}

find_next_available_ctid() {
    local start_id=200
    local ctid=$start_id
    
    while pct status "$ctid" &>/dev/null; do
        ctid=$((ctid + 1))
        if [[ $ctid -gt 999 ]]; then
            echo "300"  # Fallback if 200-999 range is full
            return
        fi
    done
    
    echo "$ctid"
}

detect_primary_gpu() {
    # Find the first AMD GPU (prefer discrete over integrated)
    local gpu_list=$(lspci | grep -i amd | grep -i vga | grep -E "(Radeon|RX|Vega)" | head -1)
    if [[ -z "$gpu_list" ]]; then
        # Fallback to any AMD VGA device
        gpu_list=$(lspci | grep -i amd | grep -i vga | head -1)
    fi
    
    if [[ -n "$gpu_list" ]]; then
        echo "$gpu_list" | awk '{print $1}'
    else
        echo ""
    fi
}

gather_configuration() {
    print_header "CONFIGURATION SETUP"
    
    # Auto-detect defaults
    local default_ctid=$(find_next_available_ctid)
    local default_gpu=$(detect_primary_gpu)
    
    print_step "Auto-detected defaults:"
    echo "  Container ID: $default_ctid"
    echo "  GPU Bus ID: ${default_gpu:-"Not detected"}"
    echo "  Memory: ${CONTAINER_MEMORY}MB"
    echo "  CPU Cores: $CONTAINER_CORES"
    echo "  Storage: ${CONTAINER_STORAGE}GB"
    echo
    
    # Get container ID with default
    while [[ -z "$CTID" ]]; do
        read -p "Enter container ID [default: $default_ctid]: " input_ctid
        CTID=${input_ctid:-$default_ctid}
        
        # Validate CTID is a valid integer
        if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
            print_warning "Container ID must be a positive integer."
            CTID=""
            continue
        fi
        
        # Check if CTID is in valid range (100-999 for containers)
        if [[ "$CTID" -lt 100 || "$CTID" -gt 999 ]]; then
            print_warning "Container ID should be between 100 and 999."
            CTID=""
            continue
        fi
        
        if pct status "$CTID" &>/dev/null; then
            print_warning "Container $CTID already exists. Choose a different ID."
            CTID=""
        fi
    done
    
    # Get GPU information with auto-detection
    print_step "Available AMD GPUs:"
    lspci | grep -i amd | grep -i vga
    echo
    
    while [[ -z "$GPU_BUS_ID" ]]; do
        if [[ -n "$default_gpu" ]]; then
            read -p "Enter your primary GPU bus ID [default: $default_gpu]: " input_gpu
            GPU_BUS_ID=${input_gpu:-$default_gpu}
        else
            read -p "Enter your primary GPU bus ID (e.g., 03:00.0): " GPU_BUS_ID
        fi
        
        if ! lspci -s "$GPU_BUS_ID" &>/dev/null; then
            print_warning "Bus ID $GPU_BUS_ID not found. Please check with 'lspci | grep -i amd'"
            GPU_BUS_ID=""
        fi
    done
    
    # Convert bus ID format (03:00.0 -> PCI:3:0:0)
    IFS=':.' read -r bus dev func <<< "$GPU_BUS_ID"
    X11_BUS_ID="PCI:$((10#$bus)):$((10#$dev)):$((10#$func))"
    
    # Get container specifications with defaults
    echo
    
    # Validate memory input
    while true; do
        read -p "Enter container memory in MB [default: $CONTAINER_MEMORY]: " input_memory
        CONTAINER_MEMORY=${input_memory:-$CONTAINER_MEMORY}
        if [[ "$CONTAINER_MEMORY" =~ ^[0-9]+$ ]] && [[ "$CONTAINER_MEMORY" -ge 1024 ]]; then
            break
        else
            print_warning "Memory must be a positive integer >= 1024 MB"
        fi
    done
    
    # Validate cores input
    while true; do
        read -p "Enter container CPU cores [default: $CONTAINER_CORES]: " input_cores
        CONTAINER_CORES=${input_cores:-$CONTAINER_CORES}
        if [[ "$CONTAINER_CORES" =~ ^[0-9]+$ ]] && [[ "$CONTAINER_CORES" -ge 1 ]] && [[ "$CONTAINER_CORES" -le 32 ]]; then
            break
        else
            print_warning "CPU cores must be a positive integer between 1 and 32"
        fi
    done
    
    # Validate storage input
    while true; do
        read -p "Enter container storage in GB [default: $CONTAINER_STORAGE]: " input_storage
        CONTAINER_STORAGE=${input_storage:-$CONTAINER_STORAGE}
        if [[ "$CONTAINER_STORAGE" =~ ^[0-9]+$ ]] && [[ "$CONTAINER_STORAGE" -ge 8 ]]; then
            break
        else
            print_warning "Storage must be a positive integer >= 8 GB"
        fi
    done
    
    # Get gamer password
    echo
    while [[ -z "$GAMER_PASSWORD" ]]; do
        read -s -p "Enter password for 'gamer' user: " GAMER_PASSWORD
        echo
        read -s -p "Confirm password: " GAMER_PASSWORD_CONFIRM
        echo
        if [[ "$GAMER_PASSWORD" != "$GAMER_PASSWORD_CONFIRM" ]]; then
            print_warning "Passwords do not match"
            GAMER_PASSWORD=""
        fi
    done
    
    # Confirm configuration
    echo -e "\n${BLUE}Final Configuration Summary:${NC}"
    echo "Container ID: $CTID"
    echo "GPU Bus ID: $GPU_BUS_ID -> $X11_BUS_ID"
    echo "Memory: ${CONTAINER_MEMORY}MB"
    echo "Cores: $CONTAINER_CORES"
    echo "Storage: ${CONTAINER_STORAGE}GB"
    echo
    
    read -p "Proceed with this configuration? [Y/n]: " confirm
    confirm=${confirm:-Y}  # Default to Y if user just presses Enter
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_error "Setup cancelled by user"
        exit 1
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" && ! -f "${file}.backup-$(date +%Y%m%d)" ]]; then
        cp "$file" "${file}.backup-$(date +%Y%m%d)"
        print_step "Created backup: ${file}.backup-$(date +%Y%m%d)"
    fi
}

safe_append_to_file() {
    local content="$1"
    local file="$2"
    local marker="$3"
    
    # Check if content already exists
    if ! grep -q "$marker" "$file" 2>/dev/null; then
        echo "$content" >> "$file"
        print_step "Added $marker to $file"
    else
        print_warning "$marker already exists in $file, skipping"
    fi
}

setup_proxmox_host() {
    print_header "PHASE 1: PROXMOX HOST PREPARATION"
    
    print_step "Configuring GRUB for GPU passthrough"
    
    # Check if GRUB is already configured
    if grep -q "amd_iommu=on" /etc/default/grub; then
        print_warning "GRUB already configured for AMD IOMMU"
    else
        backup_file "/etc/default/grub"
        
        # Get current GRUB_CMDLINE_LINUX_DEFAULT
        current_cmdline=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | cut -d'"' -f2)
        
        # Check if it already contains our parameters
        if [[ "$current_cmdline" == *"amd_iommu=on"* ]]; then
            print_warning "GRUB already contains AMD IOMMU parameters"
        else
            # Add our parameters to existing cmdline
            new_cmdline="$current_cmdline amd_iommu=on iommu=pt video=efifb:off"
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_cmdline\"|" /etc/default/grub
            update-grub
            print_warning "GRUB updated. System will need reboot after setup completion."
        fi
    fi
    
    print_step "Loading required kernel modules"
    
    # Add modules to load at boot safely
    for module in amdgpu drm uinput; do
        safe_append_to_file "$module" "/etc/modules" "$module"
        
        # Load module immediately if not already loaded
        if ! lsmod | grep -q "^$module"; then
            modprobe "$module" 2>/dev/null || print_warning "Failed to load $module module"
        fi
    done
    
    print_step "Setting up device permissions"
    
    # GPU permissions - only create if doesn't exist
    if [[ ! -f "/etc/udev/rules.d/99-gpu-permissions.rules" ]]; then
        cat > /etc/udev/rules.d/99-gpu-permissions.rules << 'EOF'
SUBSYSTEM=="drm", KERNEL=="card*", GROUP="render", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
EOF
        print_step "Created GPU permissions udev rule"
    else
        print_warning "GPU permissions udev rule already exists"
    fi
    
    # uinput permissions - only create if doesn't exist
    if [[ ! -f "/etc/udev/rules.d/99-uinput-permissions.rules" ]]; then
        cat > /etc/udev/rules.d/99-uinput-permissions.rules << 'EOF'
KERNEL=="uinput", GROUP="input", MODE="0660"
EOF
        print_step "Created uinput permissions udev rule"
    else
        print_warning "uinput permissions udev rule already exists"
    fi
    
    # Apply udev rules
    udevadm control --reload-rules
    udevadm trigger
    
    # Set immediate permissions
    if [[ -e /dev/uinput ]]; then
        chgrp input /dev/uinput 2>/dev/null || true
        chmod 660 /dev/uinput 2>/dev/null || true
    fi
    
    print_step "Verifying host GPU access"
    ls -la /dev/dri/ || print_warning "No DRI devices found"
    
    # Additional pre-creation checks
    print_step "Pre-creation validation"
    
    # Check if render device exists
    if [[ ! -e /dev/dri/renderD128 ]]; then
        print_warning "Primary render device /dev/dri/renderD128 not found"
        print_step "Available DRI devices:"
        ls -la /dev/dri/ 2>/dev/null || echo "No DRI devices available"
    else
        print_step "✓ Primary render device /dev/dri/renderD128 found"
        ls -la /dev/dri/renderD128
    fi
    
    # Check if input devices are available
    if [[ -d /dev/input ]]; then
        print_step "✓ Input devices directory found"
        input_count=$(ls /dev/input/ 2>/dev/null | wc -l)
        print_step "Found $input_count input devices"
    else
        print_warning "Input devices directory not found"
    fi
    
    # Check uinput
    if [[ -e /dev/uinput ]]; then
        print_step "✓ uinput device found"
        ls -la /dev/uinput
    else
        print_warning "uinput device not found"
    fi
}

create_lxc_container() {
    print_header "PHASE 2: CREATE LXC CONTAINER"
    
    print_step "Updating template list"
    pveam update
    
    print_step "Downloading Ubuntu 22.04 template"
    
    # Try to find the latest Ubuntu 22.04 template
    local template_name=""
    local available_templates=""
    
    # Get available Ubuntu 22.04 templates
    available_templates=$(pveam available | grep "ubuntu-22.04-standard" | head -1)
    
    if [[ -n "$available_templates" ]]; then
        template_name=$(echo "$available_templates" | awk '{print $2}')
        print_step "Found available template: $template_name"
    else
        # Fallback to expected name
        template_name="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
        print_warning "Using fallback template name: $template_name"
    fi
    
    # Check if template already exists locally
    if ! pveam list local | grep -q "ubuntu-22.04-standard"; then
        print_step "Template not found locally, downloading: $template_name"
        if ! pveam download local "$template_name"; then
            print_error "Failed to download template $template_name"
            print_step "Available Ubuntu templates:"
            pveam available | grep ubuntu | head -10
            print_step "Local templates:"
            pveam list local
            exit 1
        fi
    else
        print_warning "Ubuntu 22.04 template already downloaded"
    fi
    
    # Get the exact template filename from the local storage
    local template_file=""
    local template_path=""
    
    # Get the full line and extract the template identifier
    local template_line=$(pveam list local | grep "ubuntu-22.04-standard" | head -1)
    
    if [[ -n "$template_line" ]]; then
        # Extract the template identifier (first column) which should be like "local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
        template_path=$(echo "$template_line" | awk '{print $1}')
        print_step "Found template: $template_path"
    else
        print_error "Could not find downloaded template file"
        print_step "Available local templates:"
        pveam list local
        print_step "Debug: Looking for ubuntu-22.04-standard in:"
        pveam list local | grep "ubuntu" || echo "No Ubuntu templates found"
        exit 1
    fi
    
    # Pre-creation device validation
    print_step "Validating GPU devices before container creation"
    
    # Check major:minor numbers for DRI devices
    if [[ -e /dev/dri/renderD128 ]]; then
        local render_major=$(stat -c "%t" /dev/dri/renderD128)
        local render_minor=$(stat -c "%T" /dev/dri/renderD128)
        print_step "renderD128 device: major=$((0x$render_major)), minor=$((0x$render_minor))"
    else
        print_error "Critical: /dev/dri/renderD128 not found. GPU passthrough will fail."
        exit 1
    fi
    
    if [[ -e /dev/dri/card0 ]]; then
        local card_major=$(stat -c "%t" /dev/dri/card0)
        local card_minor=$(stat -c "%T" /dev/dri/card0)
        print_step "card0 device: major=$((0x$card_major)), minor=$((0x$card_minor))"
    fi
    
    # Check if devices are accessible
    if ! ls -la /dev/dri/renderD128 >/dev/null 2>&1; then
        print_error "Cannot access /dev/dri/renderD128"
        exit 1
    fi
    
    # Debug output for parameters
    print_step "Container creation parameters:"
    echo "  CTID: '$CTID'"
    echo "  Template: '$template_path'"
    echo "  Memory: '$CONTAINER_MEMORY'"
    echo "  Cores: '$CONTAINER_CORES'"
    echo "  Storage: '$CONTAINER_STORAGE'"
    
    print_step "Creating LXC container $CTID (without GPU passthrough initially)"
    
    # Validate all parameters before creating container
    if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
        print_error "Invalid CTID: '$CTID' - must be numeric"
        exit 1
    fi
    
    if ! [[ "$CONTAINER_MEMORY" =~ ^[0-9]+$ ]]; then
        print_error "Invalid memory: '$CONTAINER_MEMORY' - must be numeric"
        exit 1
    fi
    
    if ! [[ "$CONTAINER_CORES" =~ ^[0-9]+$ ]]; then
        print_error "Invalid cores: '$CONTAINER_CORES' - must be numeric"
        exit 1
    fi
    
    if ! [[ "$CONTAINER_STORAGE" =~ ^[0-9]+$ ]]; then
        print_error "Invalid storage: '$CONTAINER_STORAGE' - must be numeric"
        exit 1
    fi
    
    # Create the container WITHOUT GPU passthrough first
    if ! pct create "$CTID" "$template_path" \
        --hostname gaming-lxc \
        --memory "$CONTAINER_MEMORY" \
        --cores "$CONTAINER_CORES" \
        --rootfs local-lvm:"$CONTAINER_STORAGE" \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --unprivileged 0 \
        --features nesting=1,keyctl=1 \
        --startup order=2; then
        print_error "Failed to create LXC container $CTID"
        print_step "Debugging information:"
        echo "  pct version: $(pct --version 2>/dev/null || echo 'unknown')"
        echo "  Available storage: $(pvesm status | grep local-lvm || echo 'local-lvm not found')"
        echo "  Memory limit check: $(free -m | grep Mem || echo 'memory info unavailable')"
        exit 1
    fi
    
    print_step "Testing basic container startup (without GPU)"
    if ! pct start "$CTID"; then
        print_error "Failed to start basic container $CTID"
        print_step "Container status:"
        pct status "$CTID" || true
        print_step "Container configuration:"
        cat "/etc/pve/lxc/$CTID.conf" || true
        exit 1
    fi
    
    # Wait for basic container to be ready
    print_step "Waiting for basic container to be ready..."
    local timeout=30
    local count=0
    while ! pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; do
        sleep 2
        count=$((count + 2))
        if [[ $count -gt $timeout ]]; then
            print_error "Basic container failed to start properly after $timeout seconds"
            exit 1
        fi
    done
    
    print_step "✓ Basic container is working. Now adding GPU passthrough step by step..."
    
    # Stop container before modifying config
    pct stop "$CTID"
    
    # Add GPU passthrough configuration step by step
    print_step "Adding minimal GPU passthrough configuration"
    
    # Start with just the render device (most conservative)
    cat >> "/etc/pve/lxc/$CTID.conf" << EOF
# Minimal GPU passthrough - render device only
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
    
    print_step "Testing container with minimal GPU passthrough..."
    if pct start "$CTID"; then
        print_step "✓ Container starts with render device passthrough"
        
        # Wait for container to be ready
        local timeout=30
        local count=0
        while ! pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; do
            sleep 2
            count=$((count + 2))
            if [[ $count -gt $timeout ]]; then
                print_error "Container with GPU passthrough failed to start properly"
                break
            fi
        done
        
        if pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; then
            print_step "✓ Container with GPU passthrough is ready"
            
            # Test GPU device access
            if pct exec "$CTID" -- test -e /dev/dri/renderD128; then
                print_step "✓ GPU render device is accessible in container"
            else
                print_warning "⚠ GPU render device not accessible in container"
            fi
            
            # Stop container to add more devices
            pct stop "$CTID"
            
            # Add card device if it exists
            if [[ -e /dev/dri/card0 ]]; then
                print_step "Adding card0 device..."
                cat >> "/etc/pve/lxc/$CTID.conf" << EOF
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
EOF
            fi
            
            # Add input devices if they exist
            if [[ -d /dev/input ]]; then
                print_step "Adding input devices..."
                cat >> "/etc/pve/lxc/$CTID.conf" << EOF
# Input devices
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
EOF
            fi
            
            # Add uinput if it exists
            if [[ -e /dev/uinput ]]; then
                print_step "Adding uinput device..."
                cat >> "/etc/pve/lxc/$CTID.conf" << EOF
# uinput device
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file
EOF
            fi
            
            # Add sys_admin capability for Sunshine
            cat >> "/etc/pve/lxc/$CTID.conf" << EOF
# Capabilities for Sunshine
lxc.cap.keep: sys_admin
EOF
            
            print_step "Starting container with full GPU passthrough configuration..."
            
            # Capture pct start output to detect monitor socket issues
            local start_output=""
            if start_output=$(pct start "$CTID" 2>&1); then
                # Check if the output contains monitor socket timeout (indicates problematic start)
                if echo "$start_output" | grep -q "problem with monitor socket.*timeout"; then
                    print_warning "Detected monitor socket timeout - container startup is problematic"
                    print_step "Immediately falling back to GPU-only configuration..."
                    
                    # Stop and remove problematic config immediately
                    pct stop "$CTID" 2>/dev/null || true
                    sed -i '/lxc.mount.entry.*dev\/input/d' "/etc/pve/lxc/$CTID.conf"
                    sed -i '/lxc.mount.entry.*dev\/uinput/d' "/etc/pve/lxc/$CTID.conf"
                    sed -i '/lxc.cgroup2.devices.allow.*13/d' "/etc/pve/lxc/$CTID.conf"
                    sed -i '/lxc.cgroup2.devices.allow.*10:223/d' "/etc/pve/lxc/$CTID.conf"
                    sed -i '/lxc.cap.keep.*sys_admin/d' "/etc/pve/lxc/$CTID.conf"
                    
                    print_step "Starting with GPU-only configuration..."
                    if ! pct start "$CTID"; then
                        print_error "Container still fails with minimal GPU config"
                        exit 1
                    fi
                    print_warning "Using GPU-only configuration (input devices will be configured later)"
                else
                    print_step "✓ Container started with full GPU configuration successfully"
                    
                    # Quick test to verify container is actually responsive
                    print_step "Verifying container responsiveness..."
                    local quick_timeout=10
                    local quick_count=0
                    local container_responsive=false
                    
                    while [[ $quick_count -lt $quick_timeout ]]; do
                        if pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; then
                            container_responsive=true
                            break
                        fi
                        sleep 1
                        quick_count=$((quick_count + 1))
                    done
                    
                    if [[ "$container_responsive" == "true" ]]; then
                        print_step "✓ Container with full configuration is ready and responsive"
                    else
                        print_warning "Container not responsive, falling back to GPU-only configuration..."
                        
                        # Stop and remove problematic config
                        pct stop "$CTID" 2>/dev/null || true
                        sed -i '/lxc.mount.entry.*dev\/input/d' "/etc/pve/lxc/$CTID.conf"
                        sed -i '/lxc.mount.entry.*dev\/uinput/d' "/etc/pve/lxc/$CTID.conf"
                        sed -i '/lxc.cgroup2.devices.allow.*13/d' "/etc/pve/lxc/$CTID.conf"
                        sed -i '/lxc.cgroup2.devices.allow.*10:223/d' "/etc/pve/lxc/$CTID.conf"
                        sed -i '/lxc.cap.keep.*sys_admin/d' "/etc/pve/lxc/$CTID.conf"
                        
                        if ! pct start "$CTID"; then
                            print_error "Container still fails with minimal GPU config"
                            exit 1
                        fi
                        print_warning "Using GPU-only configuration (input devices will be configured later)"
                    fi
                fi
            else
                print_error "Container failed to start with full GPU configuration"
                print_step "Removing problematic config and using minimal setup..."
                
                # Remove the last additions and use minimal config
                pct stop "$CTID" 2>/dev/null || true
                sed -i '/lxc.mount.entry.*dev\/input/d' "/etc/pve/lxc/$CTID.conf"
                sed -i '/lxc.mount.entry.*dev\/uinput/d' "/etc/pve/lxc/$CTID.conf"
                sed -i '/lxc.cgroup2.devices.allow.*13/d' "/etc/pve/lxc/$CTID.conf"
                sed -i '/lxc.cgroup2.devices.allow.*10:223/d' "/etc/pve/lxc/$CTID.conf"
                sed -i '/lxc.cap.keep.*sys_admin/d' "/etc/pve/lxc/$CTID.conf"
                
                print_step "Testing with GPU-only configuration..."
                if ! pct start "$CTID"; then
                    print_error "Container still fails with minimal GPU config"
                    exit 1
                fi
                print_step "✓ Container works with GPU-only config (no input devices)"
            fi
        else
            print_error "Container with GPU passthrough failed to become ready"
            exit 1
        fi
    else
        print_error "Container fails to start even with minimal GPU passthrough"
        print_step "Reverting to no GPU passthrough and continuing..."
        
        # Remove GPU config
        sed -i '/lxc.cgroup2.devices.allow.*226/d' "/etc/pve/lxc/$CTID.conf"
        sed -i '/lxc.mount.entry.*dev\/dri/d' "/etc/pve/lxc/$CTID.conf"
        
        if ! pct start "$CTID"; then
            print_error "Container fails to start even without GPU passthrough"
            exit 1
        fi
        
        print_warning "Continuing setup without GPU passthrough - will need manual configuration later"
    fi
    
    # Final wait for container to be ready
    print_step "Waiting for container to be ready..."
    local timeout=60
    local count=0
    while ! pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; do
        sleep 2
        count=$((count + 2))
        if [[ $count -gt $timeout ]]; then
            print_error "Container failed to start properly after $timeout seconds"
            exit 1
        fi
        
        # Show progress
        if [[ $((count % 10)) -eq 0 ]]; then
            echo -n "."
        fi
    done
    
    echo  # New line after progress dots
    print_step "Container is ready"
}

setup_container_system() {
    print_header "PHASE 3: CONTAINER SYSTEM SETUP"
    
    print_step "Updating system packages"
    pct exec "$CTID" -- bash -c "apt update && apt upgrade -y"
    
    print_step "Installing essential packages"
    pct exec "$CTID" -- apt install -y curl wget gnupg software-properties-common \
        build-essential git nano htop net-tools
    
    print_step "Installing GPU drivers and graphics libraries"
    pct exec "$CTID" -- apt install -y mesa-utils mesa-vulkan-drivers \
        libgl1-mesa-dri libglx-mesa0 libgl1-mesa-glx \
        vulkan-tools mesa-opencl-icd ocl-icd-libopencl1 clinfo
    
    print_step "Enabling 32-bit architecture for Steam"
    pct exec "$CTID" -- bash -c "dpkg --add-architecture i386 && apt update"
    
    print_step "Verifying GPU passthrough"
    pct exec "$CTID" -- ls -la /dev/dri/
    pct exec "$CTID" -- bash -c "vulkaninfo --summary 2>/dev/null | head -10 || echo 'Vulkan info not available yet'"
}

setup_desktop_environment() {
    print_header "PHASE 4: DESKTOP ENVIRONMENT SETUP"
    
    print_step "Installing XFCE desktop environment"
    pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt install -y xfce4 xfce4-goodies lightdm xorg xserver-xorg-video-amdgpu"
    
    print_step "Creating X11 configuration for GPU $X11_BUS_ID"
    pct exec "$CTID" -- mkdir -p /etc/X11/xorg.conf.d/
    
    cat > /tmp/20-amd.conf << EOF
Section "Device"
    Identifier "AMD-Vega"
    Driver "amdgpu"
    BusID "$X11_BUS_ID"
    Option "DRI" "3"
    Option "TearFree" "true"
    Option "VariableRefresh" "true"
    Option "EnablePageFlip" "true"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "AMD-Vega"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "2560x1440" "1680x1050" "1600x900" "1440x900" "1280x720"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync 30.0-83.0
    VertRefresh 56.0-76.0
EndSection

Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection
EOF
    
    pct push "$CTID" /tmp/20-amd.conf /etc/X11/xorg.conf.d/20-amd.conf
    rm /tmp/20-amd.conf
    
    print_step "Creating gaming user"
    if ! pct exec "$CTID" -- id gamer &>/dev/null; then
        pct exec "$CTID" -- useradd -m -s /bin/bash gamer
        pct exec "$CTID" -- usermod -aG audio,video,render,input gamer
        
        # Set password
        pct exec "$CTID" -- bash -c "echo 'gamer:$GAMER_PASSWORD' | chpasswd"
        print_step "Created gamer user with input device access"
    else
        print_warning "Gamer user already exists"
        # Ensure user is in input group
        pct exec "$CTID" -- usermod -aG input gamer
    fi
    
    print_step "Configuring auto-login"
    cat > /tmp/lightdm.conf << 'EOF'
[LightDM]
run-directory=/run/lightdm

[Seat:*]
autologin-user=gamer
autologin-user-timeout=0
user-session=xfce
greeter-hide-users=false
EOF
    
    pct push "$CTID" /tmp/lightdm.conf /etc/lightdm/lightdm.conf
    rm /tmp/lightdm.conf
    
    pct exec "$CTID" -- usermod -aG video,audio,render,input,nopasswdlogin gamer
    
    # Fix LightDM default display manager (critical for container compatibility)
    print_step "Setting LightDM as default display manager"
    pct exec "$CTID" -- bash -c "echo '/usr/sbin/lightdm' > /etc/X11/default-display-manager"
    
    pct exec "$CTID" -- systemctl enable lightdm
}

setup_audio() {
    print_header "PHASE 5: AUDIO CONFIGURATION"
    
    print_step "Installing PulseAudio"
    pct exec "$CTID" -- apt install -y pulseaudio pulseaudio-module-jack \
        alsa-utils pavucontrol
    
    print_step "Configuring PulseAudio for network audio"
    
    # Configure PulseAudio system configuration
    cat > /tmp/system.pa << 'EOF'
#!/usr/bin/pulseaudio -nF

# Load basic modules
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore
load-module module-augment-properties
load-module module-switch-on-port-available
load-module module-udev-detect
load-module module-alsa-sink
load-module module-native-protocol-unix
load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;192.168.0.0/16 auth-anonymous=1
load-module module-zeroconf-publish
load-module module-default-device-restore
load-module module-rescue-streams
load-module module-always-sink
load-module module-intended-roles
load-module module-suspend-on-idle
load-module module-systemd-login
load-module module-position-event-sounds
EOF
    
    pct push "$CTID" /tmp/system.pa /etc/pulse/system.pa
    rm /tmp/system.pa
    
    # Configure PulseAudio client settings for network access
    cat > /tmp/client.conf << 'EOF'
# PulseAudio client configuration for game streaming
default-server = unix:/run/user/1000/pulse/native
autospawn = yes
cookie-file = /home/gamer/.config/pulse/cookie
enable-shm = yes
shm-size-bytes = 0
auto-connect-localhost = yes
EOF
    
    pct push "$CTID" /tmp/client.conf /etc/pulse/client.conf
    rm /tmp/client.conf
    
    # Disable global PulseAudio user services (will be managed by sunshine service)
    pct exec "$CTID" -- systemctl --global disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
    
    print_step "PulseAudio will be started automatically by the Sunshine service"
}

install_gaming_software() {
    print_header "PHASE 6: GAMING SOFTWARE INSTALLATION"
    
    print_step "Installing Steam"
    pct exec "$CTID" -- apt install -y libc6:i386 libegl1:i386 libgbm1:i386 \
        libgl1-mesa-dri:i386 libgl1:i386 steam-installer
    
    print_step "Installing Sunshine dependencies"
    
    # Install required dependencies first
    pct exec "$CTID" -- apt install -y libva2 libva-drm2 libva-glx2 libva-wayland2 \
        miniupnpc libminiupnpc17 vainfo intel-media-va-driver-non-free \
        mesa-va-drivers libdrm-amdgpu1 libdrm-radeon1
    
    print_step "Installing Sunshine game streaming server"
    
    # Check if we need to add back capabilities for Sunshine
    if ! grep -q "lxc.cap.keep: sys_admin" "/etc/pve/lxc/$CTID.conf"; then
        print_step "Adding sys_admin capability for Sunshine"
        pct stop "$CTID"
        echo "lxc.cap.keep: sys_admin" >> "/etc/pve/lxc/$CTID.conf"
        pct start "$CTID"
        
        # Wait for container to be ready
        local timeout=30
        local count=0
        while ! pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; do
            sleep 2
            count=$((count + 2))
            if [[ $count -gt $timeout ]]; then
                print_error "Container failed to restart with sys_admin capability"
                # Remove capability and continue without it
                pct stop "$CTID"
                sed -i '/lxc.cap.keep.*sys_admin/d' "/etc/pve/lxc/$CTID.conf"
                pct start "$CTID"
                print_warning "Continuing without sys_admin capability - some Sunshine features may be limited"
                break
            fi
        done
    fi
    
    # Install stable version v0.23.1 to avoid FFmpeg 7.1 segmentation fault bug with AMD GPUs
    print_step "Installing Sunshine v0.23.1 (stable version for AMD compatibility)"
    
    # Pre-configure dpkg to avoid interactive prompts and handle post-install errors
    pct exec "$CTID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        # Install dependencies first
        apt install -y libva2 libva-drm2 miniupnpc libminiupnpc17
    "
    
    # Download and install Sunshine with comprehensive error handling
    pct exec "$CTID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        cd /tmp
        wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb -O sunshine.deb
        
        # Extract the package to bypass problematic post-install scripts
        dpkg-deb -x sunshine.deb sunshine_extracted/
        dpkg-deb --control sunshine.deb sunshine_extracted/DEBIAN/
        
        # Install files manually
        cp -r sunshine_extracted/usr/* /usr/ 2>/dev/null || true
        cp -r sunshine_extracted/etc/* /etc/ 2>/dev/null || true
        
        # Create sunshine user manually (avoid systemd issues)
        id sunshine 2>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/sunshine sunshine 2>/dev/null || true
        
        # Set up directories
        mkdir -p /var/lib/sunshine /var/log/sunshine /etc/sunshine
        chown sunshine:sunshine /var/lib/sunshine /var/log/sunshine 2>/dev/null || true
        
        # Set capabilities manually (ignore errors in container)
        setcap cap_sys_admin+p /usr/bin/sunshine 2>/dev/null || echo 'Note: setcap failed (expected in container)'
        
        # Cleanup
        rm -rf sunshine.deb sunshine_extracted/
        
        # Verify installation
        if [[ -x /usr/bin/sunshine ]]; then
            echo 'Sunshine binary installed successfully'
        else
            echo 'ERROR: Sunshine installation failed'
            exit 1
        fi
    "
    
    # Alternative: try regular dpkg install with post-script override
    if ! pct exec "$CTID" -- test -x /usr/bin/sunshine; then
        print_step "Manual extraction failed, trying dpkg with error override..."
        pct exec "$CTID" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            cd /tmp
            
            # Download if not already there
            [[ -f sunshine.deb ]] || wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb -O sunshine.deb
            
            # Install with post-script error handling
            dpkg -i sunshine.deb 2>&1 | grep -v 'systemctl.*failed' || true
            
            # Fix any dependency issues
            apt-get install -f -y 2>/dev/null || true
            
            # Force configuration (ignore errors)
            dpkg --configure -a 2>/dev/null || true
            
            # Manual service setup since systemctl may have failed
            if [[ -f /lib/systemd/system/sunshine.service ]]; then
                systemctl daemon-reload 2>/dev/null || true
                systemctl enable sunshine 2>/dev/null || echo 'Could not enable sunshine service (will configure manually)'
            fi
            
            # Cleanup
            rm -f sunshine.deb
        "
    fi
    
    # Final verification and manual setup
    if pct exec "$CTID" -- test -x /usr/bin/sunshine; then
        print_step "✓ Sunshine binary installed successfully"
        
        print_step "Configuring Sunshine permissions and capabilities"
        pct exec "$CTID" -- bash -c "
            # Ensure sunshine user exists
            id sunshine 2>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/sunshine sunshine
            
            # Set up required directories
            mkdir -p /var/lib/sunshine /var/log/sunshine /run/sunshine
            chown sunshine:sunshine /var/lib/sunshine /var/log/sunshine /run/sunshine 2>/dev/null || true
            
            # Set binary permissions
            chown root:sunshine /usr/bin/sunshine 2>/dev/null || true
            chmod 755 /usr/bin/sunshine
            
            # Try to set capabilities (may fail in container - that's OK)
            setcap cap_sys_admin+p /usr/bin/sunshine 2>/dev/null || echo 'Note: setcap failed (normal in LXC container)'
            
            # Create manual uinput setup since post-install script may have failed
            if [[ ! -c /dev/uinput ]]; then
                # Create uinput device node manually if it doesn't exist
                mknod /dev/uinput c 10 223 2>/dev/null || echo 'Could not create uinput device node'
            fi
            
            # Set uinput permissions
            if [[ -c /dev/uinput ]]; then
                chgrp input /dev/uinput 2>/dev/null || true
                chmod 660 /dev/uinput 2>/dev/null || true
                # Add gamer to input group for uinput access
                usermod -aG input gamer 2>/dev/null || true
                echo 'uinput device configured for input access'
            else
                echo 'Warning: uinput device not available - virtual input may not work'
            fi
            
            echo 'Sunshine permissions and capabilities configured'
        "
    else
        print_error "Sunshine installation failed completely"
        print_step "Attempting alternative installation from AppImage..."
        
        # Fallback to AppImage if package installation fails
        pct exec "$CTID" -- bash -c "
            cd /tmp
            wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine.AppImage -O sunshine.AppImage 2>/dev/null || {
                echo 'AppImage download also failed. Sunshine will need manual installation.'
                exit 1
            }
            
            chmod +x sunshine.AppImage
            mkdir -p /opt/sunshine
            mv sunshine.AppImage /opt/sunshine/sunshine
            
            # Create wrapper script
            cat > /usr/bin/sunshine << 'EOF'
#!/bin/bash
exec /opt/sunshine/sunshine \"\$@\"
EOF
            chmod +x /usr/bin/sunshine
            
            echo 'Sunshine installed via AppImage'
        " || print_warning "All Sunshine installation methods failed - will need manual setup"
    fi
    
    # Verify Sunshine installation
    if pct exec "$CTID" -- which sunshine &>/dev/null; then
        print_step "Sunshine installation verified"
    else
        print_error "Sunshine installation failed. Continuing with setup..."
    fi
    
    print_step "Configuring Sunshine"
    pct exec "$CTID" -- mkdir -p /home/gamer/.config/sunshine
    pct exec "$CTID" -- chown -R gamer:gamer /home/gamer/.config
    
    cat > /tmp/sunshine.conf << 'EOF'
# Sunshine Configuration for Gaming LXC
sunshine_name = Gaming-LXC
upnp = on
min_log_level = info
file_apps = /home/gamer/.config/sunshine/apps.json

# Network settings - force IPv4 for proper Moonlight connectivity
address_family = ipv4
port = 47989

# Video settings - use VAAPI hardware encoding (stable with v0.23.1)
encoder = vaapi
adapter_name = /dev/dri/renderD128
sw_preset = medium

# Audio settings
audio_sink = pulse
EOF
    
    pct push "$CTID" /tmp/sunshine.conf /home/gamer/.config/sunshine/sunshine.conf
    rm /tmp/sunshine.conf
    
    cat > /tmp/apps.json << 'EOF'
{
  "env": {},
  "apps": [
    {
      "name": "Desktop",
      "output": "",
      "cmd": [],
      "exclude-global-prep-cmd": false,
      "auto-detach": true
    },
    {
      "name": "Steam Big Picture",
      "output": "",
      "cmd": [
        "sh", "-c", "DISPLAY=:0 steam -gamepadui"
      ],
      "exclude-global-prep-cmd": false,
      "auto-detach": true,
      "image-path": "/usr/share/pixmaps/steam.png"
    },
    {
      "name": "Steam Desktop",
      "output": "",
      "cmd": [
        "sh", "-c", "DISPLAY=:0 steam"
      ],
      "exclude-global-prep-cmd": false,
      "auto-detach": true
    }
  ]
}
EOF
    
    pct push "$CTID" /tmp/apps.json /home/gamer/.config/sunshine/apps.json
    rm /tmp/apps.json
    
    pct exec "$CTID" -- chown gamer:gamer /home/gamer/.config/sunshine/sunshine.conf
    pct exec "$CTID" -- chown gamer:gamer /home/gamer/.config/sunshine/apps.json
}

setup_services() {
    print_header "PHASE 7: SERVICE CONFIGURATION"
    
    print_step "Creating Sunshine systemd service"
    
    # Create runtime directory as root first to avoid permission issues
    pct exec "$CTID" -- bash -c "
        mkdir -p /run/user/1000 /run/sunshine
        chown gamer:gamer /run/user/1000
        chown sunshine:sunshine /run/sunshine 2>/dev/null || chown gamer:gamer /run/sunshine
        chmod 755 /run/user/1000 /run/sunshine
        
        # Create XDG runtime structure
        mkdir -p /run/user/1000/{pulse,dbus-1,systemd}
        chown -R gamer:gamer /run/user/1000/
    "
    
    cat > /tmp/sunshine.service << 'EOF'
[Unit]
Description=Sunshine Game Streaming Server
After=graphical.target network.target sound.target
Wants=graphical.target

[Service]
Type=simple
User=gamer
Group=gamer
SupplementaryGroups=video audio render input

# Environment
Environment=HOME=/home/gamer
Environment=USER=gamer
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=x11
Environment=XDG_SESSION_CLASS=user
Environment=PULSE_RUNTIME_PATH=/run/user/1000/pulse
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

# Graphics and encoding environment
Environment=DRI_PRIME=1
Environment=LIBVA_DRIVER_NAME=radeonsi
Environment=MESA_LOADER_DRIVER_OVERRIDE=radeonsi
Environment=VAAPI_DRIVER=radeonsi

# Runtime directory setup with proper permissions
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/1000/{pulse,dbus-1,systemd} || true'
ExecStartPre=/bin/bash -c 'chown -R gamer:gamer /run/user/1000/ || true'
ExecStartPre=/bin/bash -c 'chmod 755 /run/user/1000 || true'

# User directories setup
ExecStartPre=/bin/bash -c 'mkdir -p /home/gamer/.config/{sunshine,pulse} || true'
ExecStartPre=/bin/bash -c 'chown -R gamer:gamer /home/gamer/.config/ || true'

# Audio setup - start PulseAudio if not running
ExecStartPre=/bin/bash -c 'if ! pgrep -u gamer pulseaudio >/dev/null; then runuser -u gamer -- pulseaudio --start --exit-idle-time=-1 || true; fi'

# Wait for X11 to be available
ExecStartPre=/bin/bash -c 'timeout=30; count=0; while ! runuser -u gamer -- DISPLAY=:0 xset q >/dev/null 2>&1; do sleep 1; count=$((count + 1)); if [ $count -gt $timeout ]; then echo "X11 not available after ${timeout}s"; break; fi; done'

# Main command with working directory
WorkingDirectory=/home/gamer
ExecStart=/usr/bin/sunshine

# Handle service lifecycle
Restart=on-failure
RestartSec=15
KillMode=mixed
TimeoutStartSec=60
TimeoutStopSec=30

# Security (relaxed for container environment)
NoNewPrivileges=false
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
    
    pct push "$CTID" /tmp/sunshine.service /etc/systemd/system/sunshine.service
    rm /tmp/sunshine.service
    
    # Install and enable the service
    pct exec "$CTID" -- bash -c "
        systemctl daemon-reload
        systemctl enable sunshine.service
        
        # Test service configuration
        systemctl status sunshine.service --no-pager -l || echo 'Service not started yet (normal)'
        
        # Ensure the service will auto-start
        if systemctl is-enabled sunshine.service >/dev/null; then
            echo 'Sunshine service enabled successfully'
        else
            echo 'Warning: Sunshine service may not be properly enabled'
        fi
    "
    
    print_step "Creating gaming startup script"
    cat > /tmp/start-gaming.sh << 'EOF'
#!/bin/bash

# Wait for X11 to be ready
echo "Waiting for X11..."
while ! xset q &>/dev/null; do
    sleep 1
done

# Set display resolution (adjust as needed)
xrandr --output HDMI-A-1 --mode 1920x1080 --rate 60 2>/dev/null || \
xrandr --output DisplayPort-1 --mode 1920x1080 --rate 60 2>/dev/null || \
echo "Display setup completed"

# Start PulseAudio if not running
if ! pulseaudio --check; then
    echo "Starting PulseAudio..."
    pulseaudio --start
fi

# Start Steam in background
if ! pgrep -x "steam" > /dev/null; then
    echo "Starting Steam..."
    nohup steam -silent &
fi

echo "Gaming environment ready!"
EOF
    
    pct push "$CTID" /tmp/start-gaming.sh /home/gamer/start-gaming.sh
    rm /tmp/start-gaming.sh
    
    pct exec "$CTID" -- chmod +x /home/gamer/start-gaming.sh
    pct exec "$CTID" -- chown gamer:gamer /home/gamer/start-gaming.sh
    
    # Add to desktop autostart
    pct exec "$CTID" -- mkdir -p /home/gamer/.config/autostart
    cat > /tmp/gaming-setup.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Gaming Setup
Exec=/home/gamer/start-gaming.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    
    pct push "$CTID" /tmp/gaming-setup.desktop /home/gamer/.config/autostart/gaming-setup.desktop
    rm /tmp/gaming-setup.desktop
    
    pct exec "$CTID" -- chown -R gamer:gamer /home/gamer/.config/autostart
}

setup_network() {
    print_header "PHASE 8: NETWORK AND FIREWALL"
    
    print_step "Configuring container firewall"
    pct exec "$CTID" -- apt install -y ufw
    
    # Allow Sunshine ports (expanded range to include 47998-48000 for Moonlight compatibility)
    pct exec "$CTID" -- ufw allow 47984:47990/tcp
    pct exec "$CTID" -- ufw allow 47984:47990/udp
    pct exec "$CTID" -- ufw allow 47998:48000/udp
    pct exec "$CTID" -- ufw allow 48010/tcp
    
    pct exec "$CTID" -- ufw --force enable
}

test_configuration() {
    print_header "PHASE 9: TESTING CONFIGURATION"
    
    print_step "Testing GPU access"
    if pct exec "$CTID" -- su - gamer -c "ls -la /dev/dri/renderD128" 2>/dev/null; then
        print_step "✓ GPU device accessible"
    else
        print_error "✗ GPU device not accessible"
        return 1
    fi
    
    print_step "Testing VAAPI hardware encoding"
    if pct exec "$CTID" -- su - gamer -c "vainfo --display drm --device /dev/dri/renderD128" 2>/dev/null | grep -q "VAProfile"; then
        print_step "✓ VAAPI hardware encoding available"
    else
        print_warning "⚠ VAAPI encoding may not be working optimally"
    fi
    
    print_step "Testing Sunshine configuration"
    if pct exec "$CTID" -- test -f /home/gamer/.config/sunshine/sunshine.conf; then
        print_step "✓ Sunshine configuration exists"
    else
        print_error "✗ Sunshine configuration missing"
        return 1
    fi
    
    print_step "Starting services for testing"
    pct exec "$CTID" -- systemctl start sunshine.service
    sleep 5
    
    print_step "Checking Sunshine service status"
    if pct exec "$CTID" -- systemctl is-active sunshine.service | grep -q "active"; then
        print_step "✓ Sunshine service is running"
        
        # Check if ports are listening
        if pct exec "$CTID" -- netstat -tlnp 2>/dev/null | grep -q ":47989"; then
            print_step "✓ Sunshine is listening on port 47989"
        else
            print_warning "⚠ Sunshine may not be listening on expected ports"
        fi
    else
        print_error "✗ Sunshine service failed to start"
        pct exec "$CTID" -- journalctl -u sunshine.service --no-pager -n 20
        return 1
    fi
    
    print_step "Getting container IP for Moonlight connection"
    CONTAINER_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
    
    # Final verification checks
    print_step "Performing final verification checks"
    
    # Check LightDM is running
    if pct exec "$CTID" -- systemctl is-active lightdm | grep -q "active"; then
        print_step "✓ LightDM display manager is running"
    else
        print_warning "⚠ LightDM may not be running properly"
    fi
    
    # Check X server is responding
    if pct exec "$CTID" -- su - gamer -c "DISPLAY=:0 xset q" >/dev/null 2>&1; then
        print_step "✓ X server is responding on DISPLAY :0"
    else
        print_warning "⚠ X server may not be responding properly"
    fi
    
    # Check firewall configuration
    if pct exec "$CTID" -- ufw status | grep -q "47998:48000/udp"; then
        print_step "✓ Firewall configured with all required ports"
    else
        print_warning "⚠ Firewall may be missing some required ports"
    fi
    
    print_success "✅ SETUP COMPLETE!"
    echo "═══════════════════════════════════════════════════════════"
    echo "📡 MOONLIGHT CONNECTION DETAILS:"
    echo "   IP Address: $CONTAINER_IP"
    echo "   Port: 47989"
    echo "   Username: gamer"
    echo "   Password: Set during setup"
    echo ""
    echo "🎮 TO CONNECT:"
    echo "   1. Open Moonlight on your client device"
    echo "   2. Add computer manually: $CONTAINER_IP:47989"
    echo "   3. Enter the PIN when prompted"
    echo "   4. Select 'Desktop' or 'Steam Big Picture' to start"
    echo ""
    echo "🔧 SUNSHINE WEB UI:"
    echo "   https://$CONTAINER_IP:47990"
    echo "   (Accept the self-signed certificate)"
    echo ""
    echo "🚨 TROUBLESHOOTING:"
    echo "   - If Moonlight shows 'Computer is unreachable': Check firewall and network"
    echo "   - If connection fails on UDP 47999: Restart container and try again"
    echo "   - If you see black screen: Wait 30 seconds for desktop to load"
    echo "   - If you see host desktop: Check LightDM status in container"
    echo "   - Logs: pct exec $CTID -- journalctl -u sunshine -u lightdm"
    echo "═══════════════════════════════════════════════════════════"
}

finalize_setup() {
    print_header "PHASE 10: FINAL SETUP"
    
    print_step "Setting final permissions"
    pct exec "$CTID" -- chown -R gamer:gamer /home/gamer
    
    print_step "Verifying GPU permissions"
    pct exec "$CTID" -- ls -la /dev/dri/
    
    print_step "Creating performance optimization script"
    cat > /tmp/performance-tweaks.sh << 'EOF'
#!/bin/bash

# Set CPU governor to performance
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true

# Set GPU to high performance mode
echo high | sudo tee /sys/class/drm/card*/device/power_dpm_force_performance_level 2>/dev/null || true

# Disable desktop compositing for better gaming performance
export DISPLAY=:0
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true

# Optimize process priorities
sudo renice -10 -p $(pgrep sunshine) 2>/dev/null || true
sudo renice -5 -p $(pgrep steam) 2>/dev/null || true

echo "Performance optimizations applied!"
EOF
    
    pct push "$CTID" /tmp/performance-tweaks.sh /home/gamer/performance-tweaks.sh
    rm /tmp/performance-tweaks.sh
    
    pct exec "$CTID" -- chmod +x /home/gamer/performance-tweaks.sh
    
    print_step "Restarting services"
    
    # Check and fix LightDM configuration before starting
    print_step "Verifying LightDM configuration"
    pct exec "$CTID" -- bash -c "
        # Ensure required directories exist with proper permissions
        mkdir -p /tmp/.X11-unix /var/lib/lightdm /var/log/lightdm /var/cache/lightdm /run/lightdm
        chmod 1777 /tmp/.X11-unix
        
        # Create lightdm user if it doesn't exist
        id lightdm 2>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/lightdm lightdm
        
        chown lightdm:lightdm /var/lib/lightdm /var/log/lightdm /var/cache/lightdm /run/lightdm
        
        # Verify gamer user exists and has proper groups
        if ! id gamer >/dev/null 2>&1; then
            echo 'ERROR: User gamer does not exist'
            exit 1
        fi
        usermod -aG video,audio,render,input,nopasswdlogin gamer
        
        # Ensure session directories exist
        mkdir -p /usr/share/xsessions /etc/lightdm
        
        # Create basic XFCE session if missing
        if [[ ! -f /usr/share/xsessions/xfce.desktop ]]; then
            cat > /usr/share/xsessions/xfce.desktop << 'XFCE_EOF'
[Desktop Entry]
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=xfce4-logo
Type=Application
DesktopNames=XFCE
XFCE_EOF
            echo 'Created XFCE session file'
        fi
        
        # Fix X11 socket permissions
        chmod 755 /tmp/.X11-unix 2>/dev/null || true
        
        echo 'LightDM configuration verified'
    "
    
    # Create enhanced LightDM configuration for container environment
    cat > /tmp/lightdm.conf << 'EOF'
[LightDM]
run-directory=/run/lightdm
data-directory=/var/lib/lightdm-data
log-directory=/var/log/lightdm
cache-directory=/var/cache/lightdm

[Seat:*]
# Auto-login configuration
autologin-user=gamer
autologin-user-timeout=0
autologin-session=xfce

# Session and greeter configuration
user-session=xfce
greeter-session=lightdm-gtk-greeter
greeter-hide-users=false
greeter-allow-guest=false
greeter-show-manual-login=true

# X server configuration
xserver-command=X
xserver-layout=
xserver-config=
xserver-allow-tcp=false

# Display manager configuration
display-setup-script=
display-stopped-script=
greeter-setup-script=
session-setup-script=
session-cleanup-script=

# Seat configuration
type=local
pam-service=lightdm
pam-autologin-service=lightdm-autologin
pam-greeter-service=lightdm-greeter
xdmcp-manager=
xdmcp-port=177
xdmcp-listen-address=
xdmcp-key=
unity-compositor=off

# Additional X11 options for container compatibility
xserver-options=-ac -nolisten tcp
EOF
    
    pct push "$CTID" /tmp/lightdm.conf /etc/lightdm/lightdm.conf
    rm /tmp/lightdm.conf
    
    # Create enhanced GTK greeter configuration
    cat > /tmp/lightdm-gtk-greeter.conf << 'EOF'
[greeter]
background=#2C3E50
theme-name=Adwaita
icon-theme-name=Adwaita
font-name=Sans 11
xft-antialias=true
xft-dpi=96
xft-hintstyle=slight
xft-rgba=rgb
show-indicators=~host;~spacer;~clock;~spacer;~session;~a11y;~power
show-clock=true
clock-format=%a, %b %d %Y %l:%M %p
user-background=true
hide-user-image=false
default-user-image=#avatar-default
EOF
    
    pct push "$CTID" /tmp/lightdm-gtk-greeter.conf /etc/lightdm/lightdm-gtk-greeter.conf
    rm /tmp/lightdm-gtk-greeter.conf
    
    # Try to start LightDM with comprehensive error handling
    print_step "Starting LightDM display manager"
    if pct exec "$CTID" -- systemctl start lightdm; then
        print_step "LightDM started successfully"
        
        # Wait a moment for initialization
        sleep 8
        
        # Check if X11 is actually running
        if pct exec "$CTID" -- pgrep -x Xorg >/dev/null; then
            print_step "✓ X11 server is running"
        else
            print_warning "⚠ X11 server may not be running properly"
        fi
        
        # Check if the display is accessible
        if pct exec "$CTID" -- su - gamer -c "DISPLAY=:0 xset q" >/dev/null 2>&1; then
            print_step "✓ X11 display is accessible"
        else
            print_warning "⚠ X11 display not accessible to gamer user"
            
            # Try to fix display permissions
            pct exec "$CTID" -- bash -c "
                # Add gamer to required groups
                usermod -aG tty,video,audio,render,input gamer
                
                # Fix X11 permissions
                chmod 755 /tmp/.X11-unix/X0 2>/dev/null || true
                chown root:root /tmp/.X11-unix/X0 2>/dev/null || true
                
                echo 'Attempted to fix X11 permissions'
            "
        fi
        
    else
        print_warning "LightDM failed to start normally. Attempting troubleshooting..."
        
        # Get detailed status and logs
        print_step "LightDM service status:"
        pct exec "$CTID" -- systemctl status lightdm --no-pager -l || true
        
        print_step "LightDM logs (last 20 lines):"
        pct exec "$CTID" -- journalctl -u lightdm --no-pager -n 20 || true
        
        print_step "X11 logs:"
        pct exec "$CTID" -- find /var/log -name "Xorg*.log" -exec tail -n 10 {} \; 2>/dev/null || echo "No X11 logs found"
        
        # Try alternative startup methods
        print_warning "Attempting alternative X11 startup methods..."
        
        # Method 1: Direct X server start
        print_step "Trying direct X server startup..."
        pct exec "$CTID" -- bash -c "
            # Kill any existing X processes
            pkill -f Xorg 2>/dev/null || true
            pkill -f lightdm 2>/dev/null || true
            sleep 2
            
            # Create minimal xorg.conf if GPU passthrough is working
            if [[ -e /dev/dri/renderD128 ]]; then
                cat > /etc/X11/xorg.conf << 'XORG_EOF'
Section \"Device\"
    Identifier \"AMD GPU\"
    Driver \"amdgpu\"
    BusID \"$X11_BUS_ID\"
    Option \"DRI\" \"3\"
EndSection

Section \"Screen\"
    Identifier \"Screen0\"
    Device \"AMD GPU\"
    DefaultDepth 24
EndSection
XORG_EOF
                echo 'Created minimal xorg.conf for GPU'
            fi
            
            # Try to start X manually
            sudo -u gamer startx -- :0 -auth /tmp/serverauth.gamer &
            sleep 5
            
            if pgrep -x Xorg >/dev/null; then
                echo 'X server started manually'
                # Now try to start LightDM
                systemctl start lightdm || echo 'LightDM still failed'
            else
                echo 'Manual X server start also failed'
            fi
        " || true
        
        # Method 2: Container-specific X11 setup
        if ! pct exec "$CTID" -- pgrep -x Xorg >/dev/null; then
            print_step "Trying container-optimized X11 setup..."
            pct exec "$CTID" -- bash -c "
                # Install additional packages that might be needed
                apt install -y xorg-video-abi-23 xserver-xorg-core xserver-xorg-legacy
                
                # Create container-optimized X configuration
                cat > /etc/X11/xorg.conf.d/99-container.conf << 'CONTAINER_EOF'
Section \"ServerFlags\"
    Option \"AutoAddDevices\" \"false\"
    Option \"AutoEnableDevices\" \"false\"
    Option \"DontVTSwitch\" \"true\"
    Option \"DontZap\" \"true\"
EndSection

Section \"InputClass\"
    Identifier \"Keyboard Defaults\"
    MatchIsKeyboard \"yes\"
    Driver \"libinput\"
EndSection
CONTAINER_EOF
                
                # Try LightDM again
                systemctl daemon-reload
                systemctl restart lightdm || echo 'Container-optimized setup also failed'
            " || true
        fi
        
        # Final fallback: headless mode with manual X
        if ! pct exec "$CTID" -- pgrep -x Xorg >/dev/null; then
            print_warning "All X11 startup methods failed. Setting up headless mode."
            print_step "Creating headless X11 startup script for manual use"
            
            cat > /tmp/start-x11.sh << 'EOF'
#!/bin/bash
# Manual X11 startup script for troubleshooting

echo "Starting X11 server manually..."

# Kill existing processes
sudo pkill -f Xorg 2>/dev/null || true
sudo pkill -f lightdm 2>/dev/null || true
sleep 2

# Start X server
sudo -u gamer X :0 -ac -nolisten tcp -auth /tmp/serverauth.gamer &
sleep 3

# Start window manager
sudo -u gamer DISPLAY=:0 startxfce4 &

echo "Manual X11 startup completed. Check with: DISPLAY=:0 xrandr"
EOF
            
            pct push "$CTID" /tmp/start-x11.sh /usr/local/bin/start-x11.sh
            rm /tmp/start-x11.sh
            pct exec "$CTID" -- chmod +x /usr/local/bin/start-x11.sh
            
            print_warning "X11 failed to start automatically. Use '/usr/local/bin/start-x11.sh' to start manually."
        fi
    fi
    
    # Start Sunshine regardless of LightDM status
    print_step "Starting Sunshine service"
    if pct exec "$CTID" -- systemctl start sunshine; then
        print_step "Sunshine started successfully"
    else
        print_warning "Sunshine failed to start, checking status..."
        pct exec "$CTID" -- systemctl status sunshine --no-pager -l
        pct exec "$CTID" -- journalctl -u sunshine --no-pager -n 10
    fi
    
    # Get container IP
    CONTAINER_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}' 2>/dev/null || echo "IP detection failed")
    
    # Final service status check
    print_step "Final service status check"
    echo "LightDM status:"
    pct exec "$CTID" -- systemctl is-active lightdm || echo "  ❌ LightDM not running"
    echo "Sunshine status:"
    pct exec "$CTID" -- systemctl is-active sunshine || echo "  ❌ Sunshine not running"
    
    print_header "SETUP COMPLETE!"
    
    echo -e "${GREEN}Gaming LXC container setup completed successfully!${NC}\n"
    echo -e "${BLUE}Container Details:${NC}"
    echo "Container ID: $CTID"
    echo "Container IP: $CONTAINER_IP"
    echo "Gamer user created with configured password"
    echo
    echo -e "${BLUE}Service Status Check:${NC}"
    local lightdm_status=$(pct exec "$CTID" -- systemctl is-active lightdm 2>/dev/null || echo "failed")
    local sunshine_status=$(pct exec "$CTID" -- systemctl is-active sunshine 2>/dev/null || echo "failed")
    local x11_running=$(pct exec "$CTID" -- pgrep -x Xorg >/dev/null 2>&1 && echo "running" || echo "not running")
    
    echo "LightDM (Display Manager): $lightdm_status"
    echo "Sunshine (Game Streaming): $sunshine_status"
    echo "X11 Server: $x11_running"
    echo
    
    if [[ "$lightdm_status" == "active" && "$sunshine_status" == "active" && "$x11_running" == "running" ]]; then
        echo -e "${GREEN}✅ All services are running properly!${NC}"
    else
        echo -e "${YELLOW}⚠️  Some services need attention - see troubleshooting section below${NC}"
    fi
    echo
    
    echo -e "${BLUE}Connection Information:${NC}"
    echo "Moonlight Gaming Client:"
    echo "  • IP Address: $CONTAINER_IP"
    echo "  • Port: 47989"
    echo "  • Username: gamer"
    echo "  • Password: [set during setup]"
    echo
    echo "Sunshine Web Interface:"
    echo "  • URL: https://$CONTAINER_IP:47990"
    echo "  • Accept the self-signed certificate"
    echo "  • Complete initial setup (create username/password)"
    echo
    
    echo -e "${BLUE}Quick Start Guide:${NC}"
    echo "1. Install Moonlight client on your device"
    echo "2. Add computer manually: $CONTAINER_IP:47989"
    echo "3. Enter the PIN shown in Sunshine web interface"
    echo "4. Select 'Desktop' or 'Steam Big Picture' to start gaming"
    echo
    
    echo -e "${BLUE}Useful Management Commands:${NC}"
    echo "Container Management:"
    echo "  • Check status: pct status $CTID"
    echo "  • Start: pct start $CTID"
    echo "  • Stop: pct stop $CTID"
    echo "  • Enter container: pct enter $CTID"
    echo
    echo "Service Management (run inside container):"
    echo "  • Restart display: systemctl restart lightdm"
    echo "  • Restart Sunshine: systemctl restart sunshine"
    echo "  • Check logs: journalctl -u sunshine -f"
    echo "  • Manual X11 start: /usr/local/bin/start-x11.sh"
    echo
    echo "Diagnostics:"
    echo "  • GPU access: pct exec $CTID -- ls -la /dev/dri/"
    echo "  • Display status: pct exec $CTID -- DISPLAY=:0 xrandr"
    echo "  • VAAPI test: pct exec $CTID -- vainfo --display drm --device /dev/dri/renderD128"
    echo "  • Network test: pct exec $CTID -- netstat -tlnp | grep sunshine"
    echo
    
    # Show troubleshooting info based on service status
    if [[ "$lightdm_status" != "active" ]]; then
        echo -e "${YELLOW}🔧 LightDM (Display Manager) Troubleshooting:${NC}"
        echo "LightDM is not running properly. This affects desktop access."
        echo
        echo "Common Solutions:"
        echo "1. Check GPU passthrough:"
        echo "   pct exec $CTID -- ls -la /dev/dri/"
        echo "   → Should show renderD128 and card0 devices"
        echo
        echo "2. Verify X11 configuration:"
        echo "   pct exec $CTID -- cat /etc/X11/xorg.conf.d/20-amd.conf"
        echo "   → Should contain correct BusID: $X11_BUS_ID"
        echo
        echo "3. Check LightDM logs:"
        echo "   pct exec $CTID -- journalctl -u lightdm -n 50"
        echo "   → Look for specific error messages"
        echo
        echo "4. Manual X11 testing:"
        echo "   pct exec $CTID -- /usr/local/bin/start-x11.sh"
        echo "   → Attempts manual X server startup"
        echo
        echo "5. Check user permissions:"
        echo "   pct exec $CTID -- groups gamer"
        echo "   → Should include: video, audio, render, input"
        echo
        echo "6. GPU driver verification:"
        echo "   pct exec $CTID -- lsmod | grep amdgpu"
        echo "   → AMD GPU driver should be loaded"
        echo
    fi
    
    if [[ "$sunshine_status" != "active" ]]; then
        echo -e "${YELLOW}🔧 Sunshine (Game Streaming) Troubleshooting:${NC}"
        echo "Sunshine is not running properly. This affects game streaming."
        echo
        echo "Common Solutions:"
        echo "1. Check Sunshine installation:"
        echo "   pct exec $CTID -- which sunshine && sunshine --version"
        echo "   → Should show installed version"
        echo
        echo "2. Verify configuration:"
        echo "   pct exec $CTID -- cat /home/gamer/.config/sunshine/sunshine.conf"
        echo "   → Check adapter_name and encoder settings"
        echo
        echo "3. Check service logs:"
        echo "   pct exec $CTID -- journalctl -u sunshine -n 50"
        echo "   → Look for startup errors"
        echo
        echo "4. Test VAAPI encoding:"
        echo "   pct exec $CTID -- su - gamer -c 'DISPLAY=:0 vainfo'"
        echo "   → Should show available video acceleration profiles"
        echo
        echo "5. Manual Sunshine test:"
        echo "   pct exec $CTID -- su - gamer -c 'DISPLAY=:0 sunshine'"
        echo "   → Test manual startup for error messages"
        echo
        echo "6. Check runtime environment:"
        echo "   pct exec $CTID -- ls -la /run/user/1000/"
        echo "   → Should show user runtime directories"
        echo
        echo "7. Audio system check:"
        echo "   pct exec $CTID -- su - gamer -c 'pulseaudio --check || pulseaudio --start'"
        echo "   → Ensure PulseAudio is running"
        echo
    fi
    
    if [[ "$x11_running" != "running" ]]; then
        echo -e "${YELLOW}🔧 X11 Server Troubleshooting:${NC}"
        echo "X11 server is not running. This is required for desktop and gaming."
        echo
        echo "Common Solutions:"
        echo "1. Check X11 logs:"
        echo "   pct exec $CTID -- find /var/log -name 'Xorg*.log' -exec tail -20 {} \;"
        echo "   → Look for GPU-related errors"
        echo
        echo "2. Verify GPU devices:"
        echo "   pct exec $CTID -- ls -la /dev/dri/*"
        echo "   → Ensure devices exist and have proper permissions"
        echo
        echo "3. Test direct X11 startup:"
        echo "   pct exec $CTID -- sudo -u gamer X :0 -ac &"
        echo "   → Try starting X server directly"
        echo
        echo "4. Check container configuration:"
        echo "   cat /etc/pve/lxc/$CTID.conf | grep -E '(dri|cgroup|mount)'"
        echo "   → Verify GPU passthrough configuration"
        echo
        echo "5. Container capabilities:"
        echo "   cat /etc/pve/lxc/$CTID.conf | grep cap.keep"
        echo "   → Should include sys_admin if needed"
        echo
        echo "6. Restart display manager:"
        echo "   pct exec $CTID -- systemctl restart lightdm"
        echo "   → Force LightDM restart"
        echo
    fi
    
    echo -e "${BLUE}Advanced Troubleshooting:${NC}"
    echo "Network Issues:"
    echo "  • Firewall check: pct exec $CTID -- ufw status"
    echo "  • Port listening: pct exec $CTID -- netstat -tlnp | grep -E '(47989|47990)'"
    echo "  • Network config: pct exec $CTID -- ip addr show"
    echo
    echo "GPU Performance Issues:"
    echo "  • GPU utilization: pct exec $CTID -- radeontop"
    echo "  • Memory usage: pct exec $CTID -- free -h"
    echo "  • Temperature: pct exec $CTID -- sensors 2>/dev/null || echo 'sensors not available'"
    echo
    echo "Container Performance:"
    echo "  • CPU usage: pct exec $CTID -- htop"
    echo "  • Process list: pct exec $CTID -- ps aux | grep -E '(sunshine|lightdm|Xorg)'"
    echo "  • Resource limits: pct config $CTID | grep -E '(memory|cores)'"
    echo
    
    # Check if reboot is needed
    current_cmdline=$(cat /proc/cmdline)
    if grep -q "amd_iommu=on" /etc/default/grub && [[ "$current_cmdline" != *"amd_iommu=on"* ]]; then
        echo -e "${RED}⚠️  IMPORTANT: REBOOT REQUIRED${NC}"
        echo "The Proxmox host needs to be rebooted to enable AMD IOMMU support."
        echo "After reboot, the GPU passthrough will work properly."
        echo "Command: reboot"
        echo
    fi
    
    echo -e "${BLUE}Support Resources:${NC}"
    echo "Setup log: $LOG_FILE"
    echo "Container config: /etc/pve/lxc/$CTID.conf"
    echo "Sunshine docs: https://docs.lizardbyte.dev/projects/sunshine/"
    echo "Moonlight docs: https://moonlight-stream.org/"
    echo
    echo -e "${GREEN}Setup completed! Happy gaming! 🎮${NC}"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --ctid ID           Container ID (e.g., 200)"
    echo "  --gpu-bus-id ID     GPU bus ID (e.g., 03:00.0)"
    echo "  --memory MB         Container memory in MB (default: 8192)"
    echo "  --cores N           Container CPU cores (default: 4)"
    echo "  --storage GB        Container storage in GB (default: 32)"
    echo "  --help              Show this help message"
    echo
    echo "If options are not provided, the script will prompt for them interactively."
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ctid)
                if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    print_error "Invalid CTID: '$2' - must be a positive integer"
                    exit 1
                fi
                CTID="$2"
                shift 2
                ;;
            --gpu-bus-id)
                if [[ -z "$2" ]]; then
                    print_error "GPU bus ID cannot be empty"
                    exit 1
                fi
                GPU_BUS_ID="$2"
                shift 2
                ;;
            --memory)
                if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1024 ]]; then
                    print_error "Invalid memory: '$2' - must be a positive integer >= 1024"
                    exit 1
                fi
                CONTAINER_MEMORY="$2"
                shift 2
                ;;
            --cores)
                if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]] || [[ "$2" -gt 32 ]]; then
                    print_error "Invalid cores: '$2' - must be a positive integer between 1 and 32"
                    exit 1
                fi
                CONTAINER_CORES="$2"
                shift 2
                ;;
            --storage)
                if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 8 ]]; then
                    print_error "Invalid storage: '$2' - must be a positive integer >= 8"
                    exit 1
                fi
                CONTAINER_STORAGE="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

main() {
    print_header "GAMING LXC SETUP SCRIPT"
    
    check_root
    check_proxmox
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # If not all required parameters provided, gather interactively
    if [[ -z "$CTID" || -z "$GPU_BUS_ID" ]]; then
        gather_configuration
    else
        # Validate CLI parameters
        if pct status "$CTID" &>/dev/null; then
            print_error "Container $CTID already exists. Choose a different ID."
            exit 1
        fi
        
        # Convert bus ID format if provided via CLI
        IFS=':.' read -r bus dev func <<< "$GPU_BUS_ID"
        X11_BUS_ID="PCI:$((10#$bus)):$((10#$dev)):$((10#$func))"
        
        # Get password for gamer user
        while [[ -z "$GAMER_PASSWORD" ]]; do
            read -s -p "Enter password for 'gamer' user: " GAMER_PASSWORD
            echo
            if [[ ${#GAMER_PASSWORD} -lt 4 ]]; then
                print_warning "Password should be at least 4 characters"
                GAMER_PASSWORD=""
            fi
        done
        
        # Show configuration when using CLI params
        echo -e "\n${BLUE}Configuration (from CLI arguments):${NC}"
        echo "Container ID: $CTID"
        echo "GPU Bus ID: $GPU_BUS_ID -> $X11_BUS_ID"
        echo "Memory: ${CONTAINER_MEMORY}MB"
        echo "Cores: $CONTAINER_CORES"
        echo "Storage: ${CONTAINER_STORAGE}GB"
        echo
    fi
    
    echo -e "\n${YELLOW}Starting automated setup...${NC}\n"
    
    setup_proxmox_host
    create_lxc_container
    setup_container_system
    setup_desktop_environment
    setup_audio
    install_gaming_software
    setup_services
    setup_network
    finalize_setup
    test_configuration
}

# Run main function with all arguments
main "$@"
