#!/bin/bash
# ============================================================
# Asterisk 21 Production Setup for Dograh Cloud (GCP)
# This script compiles Asterisk 21 from source to support 
# externalMedia via WebSockets.
# ============================================================

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "=== Starting Asterisk 21 Source Installation ==="

# 1. Update system
apt-get update -y
apt-get upgrade -y

# 2. Remove existing Asterisk (if any)
echo ">> Removing existing Asterisk..."
systemctl stop asterisk || true
apt-get purge -y asterisk asterisk-config || true
apt-get autoremove -y || true

# 3. Install build dependencies
echo ">> Installing build dependencies..."
apt-get install -y build-essential git wget libedit-dev libsqlite3-dev uuid-dev \
    libjansson-dev libxml2-dev libssl-dev libncurses5-dev libnewt-dev \
    libcurl4-openssl-dev libspeex-dev libspeexdsp-dev libgsm1-dev libopus-dev \
    pkg-config python3-dev python3-pip python3-setuptools

# 4. Download Asterisk 21 source
echo ">> Downloading Asterisk 21..."
cd /usr/src
rm -rf asterisk-21*
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz
tar -zxvf asterisk-21-current.tar.gz
cd asterisk-21.*/

# 5. Install more dependencies using the install_prereq script
echo ">> Installing prerequisites..."
yes | ./contrib/scripts/install_prereq install

# 6. Configure Asterisk with bundled PJSIP (critical for stability)
echo ">> Configuring Asterisk..."
./configure --with-pjproject-bundled --with-jansson-bundled

# 7. Compile and Install
echo ">> Compiling Asterisk (this may take 10-20 minutes)..."
make -j$(nproc)
make install
make samples
make config
ldconfig

# 8. Setup dograh configuration
echo ">> Applying Dograh configurations..."
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "34.93.63.150")

# HTTP config
cat > /etc/asterisk/http.conf << 'EOF'
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
prefix=
enablestatic=yes
EOF

# ARI config
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

# PJSIP config
cat > /etc/asterisk/pjsip.conf << EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=$PUBLIC_IP
external_signaling_address=$PUBLIC_IP

; ---- Vobiz Trunk ----
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

# Dialplan
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

# WebSocket Client
cat > /etc/asterisk/websocket_client.conf << 'EOF'
[general]

[dograh]
type=websocket_client
uri=wss://services.dograh.com/api/v1/telephony/ws/ari
protocols=media
EOF

# Modules
cat > /etc/asterisk/modules.conf << 'EOF'
[modules]
autoload=yes
load => chan_pjsip.so
load => res_pjsip.so
load => chan_websocket.so
load => res_ari_external_media.so
noload => pbx_ael.so
noload => pbx_lua.so
EOF

# 9. Start Asterisk
echo ">> Starting Asterisk 21..."
systemctl daemon-reload
systemctl enable asterisk
systemctl start asterisk

echo ""
echo "=== Asterisk 21 Setup Complete ==="
echo "Version:"
asterisk -rx "core show version"
echo ""
echo "Check if WebSocket and externalMedia modules are loaded:"
asterisk -rx "module show like chan_websocket"
asterisk -rx "module show like external_media"
