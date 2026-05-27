#!/bin/bash
# ==============================================================================
# Add Vobiz Phone Number / SIP Registration to Asterisk
# This script adds a new Vobiz registration and authentication to pjsip.conf
# and restarts Asterisk to apply the configuration.
# ==============================================================================

set -e

# Path to the live pjsip.conf on VM
PJSIP_CONF="/opt/asterisk/asterisk_config/pjsip.conf"

show_help() {
    echo "Usage:"
    echo "  $0 <phone_number> <sip_username> <sip_password>"
    echo ""
    echo "Example:"
    echo "  $0 918065481145 dailsmart9645796928677572109 Reddy@7989"
    echo ""
    echo "This will register the number for inbound calls and configure outbound dialing."
}

if [ "$#" -ne 3 ]; then
    show_help
    exit 1
fi

NUMBER=$(echo "$1" | tr -d '+ ')
USERNAME="$2"
PASSWORD="$3"

# Validate inputs
if [[ ! "$NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: Phone number must be digits only."
    exit 1
fi

echo "=== Adding Vobiz Number: $NUMBER ==="

# 1. Back up current configuration
if [ -f "$PJSIP_CONF" ]; then
    echo ">> Backing up $PJSIP_CONF to $PJSIP_CONF.bak"
    sudo cp "$PJSIP_CONF" "$PJSIP_CONF.bak"
else
    echo "Error: Configuration file $PJSIP_CONF not found."
    exit 1
fi

# 2. Check if registration already exists
if grep -q "\[vobiz-reg-$NUMBER\]" "$PJSIP_CONF"; then
    echo ">> Registration block [vobiz-reg-$NUMBER] already exists. Updating..."
    # We will remove the old block and its auth block first to prevent duplicates
    sudo sed -i "/\[vobiz-reg-$NUMBER\]/,/^$/d" "$PJSIP_CONF"
    sudo sed -i "/\[vobiz-auth-$NUMBER\]/,/^$/d" "$PJSIP_CONF"
fi

# 3. Append new registration block to pjsip.conf
echo ">> Appending configuration to pjsip.conf..."
sudo tee -a "$PJSIP_CONF" > /dev/null <<EOF

; ---- Registration for Vobiz Number $NUMBER ----
[vobiz-reg-$NUMBER]
type = registration
transport = transport-udp
outbound_auth = vobiz-auth-$NUMBER
server_uri = sip:registrar.vobiz.ai
client_uri = sip:$USERNAME@registrar.vobiz.ai
retry_interval = 60
expiration = 3600

[vobiz-auth-$NUMBER]
type = auth
auth_type = userpass
username = $USERNAME
password = $PASSWORD

EOF

# 4. Remove 'from_user' from the main vobiz-trunk to allow dynamic outbound caller ID
echo ">> Ensuring vobiz-trunk has dynamic caller ID support (omitting static from_user)..."
sudo sed -i 's/^from_user =/# from_user =/g' "$PJSIP_CONF"

# 5. Correct file permissions
sudo chmod 644 "$PJSIP_CONF"

# 6. Restart Asterisk
echo ">> Restarting Asterisk Docker container..."
sudo docker restart asterisk

# 7. Wait and check registrations
echo ">> Waiting 5 seconds for registrations to update..."
sleep 5
echo ""
echo "=== Active Registrations ==="
sudo docker exec asterisk asterisk -rx "pjsip show registrations"
echo "============================"
echo "✅ Number $NUMBER registered successfully!"
