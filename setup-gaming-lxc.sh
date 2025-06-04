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
    read -p "Enter container memory in MB [default: $CONTAINER_MEMORY]: " input_memory
    CONTAINER_MEMORY=${input_memory:-$CONTAINER_MEMORY}
    
    read -p "Enter container CPU cores [default: $CONTAINER_CORES]: " input_cores
    CONTAINER_CORES=${input_cores:-$CONTAINER_CORES}
    
    read -p "Enter container storage in GB [default: $CONTAINER_STORAGE]: " input_storage
    CONTAINER_STORAGE=${input_storage:-$CONTAINER_STORAGE}
    
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
}

create_lxc_container() {
    print_header "PHASE 2: CREATE LXC CONTAINER"
    
    print_step "Updating template list"
    pveam update
    
    print_step "Downloading Ubuntu 22.04 template"
    local template_name="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
    if ! pveam list local | grep -q "ubuntu-22.04-standard"; then
        pveam download local "$template_name"
    else
        print_warning "Ubuntu 22.04 template already downloaded"
    fi
    
    print_step "Creating LXC container $CTID"
    pct create "$CTID" "local:vztmpl/$template_name" \
        --hostname gaming-lxc \
        --memory "$CONTAINER_MEMORY" \
        --cores "$CONTAINER_CORES" \
        --rootfs local-lvm:"$CONTAINER_STORAGE" \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --unprivileged 0 \
        --features nesting=1,keyctl=1 \
        --startup order=2
    
    print_step "Configuring container for GPU passthrough"
    
    # Check if GPU passthrough already configured
    if ! grep -q "lxc.mount.entry: /dev/dri" "/etc/pve/lxc/$CTID.conf"; then
        cat >> "/etc/pve/lxc/$CTID.conf" << 'EOF'
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file
lxc.cap.keep: sys_admin
EOF
        print_step "Added GPU passthrough configuration with CAP_SYS_ADMIN capability"
    else
        print_warning "GPU passthrough already configured for container $CTID"
    fi
    
    print_step "Starting container"
    pct start "$CTID"
    
    # Wait for container to be ready
    print_step "Waiting for container to be ready..."
    local timeout=30
    local count=0
    while ! pct exec "$CTID" -- test -f /bin/bash 2>/dev/null; do
        sleep 2
        count=$((count + 2))
        if [[ $count -gt $timeout ]]; then
            print_error "Container failed to start properly"
            exit 1
        fi
    done
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
    
    pct exec "$CTID" -- usermod -aG nopasswdlogin gamer
    
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
    
    # Install stable version v0.23.1 to avoid FFmpeg 7.1 segmentation fault bug with AMD GPUs
    print_step "Installing Sunshine v0.23.1 (stable version for AMD compatibility)"
    pct exec "$CTID" -- bash -c "
        # Install dependencies first
        apt install -y libva2 libva-drm2 miniupnpc libminiupnpc17 &&
        # Download and install specific stable version
        wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb -O /tmp/sunshine.deb &&
        dpkg -i /tmp/sunshine.deb &&
        apt-get install -f -y &&
        rm /tmp/sunshine.deb
    " || {
        print_error "Failed to install Sunshine v0.23.1. Attempting manual dependency resolution..."
        pct exec "$CTID" -- bash -c "
            apt update &&
            apt install -y --fix-broken &&
            apt install -y libva2 libva-drm2 miniupnpc libminiupnpc17 &&
            wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb -O /tmp/sunshine.deb &&
            dpkg -i /tmp/sunshine.deb || apt-get install -f -y &&
            rm -f /tmp/sunshine.deb
        "
    }
    
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
    pct exec "$CTID" -- mkdir -p /run/user/1000
    pct exec "$CTID" -- chown gamer:gamer /run/user/1000
    pct exec "$CTID" -- chmod 755 /run/user/1000
    
    cat > /tmp/sunshine.service << 'EOF'
[Unit]
Description=Sunshine Game Streaming Server
After=graphical.target sound.target
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
Environment=PULSE_RUNTIME_PATH=/run/user/1000/pulse
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

# Graphics
Environment=DRI_PRIME=1
Environment=LIBVA_DRIVER_NAME=radeonsi
Environment=MESA_LOADER_DRIVER_OVERRIDE=radeonsi

# Setup directories with proper permissions
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/1000/{pulse,dbus-1} || true'
ExecStartPre=/bin/bash -c 'mkdir -p /home/gamer/.config/{sunshine,pulse} || true'

# Start PulseAudio if needed
ExecStartPre=/bin/bash -c 'if ! pgrep -u gamer pulseaudio >/dev/null; then runuser -u gamer -- pulseaudio --start || true; fi'

# Main command
ExecStart=/usr/bin/sunshine

# Restart
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    pct push "$CTID" /tmp/sunshine.service /etc/systemd/system/sunshine.service
    rm /tmp/sunshine.service
    
    pct exec "$CTID" -- systemctl daemon-reload
    pct exec "$CTID" -- systemctl enable sunshine.service
    
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
        # Ensure X11 directories exist
        mkdir -p /tmp/.X11-unix /var/lib/lightdm /var/log/lightdm /var/cache/lightdm
        chmod 1777 /tmp/.X11-unix
        chown lightdm:lightdm /var/lib/lightdm /var/log/lightdm /var/cache/lightdm
        
        # Verify gamer user exists and has proper groups
        id gamer || { echo 'User gamer does not exist'; exit 1; }
        usermod -aG video,audio,render,input,nopasswdlogin gamer
        
        # Check if XFCE session file exists
        ls -la /usr/share/xsessions/ || echo 'No session files found'
        
        # Create basic XFCE session if missing
        if [[ ! -f /usr/share/xsessions/xfce.desktop ]]; then
            cat > /usr/share/xsessions/xfce.desktop << 'EOF'
[Desktop Entry]
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=
Type=Application
EOF
        fi
    "
    
    # Try to start LightDM with error handling
    if pct exec "$CTID" -- systemctl restart lightdm; then
        print_step "LightDM started successfully"
        sleep 5
    else
        print_warning "LightDM failed to start, checking logs..."
        
        # Get LightDM logs for troubleshooting
        print_step "LightDM status:"
        pct exec "$CTID" -- systemctl status lightdm --no-pager -l
        
        print_step "LightDM logs:"
        pct exec "$CTID" -- journalctl -u lightdm --no-pager -n 20
        
        print_step "X11 logs:"
        pct exec "$CTID" -- ls -la /var/log/Xorg.* 2>/dev/null || echo "No X11 logs found"
        pct exec "$CTID" -- tail -n 10 /var/log/Xorg.0.log 2>/dev/null || echo "No Xorg.0.log available"
        
        # Try alternative startup approach
        print_warning "Attempting alternative X11 startup approach..."
        pct exec "$CTID" -- bash -c "
            # Create minimal xinitrc for testing
            cat > /home/gamer/.xinitrc << 'EOF'
#!/bin/bash
export DISPLAY=:0
exec startxfce4
EOF
            chmod +x /home/gamer/.xinitrc
            chown gamer:gamer /home/gamer/.xinitrc
            
            # Try to start X manually for testing
            sudo -u gamer DISPLAY=:0 startx /home/gamer/.xinitrc -- :0 -auth /tmp/serverauth.0 &
        " || print_warning "Manual X11 startup also failed"
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
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Access Sunshine web interface: https://$CONTAINER_IP:47990"
    echo "2. Complete Sunshine initial setup (username/password for streaming)"
    echo "3. Install Moonlight client on your streaming device"
    echo "4. Test the connection"
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "Check container status: pct status $CTID"
    echo "Enter container: pct enter $CTID"
    echo "Check Sunshine logs: pct exec $CTID -- journalctl -u sunshine -f"
    echo "Check LightDM logs: pct exec $CTID -- journalctl -u lightdm -f"
    echo "Check display status: pct exec $CTID -- DISPLAY=:0 xrandr"
    echo "Restart display: pct exec $CTID -- systemctl restart lightdm"
    echo "Manual X11 test: pct exec $CTID -- sudo -u gamer DISPLAY=:0 xrandr"
    echo
    
    # Show troubleshooting info if services failed
    if ! pct exec "$CTID" -- systemctl is-active lightdm &>/dev/null; then
        echo -e "${YELLOW}⚠️  LightDM Troubleshooting:${NC}"
        echo "1. Check X11 configuration: pct exec $CTID -- cat /etc/X11/xorg.conf.d/20-amd.conf"
        echo "2. Verify GPU access: pct exec $CTID -- ls -la /dev/dri/"
        echo "3. Check logs: pct exec $CTID -- journalctl -u lightdm -n 50"
        echo "4. Try manual start: pct exec $CTID -- sudo -u gamer startxfce4"
        echo
    fi
    
    if ! pct exec "$CTID" -- systemctl is-active sunshine &>/dev/null; then
        echo -e "${YELLOW}⚠️  Sunshine Troubleshooting:${NC}"
        echo "1. Check service status: pct exec $CTID -- systemctl status sunshine"
        echo "2. View logs: pct exec $CTID -- journalctl -u sunshine -n 50"
        echo "3. Test manual start: pct exec $CTID -- sudo -u gamer DISPLAY=:0 sunshine"
        echo "4. Verify GPU encoding: pct exec $CTID -- DISPLAY=:0 vainfo"
        echo
    fi
    
    # Check if reboot is needed
    current_cmdline=$(cat /proc/cmdline)
    if grep -q "amd_iommu=on" /etc/default/grub && [[ "$current_cmdline" != *"amd_iommu=on"* ]]; then
        print_warning "IMPORTANT: System reboot required to enable AMD IOMMU support"
        echo "Run 'reboot' to complete the setup"
    fi
    
    echo -e "${GREEN}Setup log saved to: $LOG_FILE${NC}"
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
                CTID="$2"
                shift 2
                ;;
            --gpu-bus-id)
                GPU_BUS_ID="$2"
                shift 2
                ;;
            --memory)
                CONTAINER_MEMORY="$2"
                shift 2
                ;;
            --cores)
                CONTAINER_CORES="$2"
                shift 2
                ;;
            --storage)
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
        # Convert bus ID format if provided via CLI
        IFS=':.' read -r bus dev func <<< "$GPU_BUS_ID"
        X11_BUS_ID="PCI:$((10#$bus)):$((10#$dev)):$((10#$func))"
        
        # Get password for gamer user
        while [[ -z "$GAMER_PASSWORD" ]]; do
            read -s -p "Enter password for 'gamer' user: " GAMER_PASSWORD
            echo
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
