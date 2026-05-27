#!/bin/bash
# ============================================================
# Asterisk Setup Script for Dograh Cloud - GCP Ubuntu 24.04
# Run this as root in your GCP VM terminal
# ============================================================

set -e
echo "=== Starting Asterisk Setup for Dograh Cloud ==="

# 1. Update system
echo ">> Updating system..."
apt-get update -y
apt-get upgrade -y

# 2. Install Asterisk
echo ">> Installing Asterisk..."
# NOTE: Standard Ubuntu 24.04 provides Asterisk 20.6.0.
# Dograh requires Asterisk 20.16.0+, 21.11.0+, or 22.6.0+ for externalMedia WebSocket transport.
# If you encounter "501 Not Implemented" errors, please consider:
# 1. Using the official Dograh Docker setup (which uses andrius/asterisk:latest)
# 2. Compiling Asterisk 21 from source on this VM.
apt-get install -y asterisk asterisk-config uuid-runtime curl

# 3. Configure ARI HTTP server
echo ">> Configuring ARI..."
cat > /etc/asterisk/http.conf << 'EOF'
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
prefix=
enablestatic=yes
EOF

# 4. Configure ARI user
cat > /etc/asterisk/ari.conf << 'EOF'
[general]
enabled=yes
pretty=yes
allowed_origins=*

[dograh]
type=user
password=dograh_secure_password
password_format=plain
EOF
# 5. Configure PJSIP (Vobiz Trunk)
echo ">> Configuring PJSIP..."
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "CHANGE_ME")

cat > /etc/asterisk/pjsip.conf << EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=$PUBLIC_IP
external_signaling_address=$PUBLIC_IP

; ---- Vobiz Registration ----
[vobiz-reg]
type=registration
transport=transport-udp
outbound_auth=vobiz-auth
server_uri=sip:registrar.vobiz.ai
client_uri=sip:dailsmart9645796928677572109@registrar.vobiz.ai
retry_interval=60
expiration=3600

[vobiz-auth]
type=auth
auth_type=userpass
username=dailsmart9645796928677572109
password=Reddy@7989

[vobiz-aor]
type=aor
contact=sip:registrar.vobiz.ai

[vobiz-endpoint]
type=endpoint
transport=transport-udp
context=from-external
disallow=all
allow=ulaw,alaw
outbound_auth=vobiz-auth
aors=vobiz-aor
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
send_rpid=yes
send_pai=yes
from_user=918065481144
from_domain=registrar.vobiz.ai

[vobiz-identify]
type=identify
endpoint=vobiz-endpoint
match=registrar.vobiz.ai

; ---- Outbound SIP Trunk (pace college) ----
[vobiz-trunk-auth]
type=auth
auth_type=userpass
username=dailsmart
password=Reddy@7989

[vobiz-trunk-aor]
type=aor
contact=sip:455bdb01.sip.vobiz.ai

[vobiz-trunk]
type=endpoint
transport=transport-udp
context=from-external
disallow=all
allow=ulaw,alaw
outbound_auth=vobiz-trunk-auth
aors=vobiz-trunk-aor
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
send_rpid=yes
send_pai=yes
from_user=918065481144
from_domain=455bdb01.sip.vobiz.ai
EOF


# 6. Configure Dialplan
cat > /etc/asterisk/extensions.conf << 'EOF'
[general]
static=yes
writeprotect=no

[from-external]
exten => _X.,1,NoOp(Incoming call to ${EXTEN})
exten => _X.,n,Stasis(dograh)
exten => _X.,n,Hangup()

[default]
exten => s,1,Stasis(dograh)
exten => s,n,Hangup()
EOF

# 7. Configure RTP ports
cat > /etc/asterisk/rtp.conf << 'EOF'
[general]
rtpstart=10000
rtpend=20000
EOF

# 8. Configure WebSocket Client
cat > /etc/asterisk/websocket_client.conf << 'EOF'
[general]

[dograh]
type=websocket_client
uri=wss://services.dograh.com/api/v1/telephony/ws/ari
protocols=media
EOF

# 9. Enable required modules
cat > /etc/asterisk/modules.conf << 'EOF'
[modules]
autoload=yes
noload=pbx_ael.so
noload=pbx_lua.so
EOF

# 10. Enable Asterisk service
systemctl enable asterisk
systemctl restart asterisk
sleep 3

# 11. Check status
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Asterisk Status:"
systemctl is-active asterisk

echo ""
echo "Vobiz Registration:"
asterisk -rx "pjsip show registrations" 2>/dev/null || echo "Asterisk starting up..."

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "34.93.63.150")
echo ""
echo "============================================"
echo "  YOUR DOGRAH CLOUD SETTINGS:"
echo "============================================"
echo "  ARI base URL:      http://$PUBLIC_IP:8088"
echo "  App name:          dograh"
echo "  WebSocket name:    dograh"
echo "  App password:      dograh_secure_password"
echo "============================================"
