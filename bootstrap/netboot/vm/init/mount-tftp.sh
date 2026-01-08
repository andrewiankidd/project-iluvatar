#!/bin/bash

echo "====================="
echo "mount-tftp.sh"
echo "====================="
uname -a
lsb_release -a

# TFTP server and configuration
TFTP_SERVER="localhost"
TFTP_DIR="/tftpboot"
TFTP_MOUNT_POINT="/tmp"  # Mount point for TFTP
TEST_FILE="test.txt"

# Create the mount point if it doesn't exist
if [ ! -d "${TFTP_MOUNT_POINT}" ]; then
  echo "Creating directory for TFTP at ${TFTP_MOUNT_POINT}..."
  sudo mkdir -p "${TFTP_MOUNT_POINT}"
fi

# if already exists, remove the test file
if [ -f "${TFTP_MOUNT_POINT}/$TEST_FILE" ]; then
    rm "${TFTP_MOUNT_POINT}/$TEST_FILE"
fi

# Use TFTP client to fetch a file as a test
echo "Testing TFTP connection..."
tftp -v ${TFTP_SERVER} -c get $TEST_FILE ${TFTP_MOUNT_POINT}/$TEST_FILE

# Check if the TFTP operation was successful and the file is not empty
if [ -f "${TFTP_MOUNT_POINT}/$TEST_FILE" ] && [ -s "${TFTP_MOUNT_POINT}/$TEST_FILE" ]; then
    echo "TFTP file transfer successful, file saved to ${TFTP_MOUNT_POINT}/$TEST_FILE."
    cat "${TFTP_MOUNT_POINT}/$TEST_FILE"
else
    echo "Failed to transfer file from TFTP server or the file is empty. Please check the configuration."
    exit 1
fi
