#!/bin/bash

echo "====================="
echo "start.sh"
echo "====================="
uname -a

#############################
#        script vars        #
#############################

# options
VM_OS=${VM_OS:-"22.04"}
VM_NAME=${VM_NAME:-"ubuntu-vm"}
VM_CPUS=${VM_CPUS:-"4"}
VM_MEMORY=${VM_MEMORY:-"4G"}
VM_DISK=${VM_DISK:-"15G"}
VM_REBUILD=${VM_REBUILD:-false}

# Get the parent directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR_NAME="$(basename $PARENT_DIR)"

##############################
#        script body         #
##############################

# Check if multipass is installed
if ! command -v multipass &> /dev/null; then
    echo "Multipass is not installed. Exiting script."
    exit 1
fi

# helper to run multipass with maximum verbosity
multipass_cmd() {
    multipass -vvvv "$@"
    # multipass "$@"
}

# ensure multipass daemon is running (macOS)
if [[ "$(uname)" == "Darwin" ]]; then
    if ! multipass list >/dev/null 2>&1; then
        echo "Multipass daemon not running, restarting via launchctl..."
        sudo launchctl kickstart -k system/com.canonical.multipassd
        sleep 2
        if ! multipass list >/dev/null 2>&1; then
            echo "Failed to start Multipass daemon after launchctl restart."
            exit 1
        fi
    fi
fi

UNAME_S="$(uname -s)"
ARCH="$(uname -m)"

# Only enforce driver/qemu-arch tweaks on macOS; avoid breaking Windows/Linux
if [[ "$UNAME_S" == "Darwin" ]]; then
    # Use qemu on modern macOS (incl. Apple Silicon)
    DEFAULT_DRIVER="qemu"

    CURRENT_DRIVER_RAW=$(multipass_cmd get local.driver 2>/dev/null | tail -n1)
    CURRENT_DRIVER="${CURRENT_DRIVER_RAW#*=}"
    CURRENT_DRIVER="${CURRENT_DRIVER:-$DEFAULT_DRIVER}"

    if [[ "$CURRENT_DRIVER" != "$DEFAULT_DRIVER" ]]; then
        echo "Switching Multipass driver from '$CURRENT_DRIVER' to default '$DEFAULT_DRIVER'..."
        multipass_cmd set local.driver="$DEFAULT_DRIVER"
    fi

    CURRENT_QEMU_ARCH_RAW=$(multipass_cmd get local.qemu-arch 2>/dev/null | tail -n1)
    CURRENT_QEMU_ARCH="${CURRENT_QEMU_ARCH_RAW#*=}"

    check_qemu_arch_compatibility() {
        local host_arch="$1"
        local override="$2"

        case "$host_arch" in
            arm64)
                if [[ -n "$override" && "$override" != "arm64" && "$override" != "aarch64" ]]; then
                    echo "Detected incompatible Multipass qemu architecture override '$override' on Apple silicon."
                    echo "Attempting to reset it to the default (arm64)..."
                    if multipass_cmd unset local.qemu-arch >/dev/null 2>&1; then
                        return 0
                    fi
                    if multipass_cmd set local.qemu-arch=arm64 >/dev/null 2>&1; then
                        return 0
                    fi
                    echo "Unable to reset Multipass qemu architecture override. Please run:"
                    echo "  multipass unset local.qemu-arch"
                    exit 1
                fi
                ;;
            x86_64|amd64)
                if [[ "$override" == "arm64" || "$override" == "aarch64" ]]; then
                    echo "Detected ARM qemu override on an x86 host; resetting to x86_64..."
                    if multipass_cmd unset local.qemu-arch >/dev/null 2>&1; then
                        return 0
                    fi
                    if multipass_cmd set local.qemu-arch=x86_64 >/dev/null 2>&1; then
                        return 0
                    fi
                    echo "Unable to reset Multipass qemu architecture override. Please run:"
                    echo "  multipass unset local.qemu-arch"
                    exit 1
                fi
                ;;
        esac
    }

    check_qemu_arch_compatibility "$ARCH" "$CURRENT_QEMU_ARCH"

    if [[ "$ARCH" == "arm64" ]]; then
        UPDATED_QEMU_ARCH_RAW=$(multipass_cmd get local.qemu-arch 2>/dev/null | tail -n1)
        UPDATED_QEMU_ARCH="${UPDATED_QEMU_ARCH_RAW#*=}"
        if [[ -n "$UPDATED_QEMU_ARCH" && "$UPDATED_QEMU_ARCH" != "arm64" && "$UPDATED_QEMU_ARCH" != "aarch64" ]]; then
            echo "Multipass qemu architecture override is still '$UPDATED_QEMU_ARCH'. Exiting to avoid a hang."
            echo "Run 'multipass unset local.qemu-arch' then re-run this script."
            exit 1
        fi
    fi
fi

# source .env
if [ -f "$PARENT_DIR/.env" ]; then
    export ENV_FILE="$PARENT_DIR/.env"
    echo "Sourcing $ENV_FILE..."
    source "$ENV_FILE"
else
    echo "No .env file found."
    ls -la $PARENT_DIR
    exit 1
fi

# Set the default bridged network for created VMs (always bridged like original)
# Use robust parsing to handle names with spaces
if multipass_cmd networks --format csv >/dev/null 2>&1; then
    NETWORK_NAME=$(multipass_cmd networks --format csv | tail -n +2 | head -n 1 | cut -d, -f1)
else
    NETWORK_NAME=$(multipass_cmd networks | awk 'NR==2{print; exit}' | sed -E 's/  +.*$//')
fi

# Only update if different to avoid bouncing the daemon unnecessarily (Windows)
CURRENT_BRIDGED_RAW=$(multipass_cmd get local.bridged-network 2>/dev/null | tail -n1)
CURRENT_BRIDGED="${CURRENT_BRIDGED_RAW#*=}"

if [[ "$CURRENT_BRIDGED" != "$NETWORK_NAME" ]]; then
    echo "Setting default bridged network to '$NETWORK_NAME' (was '${CURRENT_BRIDGED:-unset}')..."
    if ! multipass_cmd set local.bridged-network="$NETWORK_NAME"; then
        echo "Failed to set bridged network."
        exit 1
    fi
else
    echo "Default bridged network already '$NETWORK_NAME'; skipping."
fi
MAC_ADDRESS=${MAC_ADDRESS:-"52:54:00:4b:ab:cd"}

# check if we need to create vm
echo "checking for existing VM '$VM_NAME'..."
VM_EXISTS=$(multipass_cmd list | grep -q "^$VM_NAME\s" && echo true || echo false)

# if vm doesn't exist or VM_REBUILD is true
# create vm
if [ "$VM_EXISTS" = false ] || [ "$VM_REBUILD" = true ]; then

    # if rebuild then delete existing
    if [ "$VM_EXISTS" = true -a "$VM_REBUILD" = true ]; then
        echo "[VM_REBUILD] Deleting existing VM..."
        multipass_cmd delete $VM_NAME --purge
        if [ $? -ne 0 ]; then
            echo "Failed to delete VM."
            exit 1
        fi
    fi

    # Create VM using Multipass
    echo "Creating new VM '$VM_NAME' with the following settings:"
    echo "OS: $VM_OS, CPUs: $VM_CPUS, Memory: $VM_MEMORY, Disk: $VM_DISK, Network: $NETWORK_NAME"
    CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-config.yaml"
    # Multipass on Windows expects a native path, not /c/...
    if [[ "$OS" == "Windows_NT" ]]; then
      CLOUD_INIT_FILE_WIN=$(cygpath -w "$CLOUD_INIT_FILE")
      CLOUD_INIT_ARG="$CLOUD_INIT_FILE_WIN"
    else
      CLOUD_INIT_ARG="$CLOUD_INIT_FILE"
    fi
    cat "$CLOUD_INIT_FILE"
    multipass_cmd launch $VM_OS --name $VM_NAME --cpus $VM_CPUS --memory $VM_MEMORY --disk $VM_DISK --network name=$NETWORK_NAME,mode=manual,mac="$MAC_ADDRESS" --cloud-init "$CLOUD_INIT_ARG"
    if [ $? -ne 0 ]; then
        echo "Failed to create VM. Please ensure Multipass is installed and running."
        exit 1
    fi
fi

# enable privileged mounts
if [[ "$OS" == "Windows_NT" ]]; then
    CURRENT_SETTING=$(multipass_cmd get local.privileged-mounts)
    if [[ "$CURRENT_SETTING" != "true" ]]; then
        echo "Enabling privileged mounts for Windows..."
        multipass_cmd set local.privileged-mounts=true
    fi
fi

# Mount the parent directory to the VM if not already mounted
echo "Checking if parent directory '$PARENT_DIR' is already mounted to VM '$VM_NAME'..."
MOUNT_PATH="/home/ubuntu/netboot"
MOUNT_STR="$VM_NAME:$MOUNT_PATH"

is_mount_present() {

		# if multipass info contains 'Mounts:         --' then no mounts present
		MOUNTS_LINE=$(multipass_cmd info "$VM_NAME" | grep -A 10 "Mounts:")
		if echo "$MOUNTS_LINE" | grep -q "Mounts:[[:space:]]*--"; then
			return 1
		fi
}

if is_mount_present; then
    echo "Parent directory '$PARENT_DIR' is already mounted to VM '$VM_NAME'"
else
    echo "Mounting parent directory '$PARENT_DIR' to VM '$VM_NAME'..."
    if [[ "$OS" == "Windows_NT" ]]; then
      HOST_PARENT=$(cygpath -w "$PARENT_DIR")
    else
      HOST_PARENT="$PARENT_DIR"
    fi
		echo "multipass mount \"$HOST_PARENT\" \"$MOUNT_STR\""
    MOUNT_OUTPUT=$(multipass_cmd mount "$HOST_PARENT" "$MOUNT_STR" 2>&1)
    STATUS=$?
    if [[ $STATUS -eq 0 ]] || [[ "$MOUNT_OUTPUT" == *"is already mounted"* ]]; then
        echo "Parent directory mounted successfully to '$MOUNT_STR'"
    else
        echo "Failed to mount '$MOUNT_STR'!"
				echo "$MOUNT_OUTPUT"
				exit 1
    fi
fi

# check can access network (ICMP only)
echo "checking network"
multipass_cmd exec "$VM_NAME" -- ping -c 1 1.1.1.1
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "Failed to set up networking inside the VM ($EXIT_CODE)"
    exit 1
fi

# echo "Applying hardened dnsmasq config and verifying..."
# multipass_cmd exec "$VM_NAME" -- bash -lc '
#   set -e
#   base=//home/ubuntu/netboot/vm/init
#   chmod +x "$base"/render-dnsmasq.sh "$base"/verify-dns.sh
#   sudo -E DNSMASQ_LAN_IF=eth1 /bin/bash "$base"/render-dnsmasq.sh
#   sudo /bin/bash "$base"/verify-dns.sh
# '
# EXIT_CODE=$?
# if [ $EXIT_CODE -ne 0 ]; then
#     echo "dnsmasq verification failed ($EXIT_CODE)"
#     exit 1
# fi

# Execute the init.sh script inside the VM
echo "Starting docker configuration on VM '$VM_NAME'..."
multipass_cmd exec "$VM_NAME" -- bash -c "chmod +x //home/ubuntu/netboot/vm/init/docker.sh"
multipass_cmd exec "$VM_NAME" --working-directory //home/ubuntu/netboot -- bash //home/ubuntu/netboot/vm/init/docker.sh
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "docker.sh executed successfully inside the VM"
else
    echo "Failed to execute docker.sh inside the VM ( $EXIT_CODE )"
    exit 1
fi

echo "Mounting TFTP share for testing..."
multipass_cmd exec "$VM_NAME" --working-directory //home/ubuntu/netboot -- bash //home/ubuntu/netboot/vm/init/mount-tftp.sh
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "mount-tftp.sh executed successfully inside the VM"
else
    echo "Failed to execute mount-tftp.sh inside the VM ($EXIT_CODE)"
    multipass_cmd exec $VM_NAME --working-directory //home/ubuntu/netboot -- sudo docker compose --profile $COMPOSE_PROFILE logs --follow --tail 100
    exit 1
fi

echo "Mounting NFS share for testing..."
multipass_cmd exec "$VM_NAME" --working-directory //home/ubuntu/netboot -- bash //home/ubuntu/netboot/vm/init/mount-nfs.sh
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "mount-nfs.sh executed successfully inside the VM"
else
    echo "Failed to execute mount-nfs.sh inside the VM ($EXIT_CODE)"
    multipass_cmd exec $VM_NAME --working-directory //home/ubuntu/netboot -- docker compose --profile $COMPOSE_PROFILE logs --follow --tail 100
    exit 1
fi

# print docker logs
multipass_cmd exec $VM_NAME --working-directory //home/ubuntu/netboot -- sudo docker compose --profile $COMPOSE_PROFILE logs --follow --tail 100
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "Failed to get docker logs inside the VM ($EXIT_CODE)"
fi

multipass_cmd shell $VM_NAME
