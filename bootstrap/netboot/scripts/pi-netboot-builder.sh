#!/usr/bin/env bash
set -e
set -o pipefail

#############################
#        script init      #
#############################
#region script init
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_PARENT_DIR"
echo "Working directory: $(pwd)"
#endregion script init

#############################
#        script params      #
#############################
#region script params

COMPOSE_PROFILE=${COMPOSE_PROFILE:="debian-netboot"}
echo "COMPOSE_PROFILE: '$COMPOSE_PROFILE'"

CLEAN_BOOT_FILES=${CLEAN_BOOT_FILES:=""}
echo "CLEAN_BOOT_FILES: '$CLEAN_BOOT_FILES'"

CLEAN_OS_FILES=${CLEAN_OS_FILES:=""}
echo "CLEAN_OS_FILES: '$CLEAN_OS_FILES'"

FORCE_REEXTRACT=${FORCE_REEXTRACT:=""}
echo "FORCE_REEXTRACT: '$FORCE_REEXTRACT'"

USE_NFS_HOME=${USE_NFS_HOME:=""}
echo "USE_NFS_HOME: '$USE_NFS_HOME'"

DOWNLOAD_LINK=${DOWNLOAD_LINK:="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-11/2023-12-11-raspios-bookworm-arm64-lite.img.xz"}
echo "DOWNLOAD_LINK: '$DOWNLOAD_LINK'"

ASSETS_DIR=${ASSETS_DIR:="raspios"}
echo "ASSETS_DIR: '$ASSETS_DIR'"

BOOTSTRAP_IP_ADDRESS=${BOOTSTRAP_IP_ADDRESS:="192.168.1.66"}
echo "BOOTSTRAP_IP_ADDRESS: '$BOOTSTRAP_IP_ADDRESS'"

BOOT_EXPORT_DIRECTORY="${BOOT_EXPORT_DIRECTORY:-"$SCRIPT_PARENT_DIR/boot"}"
echo "BOOT_EXPORT_DIRECTORY: '$BOOT_EXPORT_DIRECTORY'"

OS_EXPORT_DIRECTORY="${OS_EXPORT_DIRECTORY:-"$SCRIPT_PARENT_DIR/os"}"
echo "OS_EXPORT_DIRECTORY: '$OS_EXPORT_DIRECTORY'"

OUTPUT_DIR="${OUTPUT_DIR:-"$SCRIPT_PARENT_DIR/output"}"
echo "OUTPUT_DIR: '$OUTPUT_DIR'"

DOWNLOAD_DIRECTORY="${DOWNLOAD_DIRECTORY:-"$SCRIPT_PARENT_DIR/download"}"
echo "DOWNLOAD_DIRECTORY: '$DOWNLOAD_DIRECTORY'"

ASSETS_DIRECTORY="${ASSETS_DIRECTORY:-"$SCRIPT_PARENT_DIR/assets/$ASSETS_DIR"}"
echo "ASSETS_DIRECTORY: '$ASSETS_DIRECTORY'"

EXTRACT_DIRECTORY="${EXTRACT_DIRECTORY:-"$SCRIPT_PARENT_DIR/extract"}"
echo "EXTRACT_DIRECTORY: '$EXTRACT_DIRECTORY'"
#endregion script params

#############################
#        script vars        #
#############################
#region script vars

# download vars
DOWNLOAD_FILE=$(basename "$DOWNLOAD_LINK")

# extract vars
EXTRACT_FILENAME="${DOWNLOAD_FILE%.*}"
EXTRACT_FILENAME=$(printf "%s" "$EXTRACT_FILENAME" | tr -d '\r')

# mount paths
BOOT_MOUNT_PATH=/mnt/tmp-img-boot
OS_MOUNT_PATH=/mnt/tmp-img-os
LOOP_MOUNT_PATH=""

cleanup() {
  set +e
  if mountpoint -q "$BOOT_MOUNT_PATH"; then umount -f -l "$BOOT_MOUNT_PATH"; fi
  if mountpoint -q "$OS_MOUNT_PATH"; then umount -f -l "$OS_MOUNT_PATH"; fi
  if [ -n "$LOOP_MOUNT_PATH" ] && losetup "$LOOP_MOUNT_PATH" >/dev/null 2>&1; then
    losetup -d "$LOOP_MOUNT_PATH" >/dev/null 2>&1 || true
  fi
  if [ -n "$LOOP_MOUNT_PATH" ]; then
    rm -f ${LOOP_MOUNT_PATH}p* 2>/dev/null || true
  fi
}
trap cleanup EXIT

mount_image_partitions() {
	echo "Ensuring boot partition mounted at '$BOOT_MOUNT_PATH'"
	mkdir -p "$BOOT_MOUNT_PATH"
	if ! mountpoint -q "$BOOT_MOUNT_PATH"; then
		mount "${LOOP_MOUNT_PATH}p1" "$BOOT_MOUNT_PATH"
	fi

	echo "Ensuring OS partition mounted at '$OS_MOUNT_PATH'"
	mkdir -p "$OS_MOUNT_PATH"
	if ! mountpoint -q "$OS_MOUNT_PATH"; then
		mount "${LOOP_MOUNT_PATH}p2" "$OS_MOUNT_PATH"
	fi
}

unmount_image_partitions() {
	if mountpoint -q "$BOOT_MOUNT_PATH"; then umount -f -l "$BOOT_MOUNT_PATH"; fi
	if mountpoint -q "$OS_MOUNT_PATH"; then umount -f -l "$OS_MOUNT_PATH"; fi
}
#endregion

##############################
#        script body         #
##############################

# ensure workspace dirs exist
echo "Ensuring workspace directories exist... (download: '$DOWNLOAD_DIRECTORY', extract: '$EXTRACT_DIRECTORY', output: '$OUTPUT_DIR')"
mkdir -p "$DOWNLOAD_DIRECTORY" "$EXTRACT_DIRECTORY" "$OUTPUT_DIR"

#region download and extract
# download (likely compressed) Image File
if [[ "$DOWNLOAD_LINK" == file://* ]]; then
	echo "Skipping download: '$DOWNLOAD_FILE' is a local file (file:// URL)"
else
	# If not a file:// URL, proceed with wget
	echo "Downloading '$DOWNLOAD_FILE' [$DOWNLOAD_LINK]"
	wget -N $DOWNLOAD_LINK -e robots=off --no-check-certificate -P "$DOWNLOAD_DIRECTORY"
fi

# find compressed image file
ARCHIVE_FILE=$(find $DOWNLOAD_DIRECTORY -iname "$DOWNLOAD_FILE")

# honor FORCE_REEXTRACT on reruns
TARGET_EXTRACT_PATH="$EXTRACT_DIRECTORY/$EXTRACT_FILENAME"
FORCE_FLAG="${FORCE_REEXTRACT,,}"
# Also purge the extracted image when CLEAN_OS_FILES is set (to avoid stale/large files)
if [[ "$FORCE_FLAG" == "true" || "$FORCE_FLAG" == "1" || "$FORCE_FLAG" == "yes" || -n "$CLEAN_OS_FILES" ]]; then
    echo "Extraction cleanup enabled; removing existing extracted artifact at '$TARGET_EXTRACT_PATH'"
    rm -rf -- "$TARGET_EXTRACT_PATH" 2>/dev/null || true
fi

# extract the compressed file if not already done (or if zero-sized)
if [ ! -s "$TARGET_EXTRACT_PATH" ]; then

	# Attempt to handle various formats
	echo "Extracting '$ARCHIVE_FILE' to '$EXTRACT_DIRECTORY'"
	mkdir -p "$EXTRACT_DIRECTORY"

	if [[ "$ARCHIVE_FILE" == *.zst ]]; then
        zstd -d "$ARCHIVE_FILE" -o "$TARGET_EXTRACT_PATH"
    elif [[ "$ARCHIVE_FILE" == *.xz ]]; then
        unxz -f -k -c "$ARCHIVE_FILE" > "$TARGET_EXTRACT_PATH"
    elif [[ "$ARCHIVE_FILE" == *.tar ]]; then
        mkdir -p "$TARGET_EXTRACT_PATH"
        tar -xf "$ARCHIVE_FILE" -C "$TARGET_EXTRACT_PATH"
    elif [[ "$ARCHIVE_FILE" == *.zip ]]; then
        mkdir -p "$TARGET_EXTRACT_PATH"
        unzip "$ARCHIVE_FILE" -d "$TARGET_EXTRACT_PATH"
    elif [[ "$ARCHIVE_FILE" == *.img ]]; then
        cp "$ARCHIVE_FILE" "$TARGET_EXTRACT_PATH"
    else
        echo "Unsupported file extension"
        exit 1
    fi

    echo "Extraction Complete!"
    # Validate non-empty image file when expecting a single file
    if [[ "$ARCHIVE_FILE" =~ \.(xz|zst|img)$ ]] && [ ! -s "$TARGET_EXTRACT_PATH" ]; then
        echo "Error: extracted image '$TARGET_EXTRACT_PATH' is empty."
        exit 1
    fi
else
    echo "Output file '$TARGET_EXTRACT_PATH' already exists and is non-empty. Decompression skipped."
fi
#endregion download and extract

#region mount image and export files

# find extracted IMG file
MOST_RECENT_IMG_FILE=$TARGET_EXTRACT_PATH #$(find "$EXTRACT_DIRECTORY" -type f -name "*.img" -exec ls -t {} + | head -n 1)
# In case a directory was extracted (e.g., tar/zip), try to locate the first .img within
if [ -d "$MOST_RECENT_IMG_FILE" ]; then
    CANDIDATE=$(find "$MOST_RECENT_IMG_FILE" -maxdepth 2 -type f -name "*.img" | head -n1)
    if [ -n "$CANDIDATE" ]; then
        MOST_RECENT_IMG_FILE="$CANDIDATE"
    fi
fi
MOST_RECENT_IMG_FILE=$(printf "%s" "$MOST_RECENT_IMG_FILE" | tr -d '\r')

# Validate presence of image file before attempting losetup
if [ ! -f "$MOST_RECENT_IMG_FILE" ]; then
    echo "Error: expected image file not found: '$MOST_RECENT_IMG_FILE'"
    echo "Directory listing of '$EXTRACT_DIRECTORY':"
    ls -la "$EXTRACT_DIRECTORY" || true
    exit 1
fi
BASE_IMAGE_PATH="$MOST_RECENT_IMG_FILE"
IMG_FILENAME_WITH_EXTENSION=$(basename "$BASE_IMAGE_PATH")
IMG_FILENAME="${IMG_FILENAME_WITH_EXTENSION%.*}"

# optionally purge old artifacts for this image to reclaim space
if [ -n "$CLEAN_OS_FILES" ]; then
	echo "CLEAN_OS_FILES is set; removing existing output artifacts for '$IMG_FILENAME' from '$OUTPUT_DIR'"
	find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name "${IMG_FILENAME}*.img" -o -name "${IMG_FILENAME}*.img.*" -o -name "${IMG_FILENAME}*.xz" -o -name "${IMG_FILENAME}*.zst" -o -name "${IMG_FILENAME}*.zip" -o -name "${IMG_FILENAME}*.tar" \) -print -delete
fi

# Decide whether to create a working copy; default is to reuse the extracted image to save space.
USE_WORKING_COPY="${USE_WORKING_COPY:-}"
if [ -n "$USE_WORKING_COPY" ]; then
  WORKING_IMAGE_PATH="$OUTPUT_DIR/${IMG_FILENAME}.working.img"
  echo "Creating working copy at '$WORKING_IMAGE_PATH' (USE_WORKING_COPY set)"
  IMAGE_SIZE_BYTES=$(stat -c%s "$BASE_IMAGE_PATH" 2>/dev/null || echo 0)
  AVAILABLE_BYTES=$(df --output=avail -B1 "$OUTPUT_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [ -n "$AVAILABLE_BYTES" ] && [ "$AVAILABLE_BYTES" -lt "$IMAGE_SIZE_BYTES" ]; then
    echo "Insufficient space for working copy (~${IMAGE_SIZE_BYTES} bytes needed, ${AVAILABLE_BYTES} available); reusing extracted image instead."
    USE_WORKING_COPY=""
  else
    rm -f "$WORKING_IMAGE_PATH"
    # try a reflink first to keep a pristine base if supported
    if ! cp --reflink=auto --sparse=always "$BASE_IMAGE_PATH" "$WORKING_IMAGE_PATH"; then
      echo "cp reflink failed; falling back to standard copy"
      cp --sparse=always "$BASE_IMAGE_PATH" "$WORKING_IMAGE_PATH"
    fi
    MOST_RECENT_IMG_FILE="$WORKING_IMAGE_PATH"
    echo "Image size: $(stat -c%s "$MOST_RECENT_IMG_FILE" 2>/dev/null || echo 0) bytes"
  fi
fi

# If no working copy created, operate directly on the extracted image
if [ -z "$USE_WORKING_COPY" ]; then
  MOST_RECENT_IMG_FILE="$BASE_IMAGE_PATH"
  echo "Reusing extracted image as working image: '$MOST_RECENT_IMG_FILE'"
fi

# Try to ensure loop module is available
modprobe loop || true
if ! [ -e /dev/loop-control ] && ! losetup -f >/dev/null 2>&1; then
    echo "Warning: loop device support appears unavailable (/dev/loop-control missing and no free loop)."
    echo "If running in Docker, ensure the container is privileged and the host kernel supports loop devices."
fi

# Ensure no stale loop devices from prior runs
losetup -D || true

# mount IMG file using losetup
set +e
LOOP_MOUNT_PATH=$(losetup -Pf "$MOST_RECENT_IMG_FILE" --show 2>/tmp/losetup.err)
ATTEMPTS=0
while [ -z "$LOOP_MOUNT_PATH" ] && [ $ATTEMPTS -lt 5 ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    if [ -e "$MOST_RECENT_IMG_FILE" ]; then
        echo "Image present: '$MOST_RECENT_IMG_FILE' ($(stat -c%s "$MOST_RECENT_IMG_FILE" 2>/dev/null || echo 0) bytes)"
    else
        echo "Image missing: '$MOST_RECENT_IMG_FILE'"
    fi
    echo "losetup attempt $ATTEMPTS failed: $(tr -d '\n' </tmp/losetup.err)"
    sleep 1
    LOOP_MOUNT_PATH=$(losetup -Pf "$MOST_RECENT_IMG_FILE" --show 2>/tmp/losetup.err)
done
set -e
if [ -z "$LOOP_MOUNT_PATH" ]; then
    echo "Error: unable to attach loop device for '$MOST_RECENT_IMG_FILE' after $ATTEMPTS attempts."
    echo "Hint: if this persists, try removing '$TARGET_EXTRACT_PATH' to force re-extraction, or ensure the container is running with --privileged."
    exit 1
fi
echo "Mounted '$MOST_RECENT_IMG_FILE' at '$LOOP_MOUNT_PATH'"

# fix for running in docker
# for whatever reason (probably permission related) losetup does not create the partition mounts
# https://github.com/RPi-Distro/pi-gen/issues/482#issuecomment-1676103147
rm -f ${LOOP_MOUNT_PATH}p* 2>/dev/null || true
PARTITIONS=$(lsblk --raw --output "MAJ:MIN" --noheadings ${LOOP_MOUNT_PATH} | tail -n +2)
COUNTER=1
for i in $PARTITIONS; do
	echo "Creating node file for partition $i..."
	MAJ=$(echo $i | cut -d: -f1)
	MIN=$(echo $i | cut -d: -f2)
	if [ ! -e "${LOOP_MOUNT_PATH}p${COUNTER}" ]; then
		# mknod may race with udev auto-creating the node; ignore "exists" noise
		mknod ${LOOP_MOUNT_PATH}p${COUNTER} b $MAJ $MIN 2>/dev/null || true
	fi
	COUNTER=$((COUNTER + 1))
done

##### Sync OS & Boot Files #####
echo "Mounting image partitions for export..."
mount_image_partitions

# copy boot files from mountpoint to export directory (delete keeps it in sync without pre-wipe)
if [ -n "$CLEAN_BOOT_FILES" ]; then
	echo "Warning: CLEAN_BOOT_FILES is set. Syncing boot export with --delete."
fi
echo "Copying boot files to '$BOOT_EXPORT_DIRECTORY'"
rsync -xar --inplace --delete --progress "$BOOT_MOUNT_PATH"/ "$BOOT_EXPORT_DIRECTORY"/

# copy OS files from mountpoint to export directory
if [ -n "$CLEAN_OS_FILES" ]; then
	echo "Warning: CLEAN_OS_FILES is set. Syncing OS export with --delete."
fi
echo "Copying OS files to '$OS_EXPORT_DIRECTORY/$IMG_FILENAME'"
rsync -xar --inplace --delete --progress "$OS_MOUNT_PATH"/ "$OS_EXPORT_DIRECTORY/$IMG_FILENAME"/
echo "Unmounting image partitions after export"
unmount_image_partitions
#endregion mount image and export files

#region copy assets
copy_assets() {
  local OVERLAY_TARGET="$1"
  echo "Copying assets from '$ASSETS_DIRECTORY' ($OVERLAY_TARGET overlays)"

	# make all scripts executable
  find "$ASSETS_DIRECTORY" -type f -name "*.sh" -exec chmod +x {} +;

	# copy boot assets with overlay support
  if [ -d "$ASSETS_DIRECTORY/boot" ]; then
	  echo "  -> syncing boot assets to '$BOOT_EXPORT_DIRECTORY'"
		ls -aR "$ASSETS_DIRECTORY/boot"

		echo "Checking for boot overlays for target '$OVERLAY_TARGET'it"
	  find "$ASSETS_DIRECTORY/boot" -type f ! -path "$ASSETS_DIRECTORY/boot/overlays/*" | while read -r f; do
			rel="${f#"$ASSETS_DIRECTORY/boot/"}"
			dest="$BOOT_EXPORT_DIRECTORY/$rel"
			mkdir -p "$(dirname "$dest")"

			overlays=$(find "$ASSETS_DIRECTORY/boot/overlays/$OVERLAY_TARGET" -type f -path "*/$rel" 2>/dev/null)
			echo "Processing boot asset '$rel' with overlays: $overlays"
			if [ -n "$overlays" ]; then
				echo "Merging overlays for '$rel'"
				yq ea '. as $item ireduce ({}; . *+ $item)' "$f" $overlays > "$dest"
			else
				echo "No overlay found. Copying base file for '$rel'"
				rsync -xar --inplace --progress "$f" "$dest"
			fi
		done
	fi

	# copy os assets (no overlay support yet)
  if [ -d "$ASSETS_DIRECTORY/os" ]; then
	  echo "  -> syncing OS assets to '$OS_EXPORT_DIRECTORY/$IMG_FILENAME'"
		ls -aR "$ASSETS_DIRECTORY/os"

		DEST_OS_DIR="$OS_EXPORT_DIRECTORY/$IMG_FILENAME"
	  echo "  -> syncing OS assets to '$DEST_OS_DIR'"
	  rsync -xar --inplace --progress "$ASSETS_DIRECTORY/os/" "$DEST_OS_DIR/"
  fi
}
#endregion copy assets

#region sdcard
if [[ "${COMPOSE_PROFILE,,}" == *sdcard* ]]; then
	echo "COMPOSE_PROFILE contains 'sdcard'; syncing exports back into disk image."

	# copy sdcard specific assets (cloud-init config)
	copy_assets "sdcard"

	mount_image_partitions

	echo "Syncing boot partition..."
	rsync -ax --delete --no-owner --no-group "$BOOT_EXPORT_DIRECTORY"/ "$BOOT_MOUNT_PATH"/
	sync

	echo "Syncing root partition..."
	rsync -ax --delete "$OS_EXPORT_DIRECTORY/$IMG_FILENAME"/ "$OS_MOUNT_PATH"/
	sync
	unmount_image_partitions

	TIMESTAMP=$(date +%Y%m%d%H%M%S)
	OUTPUT_IMAGE_BASENAME="${IMG_FILENAME}_${TIMESTAMP}.img"
	OUTPUT_IMAGE_PATH="$OUTPUT_DIR/$OUTPUT_IMAGE_BASENAME"
	echo "Writing base image to '$OUTPUT_IMAGE_PATH' (container-local volume)"
	cp "$MOST_RECENT_IMG_FILE" "$OUTPUT_IMAGE_PATH"

	ORIGINAL_EXTENSION="${DOWNLOAD_FILE#${EXTRACT_FILENAME}}"
	FINAL_IMAGE_PATH="$OUTPUT_IMAGE_PATH"

	case "$ORIGINAL_EXTENSION" in
		.xz)
			echo "Compressing image to XZ format..."
			xz -T0 -vv -zf "$OUTPUT_IMAGE_PATH"
			FINAL_IMAGE_PATH="${OUTPUT_IMAGE_PATH}.xz"
			;;
		.zst)
			echo "Compressing image to Zstandard format..."
			zstd -f --rm -T0 --progress "$OUTPUT_IMAGE_PATH"
			FINAL_IMAGE_PATH="${OUTPUT_IMAGE_PATH}.zst"
			;;
		.zip)
			echo "Compressing image to ZIP format..."
			(cd "$(dirname "$OUTPUT_IMAGE_PATH")" && zip -qr "$(basename "$OUTPUT_IMAGE_PATH").zip" "$(basename "$OUTPUT_IMAGE_PATH")")
			rm -f "$OUTPUT_IMAGE_PATH"
			FINAL_IMAGE_PATH="${OUTPUT_IMAGE_PATH}.zip"
			;;
		.tar)
			echo "Creating tar archive..."
			(cd "$(dirname "$OUTPUT_IMAGE_PATH")" && tar -cf "$(basename "$OUTPUT_IMAGE_PATH").tar" "$(basename "$OUTPUT_IMAGE_PATH")")
			rm -f "$OUTPUT_IMAGE_PATH"
			FINAL_IMAGE_PATH="${OUTPUT_IMAGE_PATH}.tar"
			;;
		.img)
			echo "Leaving image uncompressed."
			;;
		*)
		if [[ -n "$ORIGINAL_EXTENSION" ]]; then
			echo "Warning: unsupported original extension '$ORIGINAL_EXTENSION'. Leaving image as raw .img."
		fi
		;;
	esac

	echo "Bundled image written to '$FINAL_IMAGE_PATH'"
	echo "Copying artifact to host bind mount: '$DOWNLOAD_DIRECTORY'"
	cp -f "$FINAL_IMAGE_PATH" "$DOWNLOAD_DIRECTORY/" || echo "Warning: copy to host bind mount failed (non-fatal). Artifact remains at '$FINAL_IMAGE_PATH'."
fi
#endregion sdcard

#region netboot
### Netboot patching
if [[ "${COMPOSE_PROFILE,,}" == *netboot* ]]; then
	echo "COMPOSE_PROFILE contains 'netboot'; applying netboot patches."

	# create SD card image for optional local boot fallback
	echo "COMPOSE_PROFILE contains 'sdcard'; syncing exports back into disk image and staging sd.img."

	# copy sdcard specific assets (cloud-init config)
	copy_assets "sdcard"

	# echo "Patching '$BOOT_EXPORT_DIRECTORY/cmdline.txt'"
	# # read existing cmdline.txt contents
	# CMDLINE_CONTENTS=$(cat "$BOOT_EXPORT_DIRECTORY/cmdline.txt" || echo "")

	# # use overlay filesystem so machine level changes are in tmpfs (RAM) only
	# CMDLINE_CONTENTS="$CMDLINE_CONTENTS modules-load=overlay overlayroot=tmpfs"

	# # update cmdline.txt
	# echo $CMDLINE_CONTENTS > $BOOT_EXPORT_DIRECTORY/cmdline.txt

	### Sync exports back into disk image
	mount_image_partitions

	echo "Syncing boot partition..."
	rsync -ax --delete --no-owner --no-group "$BOOT_EXPORT_DIRECTORY"/ "$BOOT_MOUNT_PATH"/
	sync

	echo "Syncing root partition..."
	rsync -ax --delete "$OS_EXPORT_DIRECTORY/$IMG_FILENAME"/ "$OS_MOUNT_PATH"/
	sync
	unmount_image_partitions

	sd_copy_pid=""
	(
		set -e
		SD_IMG_DIR="$OS_EXPORT_DIRECTORY/$IMG_FILENAME/etc"
		mkdir -p "$SD_IMG_DIR"
		SD_IMG_PATH="$SD_IMG_DIR/sd.img"
		BASE_SHA=$(sha256sum "$MOST_RECENT_IMG_FILE" | awk '{print $1}')
		CURR_SHA=""
		if [ -f "$SD_IMG_PATH" ]; then
			CURR_SHA=$(sha256sum "$SD_IMG_PATH" | awk '{print $1}')
		fi

		if [ -n "$CURR_SHA" ] && [ "$CURR_SHA" = "$BASE_SHA" ]; then
			echo "sd.img already present with matching sha256 ($BASE_SHA); skipping copy."
		else
			echo "Staging raw image for sd-flash at '$SD_IMG_PATH'"
			if ! cp --reflink=auto --sparse=always -f "$MOST_RECENT_IMG_FILE" "$SD_IMG_PATH"; then
				echo "Reflink copy failed; falling back to standard copy..."
				cp -f "$MOST_RECENT_IMG_FILE" "$SD_IMG_PATH"
			fi
		fi
		echo "Computing sha256 for sd.img"
		(cd "$SD_IMG_DIR" && sha256sum sd.img > sd.img.sha256)
	) &
	sd_copy_pid=$!


	# copy netboot specific assets (cloud-init config)
	copy_assets "netboot"

	echo "Patching '$BOOT_EXPORT_DIRECTORY/cmdline.txt'"
	# Noisy boot for debugging
	CMDLINE_CONTENTS="rd.debug selinux=0 dwc_otg.lpm_enable=0 console=tty1 elevator=deadline systemd.log_level=info systemd.show_status=1 systemd.log_target=console systemd.debug-shell=1"

	# remote root via NFS, RW by default
	CMDLINE_CONTENTS="$CMDLINE_CONTENTS ip=dhcp root=/dev/nfs rootwait rootdelay=5 rw nfsroot=$BOOTSTRAP_IP_ADDRESS:/mnt/nfsshare/$IMG_FILENAME,v3,tcp,ro"

	# disable unwanted services (snapd, rpi-eeprom-update, systemd-networkd-wait-online)
	CMDLINE_CONTENTS="$CMDLINE_CONTENTS systemd.mask=systemd-networkd-wait-online.service systemd.mask=snapd.seeded.service systemd.mask=snapd.service systemd.mask=snapd.socket systemd.mask=wpa_supplicant.service systemd.mask=rpi-eeprom-update.service systemd.mask=rpi-eeprom-config.service systemd.mask=rpi-eeprom-update.timer systemd.mask=apport.service systemd.mask=rsyslog.service systemd.mask=ubuntu-advantage.service systemd.mask=ubuntu-advantage-timer.timer systemd.mask=apt-daily.timer systemd.mask=apt-daily-upgrade.timer systemd.mask=motd-news.timer"

	# use overlay filesystem so machine level changes are in tmpfs (RAM) only
	CMDLINE_CONTENTS="$CMDLINE_CONTENTS modules-load=overlay overlayroot=tmpfs"

	# unattended install / first boot config
	if [[ "$IMG_FILENAME" == *raspios* ]]; then
		CMDLINE_CONTENTS="$CMDLINE_CONTENTS init=/boot/apply-config.sh"
	else
		CMDLINE_CONTENTS="$CMDLINE_CONTENTS ds=nocloud;s=http://$BOOTSTRAP_IP_ADDRESS/"
	fi

	# update cmdline.txt
	echo $CMDLINE_CONTENTS > $BOOT_EXPORT_DIRECTORY/cmdline.txt

	### patch /etc/overlayroot.conf (initramfs overlay configuration)
	# if not raspios, assume overlayroot package is present
	if [[ "$IMG_FILENAME" == *raspios* ]]; then
		echo "Skipping /etc/overlayroot.conf patch: '$IMG_FILENAME' appears to be Raspios (no overlayroot package)"
	else
		echo "Patching '$OS_EXPORT_DIRECTORY/$IMG_FILENAME/etc/overlayroot.conf'"
		OVERLAYROOT_CONTENTS=$'overlayroot="tmpfs"\noverlayroot_overlayfs_opts="redirect_dir=off,index=off,metacopy=off"'
		echo -e "$OVERLAYROOT_CONTENTS" > "$OS_EXPORT_DIRECTORY/$IMG_FILENAME/etc/overlayroot.conf"
	fi

	### patch /etc/fstab (if exists) to use NFS
	FSTAB_PATH=$OS_EXPORT_DIRECTORY/$IMG_FILENAME/etc/fstab
	if [ -f "$FSTAB_PATH" ]; then
		echo "Patching '$FSTAB_PATH'"

		FSTAB_CONTENTS="\
proc                                                             /proc           proc    defaults                                                                    0       0\n\
tmpfs                                                            /tmp            tmpfs   defaults,size=512M                                                          0       0\n\
overlay                                                          /               overlay defaults                                                                    0       2"
		echo -e "$FSTAB_CONTENTS" > "$FSTAB_PATH"
	fi

	# done
else
	echo "COMPOSE_PROFILE '$COMPOSE_PROFILE' does not include 'netboot'; skipping netboot-specific patches."
fi
#endregion netboot

# wait for sd.img copy to finish
if [ -n "$sd_copy_pid" ]; then
  if ! wait "$sd_copy_pid"; then
    echo "sd.img staging failed"; exit 1
  fi
fi

# cleanup
unmount_image_partitions
losetup -D

# we're done 🎉
echo "Done!"
