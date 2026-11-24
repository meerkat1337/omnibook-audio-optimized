#!/usr/bin/env bash
#
# omnibook-audio-fix — Optimized multi-distro installer for HP OmniBook X Flip 14 (8EA1)
#
# Requirements:
# - Kernel >= 7.3.x
# - Supported distros: Fedora, CachyOS (Arch), Ubuntu
#
set -euo pipefail

EXPECTED_BOARD="8EA1"
FW_DIR="/usr/lib/firmware"
TAS_SUBDIR="ti/audio/tas2783"

# --- Helpers ---
log()  { printf '  %s\\n' "$*"; }
ok()   { printf '\\033[32m✓\\033[0m %s\\n' "$*"; }
warn() { printf '\\033[33m!\\033[0m %s\\n' "$*" >&2; }
die()  { printf '\\033[31m✗\\033[0m %s\\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"

# --- 1. Distro Detection ---
log "Detecting distribution..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    die "Could not detect distribution (/etc/os-release missing)."
fi
log "Detected: $DISTRO"

# --- 2. Kernel Management (Target: >= 7.3) ---
log "Checking kernel version..."
current_kver=$(uname -r | cut -d'-' -f1)
major=$(echo $current_kver | cut -d'.' -f1)
minor=$(echo $current_kver | cut -d'.' -f2)

NEEDS_KERNEL=false
if [ "$major" -lt 7 ]; then
    NEEDS_KERNEL=true
elif [ "$major" -eq 7 ] && [ "$minor" -lt 3 ]; then
    NEEDS_KERNEL=true
fi

if [ "$NEEDS_KERNEL" = true ]; then
    warn "Current kernel ($current_kver) is older than 7.3. Attempting installation..."
    
    case "$DISTRO" in
        fedora)
            log "Installing latest kernel for Fedora..."
            dnf update kernel -y
            ;;
        cachyos|arch)
            log "Installing mainline kernel for CachyOS/Arch..."
            pacman -Sy --noconfirm linux-mainline linux-mainline-headers
            ;;
        ubuntu|debian)
            warn "Ubuntu might require a custom PPA or build for Kernel 7.3+."
            warn "Attempting standard update, but manual build may be required as per repo docs."
            apt update && apt upgrade -y
            ;;
        *)
            die "Unsupported distribution for automatic kernel management: $DISTRO"
            ;;
    esac

    log "Updating GRUB configuration..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        if [ -f /boot/grub2/grub.cfg ]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        elif [ -f /boot/efi/EFI/fedora/grub.cfg ]; then
            grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
        else
            grub2-mkconfig -o /boot/grub/grub.cfg || true
        fi
    else
        warn "Could not find grub-mkconfig. Please update GRUB manually."
    fi
    
    ok "Kernel update logic completed. REBOOT IS HIGHLY RECOMMENDED before proceeding with audio fixes."
    read -p "Do you want to continue anyway? (y/N): " cont
    if [[ ! $cont =~ ^[Yy]$ ]]; then
        log "Exiting. Please reboot and run this script again."
        exit 0
    fi
fi

# --- 3. Hardware Validation ---
board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)
if [[ "$board" != "$EXPECTED_BOARD" ]]; then
  warn "DMI board is '$board', not '$EXPECTED_BOARD'. Proceeding with caution."
fi

# --- 4. TAS2783 Firmware Symlinks ---
log ""
log "[1/2] TAS2783 firmware symlinks"
made=0
shopt -s nullglob
for blob in "$FW_DIR/$TAS_SUBDIR/${board}"-*-*-0x*.bin.zst; do
  base=$(basename "$blob")
  short=$(sed -E 's/^([0-9A-Fa-f]+-[0-9]+)-[0-9]+-(0x[0-9A-Fa-f]+\\.bin\\.zst)$/\\1-\\2/' <<<"$base")
  [[ "$short" != "$base" ]] || continue
  link="$FW_DIR/$short"
  target="$TAS_SUBDIR/$base"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    log "already linked: $short"
  else
    ln -sfn "$target" "$link"
    log "linked: $short -> $target"
    made=$((made+1))
  fi
done
shopt -u nullglob
if [[ $made -gt 0 ]]; then
  ok "firmware symlinks created ($made new)"
else
  ok "firmware symlinks already in place"
fi

# --- 5. RT712 Capture Unmute ---
log ""
log "[2/2] RT712 capture unmute (internal mic)"
card=""
for i in $(seq 0 6); do
  if [[ -r /proc/asound/card$i/id ]] && grep -qiE 'soundwire|amd_sdw' "/proc/asound/card$i/id" 2>/dev/null; then
    card=$i; break
  fi
done
[[ -n "$card" ]] || card="$(aplay -l 2>/dev/null | grep -iE 'soundwire|amd_sdw|SmartAmp' | grep -oE 'card [0-9]+' | head -1 | grep -oE '[0-9]+' || true)"

if [[ -z "$card" ]]; then
  warn "could not find the SoundWire card — skipping mic unmute."
else
  log "SoundWire card: $card"
  changed=0
  while IFS= read -r numid; do
    amixer -c "$card" cset numid="$numid" on >/dev/null 2>&1 && changed=$((changed+1)) || true
  done < <(amixer -c "$card" controls 2>/dev/null | grep -iE "rt712.*Capture Switch" | grep -oE 'numid=[0-9]+' | cut -d= -f2)
  while IFS= read -r numid; do
    amixer -c "$card" cset numid="$numid" 1 >/dev/null 2>&1 || true
  done < <(amixer -c "$card" controls 2>/dev/null | grep -iE "rt712.*Boost Volume" | grep -oE 'numid=[0-9]+' | cut -d= -f2)
  ok "unmuted $changed rt712 capture switch(es)"
  
  if command -v alsactl >/dev/null 2>&1; then
    alsactl store >/dev/null 2>&1 && ok "saved ALSA state"
  fi
fi

# --- 6. Final Audio Verification ---
log ""
log "[FINAL] Verifying Audio Hardware..."
if aplay -l 2>/dev/null | grep -qiE 'sof|soundwire|amd_sdw|SmartAmp|tas2783'; then
  ok "Audio hardware (SoundWire/SmartAmp) successfully enumerated!"
else
  warn "Audio hardware NOT detected via aplay. Check your kernel/firmware."
fi

log ""
ok "Installation complete."
