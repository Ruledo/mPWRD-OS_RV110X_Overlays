#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# This is the image customization script

# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed

# NOTE: If you want to transfer files between chroot and host
# userpatches/overlay directory on host is bind-mounted to /tmp/overlay in chroot
# The sd card's root path is accessible via $SDCARD variable.

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

# 'Global' env vars for all functions in this script
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Release-specific variables
case $RELEASE in
	trixie)
		pipx_g=true
		;;
	bookworm)
		pipx_g=false
		;;
	resolute)
		pipx_g=true
		;;
	noble)
		pipx_g=false
		;;
	*)
		# Exit early for unsupported releases
		echo "Unsupported mPWRD RELEASE: $RELEASE"
		exit 1
		;;
esac

Main() {
	apt-get update
	# meshtasticd can't currently be installed via the `meshtasticd` Extension
	# due to a race condition with the gpio group when installing before family-tweaks.
	InstallAptPkg "meshtasticd"
	# Same story with i2c-tools. Race condition with i2c group in family-tweaks.
	InstallAptPkg "i2c-tools"
	case $pipx_g in
		true)
			InstallPipxPkg "meshtastic"
			InstallPipxPkg "contact"
			;;
		*)
			echo "'pipx install --global' skipped for ${RELEASE} due to old pipx version."
			echo "Target Debian 13+ or Ubuntu 26.04+ for pipx global support."
			;;
	esac
	# Always run
	ApplyFSOverlay
	BoardSpecific "$@"
	apt-get clean && rm -rf /var/lib/apt/lists/*
	CompileDTBO
} # Main

ApplyFSOverlay() {
	# Copy overlay files to their destinations
	# replacing existing files
	cp -r /tmp/overlay/fs/* /
} # ApplyFSOverlay

InstallAptPkg() {
	PKGSPEC="$1"
	# Install package via apt-get
	echo "APT: Installing ${PKGSPEC}..."
	apt-get --yes --allow-unauthenticated \
		install $PKGSPEC
} # InstallAptPkg

InstallPipxPkg() {
	PKGSPEC="$1"
	# Install package via 'pipx install --global'
	pipx install --global "${PKGSPEC}"
	# --global flag requires pipx 1.5.0 or newer
} # InstallPipxPkg

GetDTBOSourceDirs() {
	local family_dir="/tmp/overlay/dtbo/${LINUXFAMILY}"
	local base_family="${LINUXFAMILY%%-*}"
	local base_dir="/tmp/overlay/dtbo/${base_family}"
	if [ -d "${base_dir}" ] && [ "${base_dir}" != "${family_dir}" ]; then
		printf '%s\n' "${base_dir}"
	fi
	if [ -d "${family_dir}" ]; then
		printf '%s\n' "${family_dir}"
	fi
} # GetDTBOSourceDirs

CompileDTBO() {
	local dtbo_dir
	local -a dtbo_dirs=()
	# Always compile DTBOs for each family (even if not enabled by default)
	mkdir -p /boot/overlay-user
	echo "Compiling mPWRD device tree overlays for ${LINUXFAMILY}"
	while IFS= read -r dtbo_dir; do
		if [ -n "${dtbo_dir}" ]; then
			dtbo_dirs+=("${dtbo_dir}")
		fi
	done < <(GetDTBOSourceDirs)
	if [ ${#dtbo_dirs[@]} -eq 0 ]; then
		echo "No overlay sources found for ${LINUXFAMILY}"
		return 0
	fi
	shopt -s nullglob
	# If *.dts returns no results, the loop will not execute (desired behavior)
	for dtbo_dir in "${dtbo_dirs[@]}"; do
		echo "Scanning ${dtbo_dir}"
		for f in "${dtbo_dir}"/*.dts; do
			DTBO_NAME=$(basename "${f}" .dts)
			echo "Compiling ${DTBO_NAME}"
			dtc -@ -q -I dts -O dtb -o "/boot/overlay-user/${DTBO_NAME}.dtbo" "${f}"
		done
	done
	shopt -u nullglob
} # CompileDTBO

EnableExtlinuxUserOverlays() {
	local extlinux_conf="/boot/extlinux/extlinux.conf"
	local overlay_name
	local overlay_path
	local extlinux_pattern='^[[:space:]]*fdt(dir)?[[:space:]]'
	local -a overlay_paths=()
	if [ ! -f "${extlinux_conf}" ]; then
		echo "Warning: ${extlinux_conf} not found, cannot enable device tree overlays"
		return 1
	fi
	for overlay_name in "$@"; do
		overlay_paths+=("/boot/overlay-user/${overlay_name}.dtbo")
	done
	if grep -Eq '^[[:space:]]*fdtoverlays[[:space:]]' "${extlinux_conf}"; then
		for overlay_path in "${overlay_paths[@]}"; do
			if ! grep -Fq "${overlay_path}" "${extlinux_conf}"; then
				sed -i "/^[[:space:]]*fdtoverlays[[:space:]]/ s|\$| ${overlay_path}|" "${extlinux_conf}"
			fi
		done
	elif grep -Eq "${extlinux_pattern}" "${extlinux_conf}"; then
		sed -Ei "/${extlinux_pattern}/a\\  fdtoverlays ${overlay_paths[*]}" "${extlinux_conf}"
	else
		echo "  fdtoverlays ${overlay_paths[*]}" >> "${extlinux_conf}"
	fi
} # EnableExtlinuxUserOverlays

ShouldUseArmbianEnvUserOverlays() {
	if [ "${BOOT_OVERLAY_MODE:-}" = "armbianEnv" ]; then
		return 0
	fi
	if [ -f /boot/armbianEnv.txt ] && grep -q '^boot_overlay_mode=armbianEnv$' /boot/armbianEnv.txt; then
		return 0
	fi
	if HasLegacyBootscriptOverlayMode; then
		return 0
	fi
	return 1
} # ShouldUseArmbianEnvUserOverlays

HasLegacyBootscriptOverlayMode() {
	[ -f /boot/boot.cmd ] && grep -q '^setenv overlay_error' /boot/boot.cmd
} # HasLegacyBootscriptOverlayMode

EnsureArmbianEnvListContains() {
	local key="$1"
	shift
	local value
	local current_values=""

	if [ ! -f /boot/armbianEnv.txt ]; then
		echo "Warning: /boot/armbianEnv.txt not found, cannot update ${key}"
		return 1
	fi

	if grep -q "^${key}=" /boot/armbianEnv.txt; then
		current_values=$(sed -n "s/^${key}=//p" /boot/armbianEnv.txt | head -n 1)
	fi

	for value in "$@"; do
		if ! grep -qE "(^|[[:space:]])${value}([[:space:]]|$)" <<< "${current_values}"; then
			if [ -n "${current_values}" ]; then
				current_values="${current_values} ${value}"
			else
				current_values="${value}"
			fi
		fi
	done

	if grep -q "^${key}=" /boot/armbianEnv.txt; then
		sed -i "s|^${key}=.*|${key}=${current_values}|" /boot/armbianEnv.txt
	else
		echo "${key}=${current_values}" >> /boot/armbianEnv.txt
	fi
} # EnsureArmbianEnvListContains

EnableUserDTOverlay() {
	local user_overlays="$1"
	local -a overlay_names=()
	echo "Enabling user_overlays: ${user_overlays}"
	read -r -a overlay_names <<< "${user_overlays}"
	# Enable overlays (space separated)
	# in /boot/armbianEnv.txt or /boot/extlinux/extlinux.conf
	if ShouldUseArmbianEnvUserOverlays; then
		EnsureArmbianEnvListContains "user_overlays" "${overlay_names[@]}"
	elif [ -f /boot/extlinux/extlinux.conf ]; then
		EnableExtlinuxUserOverlays "${overlay_names[@]}"
	else
		echo "Warning: no supported boot config found, cannot enable device tree overlays"
	fi
} # EnableUserDTOverlay

EnableKernelDTOverlay() {
	OVERLAY_NAME="$1"
	echo "Enabling kernel (builtin) overlay: ${OVERLAY_NAME}"
	# Enable overlay in /boot/armbianEnv.txt
	if [ -f /boot/armbianEnv.txt ]; then
		EnsureArmbianEnvListContains "overlays" "${OVERLAY_NAME}"
	else
		echo "Warning: /boot/armbianEnv.txt not found, cannot enable device tree overlays"
	fi
} # EnableKernelDTOverlay


MTSetMacSrc() {
	iface_name="$1"
	# Set the General.MACAddressSource to $iface_name
	# for meshtasticd (/etc/meshtasticd/config.yaml)
	sed -i "s/^#\?  MACAddressSource: .*/  MACAddressSource: $iface_name/" /etc/meshtasticd/config.yaml
} # MTSetMacSrc

BoardSpecific() {
	# Note: Board specific customizations may also be added via Extensions
	# See extensions/ directory
	case $BOARD in
		ebyte-ecb41-pge)
			# Enable ebyte-ecb41-pge-spi0-1cs-spidev overlay
			EnableUserDTOverlay "ebyte-ecb41-pge-spi0-1cs-spidev"
			# Set meshtasticd MacAddressSource to 'end0' for ebyte-ecb41-pge
			MTSetMacSrc "end0"
			;;
		forlinx-ok3506-s12)
			# Enable forlinx-ok3506-s12-spi0-1cs-spidev overlay
			EnableKernelDTOverlay "forlinx-ok3506-s12-spi0-1cs-spidev"
			# Set meshtasticd MacAddressSource to 'end0' for forlinx-ok3506-s12
			MTSetMacSrc "end0"
			;;
		luckfox-lyra-plus)
			# Enable luckfox-lyra-plus-spi0-1cs_rmio13-spidev overlay
			EnableKernelDTOverlay "luckfox-lyra-plus-spi0-1cs_rmio13-spidev"
			# Set meshtasticd MacAddressSource to 'end1' for lyra-plus
			MTSetMacSrc "end1"
			# Download waveshare pico config for lyra-plus
			curl -fsSL https://raw.githubusercontent.com/meshtastic/firmware/refs/tags/v2.7.22.96dd647/bin/config.d/lora-lyra-ws-raspberry-pi-pico-hat.yaml \
				-o /etc/meshtasticd/config.d/lora-lyra-ws-raspberry-pi-pico-hat.yaml
			;;
		luckfox-lyra-ultra-w)
			# Enable devicetree overlays
			EnableKernelDTOverlay "luckfox-lyra-ultra-w-spi0-1cs-spidev"
			EnableUserDTOverlay "luckfox-lyra-ultra-w-uart1"
			EnableUserDTOverlay "luckfox-lyra-ultra-w-i2c0"
			# Set meshtasticd MacAddressSource to 'end1' for lyra-ultra-w
			MTSetMacSrc "end1"
			# Download 'Luckfox Ultra' 2W hat config for lyra-ultra
			curl -fsSL https://raw.githubusercontent.com/meshtastic/firmware/refs/tags/v2.7.22.96dd647/bin/config.d/lora-lyra-ultra_2w.yaml \
				-o /etc/meshtasticd/config.d/lora-lyra-ultra_2w.yaml
			;;
		luckfox-lyra-zero-w)
			# Enable luckfox-lyra-zero-w-spi0-1cs-spidev overlay
			EnableKernelDTOverlay "luckfox-lyra-zero-w-spi0-1cs-spidev"
			;;
		luckfox-pico-max)
			# Set meshtasticd MacAddressSource to 'eth0' for pico-max
			MTSetMacSrc "eth0"
			# Download waveshare pico config for pico-max (from develop branch)
			curl -fsSL https://github.com/meshtastic/firmware/raw/466cc4cecddd11cd1bb0d0b166bd658d116832b3/bin/config.d/lora-luckfox-pico-max-ws-raspberry-pi-pico-hat.yaml \
				-o /etc/meshtasticd/config.d/lora-luckfox-pico-max-ws-raspberry-pi-pico-hat.yaml
			;;
		luckfox-pico-mini)
			# Set meshtasticd MacAddressSource to 'eth0' for pico-mini
			MTSetMacSrc "eth0"
			# Download femtofox config for pico-mini (directory changed upstream)
			curl -fsSL https://raw.githubusercontent.com/meshtastic/firmware/refs/tags/v2.7.22.96dd647/bin/config.d/lora-femtofox_SX1262_TCXO.yaml \
				-o /etc/meshtasticd/config.d/lora-femtofox_SX1262_TCXO.yaml
			;;
		# raspberry-pi-64bit
		rpi4b)
			# Set meshtasticd MacAddressSource to 'end0' for Raspberry Pi
			MTSetMacSrc "end0"
			;;
		*)
			echo "No board-specific customizations for board: $BOARD"
			;;
	esac
	# Fix ownership for meshtasticd configs
	chown -R meshtasticd:meshtasticd /etc/meshtasticd/config.d
} # BoardSpecific

Main "$@"
