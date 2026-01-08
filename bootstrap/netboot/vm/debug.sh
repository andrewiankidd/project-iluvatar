#!/bin/bash

echo "====================="
echo "debug.sh"
echo "====================="
uname -a

#############################
#        script vars        #
#############################

# options
export MSYS_NO_PATHCONV=1

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
    multipass "$@"
}

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

echo "======= /etc/dnsmasq.d/proxy-tftp.conf ======="
multipass_cmd exec "$VM_NAME" -- cat /etc/dnsmasq.d/proxy-tftp.conf

echo "======= dnsmasq status and logs ======="
multipass_cmd exec "$VM_NAME" -- bash -lc 'systemctl status dnsmasq --no-pager; echo ===; journalctl -xeu dnsmasq -n 50 --no-pager'

echo "======= dhcpdump ======="
multipass_cmd exec "$VM_NAME" -- sudo dhcpdump -i eth1
