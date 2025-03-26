#!/usr/bin/env bash
#
# A comprehensive script to:
# 1) Install and compile Dante (with PAM) on Ubuntu.
# 2) Configure Dante with PAM-based user auth, forwarding to HAProxy.
# 3) Install and configure HAProxy for round-robin of many SOCKS5 proxies.
# 4) Create a script to dynamically fetch proxies from a GitHub raw list (TheSpeedX) and update HAProxy.
# 5) Schedule a cron job to refresh them every 5 hours.
# 6) Auto-detects the default network interface or uses $DANTE_EXTERNAL_IF or falls back to ens19.

set -e

##############################################
# 0. Determine the external interface
##############################################
if [ -z "$DANTE_EXTERNAL_IF" ]; then
  # Attempt to detect via "ip route get 8.8.8.8"
  DETECTED_IF=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  if [ -n "$DETECTED_IF" ]; then
    DANTE_EXTERNAL_IF="$DETECTED_IF"
    echo "===> Auto-detected interface: $DANTE_EXTERNAL_IF"
  else
    # Fallback if detection fails
    DANTE_EXTERNAL_IF="ens19"
    echo "===> Could not detect interface; defaulting to: $DANTE_EXTERNAL_IF"
  fi
else
  echo "===> Using interface from DANTE_EXTERNAL_IF: $DANTE_EXTERNAL_IF"
fi

##############################################
# 1. Install Required Packages
##############################################
echo "===> Updating apt and installing necessary packages..."
apt-get update -y
apt-get install -y build-essential libpam0g-dev libssl-dev libwrap0-dev \
                   apache2-utils wget tar pkg-config haproxy libpam-pwdfile jq

##############################################
# 2. Download and Compile Dante with PAM
##############################################
DANTE_VERSION="1.4.3"
DANTE_TARBALL="dante-$DANTE_VERSION.tar.gz"

if [ ! -f "$DANTE_TARBALL" ]; then
  echo "===> Downloading Dante source..."
  wget https://www.inet.no/dante/files/$DANTE_TARBALL
fi

if [ ! -d "dante-$DANTE_VERSION" ]; then
  echo "===> Extracting Dante source..."
  tar xvf $DANTE_TARBALL
fi

cd dante-$DANTE_VERSION

echo "===> Configuring Dante..."
./configure --prefix=/usr/local --sysconfdir=/etc --enable-shared=yes
# Dante auto-detects PAM if libpam0g-dev is installed.

echo "===> Compiling Dante..."
make
echo "===> Installing Dante..."
make install

cd ..

##############################################
# 3. Configure PAM for Dante (sockd)
##############################################
echo "===> Setting up /etc/pam.d/sockd with pam_pwdfile..."
cat >/etc/pam.d/sockd <<'EOF'
auth     required  pam_pwdfile.so pwdfile /etc/dante.passwd
account  required  pam_permit.so
EOF

# Create /etc/dante.passwd if it doesn't exist, with an example user
if [ ! -f /etc/dante.passwd ]; then
  echo "===> Creating /etc/dante.passwd with user alice..."
  htpasswd -c -B /etc/dante.passwd alice
  chmod 600 /etc/dante.passwd
  chown root:root /etc/dante.passwd
fi

##############################################
# 4. Create Dante Config /etc/danted.conf
##############################################
echo "===> Writing /etc/danted.conf..."
cat >/etc/danted.conf <<EOF
logoutput: stderr

# Bind Dante on port 1080, listening on all interfaces
internal: 0.0.0.0 port = 1080

# Outbound interface - set to auto-detected or fallback
external: $DANTE_EXTERNAL_IF

# Global auth methods
clientmethod: none
socksmethod: pam.username

# Drop privileges
user.privileged: root
user.notprivileged: nobody
user.libwrap: nobody

# 1) Permit client connections from anywhere (adjust in production).
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

# 2) For SOCKS (and HTTP-CONNECT), require auth via pam.username.
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect bind udpassociate
    log: connect disconnect
    socksmethod: pam.username
}

# 3) Forward all traffic to HAProxy at 127.0.0.1:9999
route {
    from: 0.0.0.0/0  to: 0.0.0.0/0
    via: 127.0.0.1 port = 9999
    protocol: tcp udp
    method: none
}
EOF

##############################################
# 5. Create a Systemd Service for Dante
##############################################
echo "===> Creating /etc/systemd/system/danted.service..."
cat >/etc/systemd/system/danted.service <<'EOF'
[Unit]
Description=Dante SOCKS5 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/sockd -f /etc/danted.conf
User=root
Group=root
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "===> Enabling and starting danted..."
systemctl daemon-reload
systemctl enable danted
systemctl restart danted

##############################################
# 6. Configure HAProxy
##############################################
echo "===> Writing /etc/haproxy/haproxy.cfg..."
cat >/etc/haproxy/haproxy.cfg <<'EOF'
# /etc/haproxy/haproxy.cfg

global
    log /dev/log local0
    log /dev/log local1 notice
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

# Frontend: Listens on 127.0.0.1:9999 for Dante's traffic
frontend socks_in
    bind 127.0.0.1:9999
    mode tcp
    default_backend socks_out

# Backend: Round-robin over multiple SOCKS proxies, with health checks
backend socks_out
    mode tcp
    balance roundrobin
    option tcp-check

    ### Socks proxy list Start
    ### Socks proxy list End
EOF

echo "===> Enabling and starting haproxy..."
systemctl enable haproxy
systemctl restart haproxy

##############################################
# 7. Create Update Script for HAProxy Proxies
##############################################
UPDATE_SCRIPT="/usr/local/bin/update_haproxy_socks.sh"
echo "===> Creating $UPDATE_SCRIPT..."
cat >"$UPDATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
#
# This script fetches a list of SOCKS5 proxies from a GitHub raw list (TheSpeedX)
# then updates the HAProxy "socks_out" backend by inserting "server proxyN"
# lines between the markers:
#
#   ### Socks proxy list Start
#   ### Socks proxy list End
#
# We use round-robin + basic TCP checks, so only healthy proxies remain "UP".
# In case of syntax errors, we restore the last backup.

set -e

# We'll fetch from TheSpeedX repo:
URL="https://raw.githubusercontent.com/TheSpeedX/PROXY-List/refs/heads/master/socks5.txt"

TMPFILE="/tmp/socks5list.txt"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
SERVERLINES="/tmp/haproxy_servers.tmp"

echo "===> Fetching SOCKS5 proxy list from $URL ..."
if ! curl -sS "$URL" > "$TMPFILE"; then
  echo "ERROR: Could not fetch or parse $URL"
  exit 1
fi

if [ ! -s "$TMPFILE" ]; then
  echo "ERROR: The downloaded proxy list is empty."
  exit 1
fi

# Reverse the list so the first line becomes "proxy1" at top
tac "$TMPFILE" > /tmp/tmp_reversed
mv /tmp/tmp_reversed "$TMPFILE"

echo "===> Backing up $HAPROXY_CFG"
BACKUPFILE="${HAPROXY_CFG}.bak.$(date +%F_%T)"
cp -p "$HAPROXY_CFG" "$BACKUPFILE"

echo "===> Removing old proxy lines between markers..."
sed -i '/### Socks proxy list Start/,/### Socks proxy list End/{//!d}' "$HAPROXY_CFG"

echo "===> Building new server lines..."
rm -f "$SERVERLINES"
INDEX=1
while IFS= read -r line; do
  # line is "IP:PORT"
  echo "    server proxy$INDEX $line check inter 10s rise 2 fall 3" >> "$SERVERLINES"
  INDEX=$((INDEX + 1))
done < "$TMPFILE"

echo "===> Inserting new server lines between markers..."
sed -i "/### Socks proxy list Start/r $SERVERLINES" "$HAPROXY_CFG"

echo "===> Checking HAProxy config syntax..."
if ! haproxy -c -f "$HAPROXY_CFG" > /dev/null 2>&1; then
  echo "ERROR: HAProxy config invalid. Restoring backup..."
  cp -p "$BACKUPFILE" "$HAPROXY_CFG"
  exit 1
fi

echo "===> Restarting HAProxy..."
systemctl restart haproxy
echo "Done. Check $HAPROXY_CFG to see the updated server list."
EOF

chmod +x "$UPDATE_SCRIPT"

##############################################
# 8. Create Cron Job to Run Every 5 Hours
##############################################
CRONFILE="/etc/cron.d/update_haproxy_socks"
echo "===> Creating cron entry at $CRONFILE..."
cat >"$CRONFILE" <<EOF
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Run every 5 hours at minute 0
0 */5 * * * root $UPDATE_SCRIPT
EOF

echo "===> Running the proxy update script for the first time..."
/usr/local/bin/update_haproxy_socks.sh || {
  echo "WARNING: The first update script run failed. Check logs or configuration."
}

echo "===> Setup complete!"
echo "    Dante is running on port 1080."
echo "    HAProxy is on 127.0.0.1:9999, forwarding to proxies from TheSpeedX list."
echo "    A cron job refreshes the proxy list every 5 hours."
echo "    If you want a specific interface, run with 'DANTE_EXTERNAL_IF=eth0 bash thisscript.sh' next time."

