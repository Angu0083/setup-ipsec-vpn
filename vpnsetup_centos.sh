#!/bin/sh
#
# Script for automatic configuration of IPsec/L2TP VPN server on 64-bit CentOS/RHEL 6 & 7.
# Works on dedicated servers or any KVM- or XEN-based Virtual Private Server (VPS).
# It can also be used as the Amazon EC2 "user-data" with the official CentOS 6 and 7 AMIs.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC! THIS IS MEANT TO BE RUN
# ON YOUR DEDICATED SERVER OR VPS!
#
# Copyright (C) 2015 Lin Song
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0 
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it! 

if [ "$(uname)" = "Darwin" ]; then
  echo 'DO NOT run this script on your Mac! It should only be run on a Dedicated Server / VPS'
  echo 'or a newly-created EC2 instance, after you have modified it to set the variables below.'
  exit 1
fi

# Please define your own values for these variables
# Escape *all* non-alphanumeric characters with a backslash (or 3 backslashes for \ and ").
# Examples: \ --> \\\\, " --> \\\", ' --> \', $ --> \$, ` --> \`, [space] --> \[space]

IPSEC_PSK=your_very_secure_key
VPN_USER=your_username
VPN_PASSWORD=your_very_secure_password

# -----------------
#  IMPORTANT NOTES
# -----------------

# To support multiple VPN users with different credentials, just edit a few lines below.
# See: https://gist.github.com/hwdsl2/123b886f29f4c689f531

# For **Windows users**, a one-time registry change is required if the VPN server
# and/or client is behind NAT (e.g. home router). Refer to "Error 809" on this page:
# https://documentation.meraki.com/MX-Z/Client_VPN/Troubleshooting_Client_VPN#Windows_Error_809

# **Android 6.0 users**: Edit /etc/ipsec.conf and append ",aes256-sha2_256" to the end of
# both "ike=" and "phase2alg=", then add a new line "sha2-truncbug=yes". Must start lines
# with two spaces. Finally, run "service ipsec restart".

# **iPhone/iOS users**: In iOS settings, choose L2TP (instead of IPSec) for the VPN type.
# In case you're unable to connect, try replacing this line in /etc/ipsec.conf:
# "rightprotoport=17/%any" with "rightprotoport=17/0". Then restart "ipsec" service.

# Clients are configured to use "Google Public DNS" when the VPN connection is active.
# This setting is controlled by "ms-dns" in /etc/ppp/options.xl2tpd.

# If using Amazon EC2, these ports must be open in the instance's security group:
# UDP ports 500 & 4500 (for the VPN), and TCP port 22 (optional, for SSH).

# If your server uses a custom SSH port (not 22), or if you wish to allow other services
# through IPTables, be sure to edit the IPTables rules below before running this script.

# This script will backup your existing configuration files before overwriting them.
# Backups can be found in the same folder as the original, with .old-date/time suffix.

if [ ! -f /etc/redhat-release ]; then
  echo "Looks like you aren't running this script on a CentOS/RHEL system."
  exit 1
fi

if ! grep -qs -e "release 6" -e "release 7" /etc/redhat-release; then
  echo "Sorry, this script only supports versions 6 and 7 of CentOS/RHEL."
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "Sorry, this script only supports 64-bit CentOS/RHEL."
  exit 1
fi

if [ -f "/proc/user_beancounters" ]; then
  echo "Sorry, this script does NOT support OpenVZ VPS. Try Nyr's OpenVPN script instead:"
  echo "https://github.com/Nyr/openvpn-install"
  exit 1
fi

if [ "$(id -u)" != 0 ]; then
  echo "Sorry, you need to run this script as root."
  exit 1
fi

# Check for empty VPN variables
[ -z "$IPSEC_PSK" ] && { echo "'IPSEC_PSK' cannot be empty. Please edit the VPN script."; exit 1; }
[ -z "$VPN_USER" ] && { echo "'VPN_USER' cannot be empty. Please edit the VPN script."; exit 1; }
[ -z "$VPN_PASSWORD" ] && { echo "'VPN_PASSWORD' cannot be empty. Please edit the VPN script."; exit 1; }

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || { echo "Failed to change working directory to /opt/src. Aborting."; exit 1; }

# Install wget, dig (bind-utils) and nano
yum -y install wget bind-utils nano

echo
echo 'Please wait... Trying to find Public IP and Private IP of this server.'
echo
echo 'If the script hangs here for more than a few minutes, press Ctrl-C to interrupt,'
echo 'then edit it and comment out the next two lines PUBLIC_IP= and PRIVATE_IP= ,'
echo 'OR replace them with the actual IPs. If your server only has a public IP,'
echo 'put that public IP on both lines.'
echo

# In Amazon EC2, these two variables will be found automatically.
# For all other servers, you may replace them with the actual IPs,
# or comment out and let the script auto-detect in the next section.
# If your server only has a public IP, put that public IP on both lines.
PUBLIC_IP=$(wget --retry-connrefused -t 3 -T 15 -qO- 'http://169.254.169.254/latest/meta-data/public-ipv4')
PRIVATE_IP=$(wget --retry-connrefused -t 3 -T 15 -qO- 'http://169.254.169.254/latest/meta-data/local-ipv4')

# Attempt to find server IPs automatically for non-EC2 servers
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipecho.net/plain)
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(ip -4 route get 1 | awk '{print $NF;exit}')
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')

# Check public/private IPs for correct format
IP_REGEX="^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
if printf %s "$PUBLIC_IP" | grep -vEq "$IP_REGEX"; then
  echo "Could not find valid Public IP, please edit the VPN script manually."
  exit 1
fi
if printf %s "$PRIVATE_IP" | grep -vEq "$IP_REGEX"; then
  echo "Could not find valid Private IP, please edit the VPN script manually."
  exit 1
fi

# Add the EPEL repository
if grep -qs "release 6" /etc/redhat-release; then
  EPEL_RPM="epel-release-6-8.noarch.rpm"
  EPEL_URL="http://download.fedoraproject.org/pub/epel/6/x86_64/$EPEL_RPM"
elif grep -qs "release 7" /etc/redhat-release; then
  EPEL_RPM="epel-release-7-5.noarch.rpm"
  EPEL_URL="http://download.fedoraproject.org/pub/epel/7/x86_64/e/$EPEL_RPM"
else
  echo "Sorry, this script only supports versions 6 and 7 of CentOS/RHEL."
  exit 1
fi
wget -t 3 -T 30 -nv -O "$EPEL_RPM" "$EPEL_URL"
[ ! -f "$EPEL_RPM" ] && { echo "Could not retrieve EPEL repository RPM file. Aborting."; exit 1; }
rpm -ivh --force "$EPEL_RPM" && /bin/rm -f "$EPEL_RPM"

# Install necessary packages
yum -y install nss-devel nspr-devel pkgconfig pam-devel \
    libcap-ng-devel libselinux-devel \
    curl-devel gmp-devel flex bison gcc make \
    fipscheck-devel unbound-devel gmp gmp-devel xmlto
yum -y install ppp xl2tpd

# Install Fail2Ban to protect SSH server
yum -y install fail2ban

# Install IP6Tables for CentOS/RHEL 6
if grep -qs "release 6" /etc/redhat-release; then
  yum -y install iptables-ipv6
fi

# Installed Libevent2. Use backported version for CentOS 6.
if grep -qs "release 6" /etc/redhat-release; then
  LE2_URL="https://people.redhat.com/pwouters/libreswan-rhel6"
  RPM1="libevent2-2.0.21-1.el6.x86_64.rpm"
  RPM2="libevent2-devel-2.0.21-1.el6.x86_64.rpm"
  wget -t 3 -T 30 -nv -O "$RPM1" "$LE2_URL/$RPM1"
  wget -t 3 -T 30 -nv -O "$RPM2" "$LE2_URL/$RPM2"
  [ ! -f "$RPM1" ] || [ ! -f "$RPM2" ] && { echo "Could not retrieve Libevent2 RPM file(s). Aborting."; exit 1; }
  rpm -ivh --force "$RPM1" "$RPM2" && /bin/rm -f "$RPM1" "$RPM2"
elif grep -qs "release 7" /etc/redhat-release; then
  yum -y install libevent-devel
fi

# Compile and install Libreswan (https://libreswan.org/)
SWAN_VER=3.16
SWAN_FILE="libreswan-${SWAN_VER}.tar.gz"
SWAN_URL="https://download.libreswan.org/${SWAN_FILE}"
wget -t 3 -T 30 -nv -O "$SWAN_FILE" "$SWAN_URL"
[ ! -f "$SWAN_FILE" ] && { echo "Could not retrieve Libreswan source file. Aborting."; exit 1; }
/bin/rm -rf "/opt/src/libreswan-${SWAN_VER}"
tar xvzf "$SWAN_FILE" && rm -f "$SWAN_FILE"
cd "libreswan-${SWAN_VER}" || { echo "Failed to enter Libreswan source directory. Aborting."; exit 1; }
make programs && make install

# Prepare various config files
/bin/cp -f /etc/ipsec.conf "/etc/ipsec.conf.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
  dumpdir=/var/run/pluto/
  nat_traversal=yes
  virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!192.168.42.0/24
  oe=off
  protostack=netkey
  nhelpers=0
  interfaces=%defaultroute

conn vpnpsk
  connaddrfamily=ipv4
  auto=add
  left=$PRIVATE_IP
  leftid=$PUBLIC_IP
  leftsubnet=$PRIVATE_IP/32
  leftnexthop=%defaultroute
  leftprotoport=17/1701
  rightprotoport=17/%any
  right=%any
  rightsubnetwithin=0.0.0.0/0
  forceencaps=yes
  authby=secret
  pfs=no
  type=transport
  auth=esp
  ike=3des-sha1,aes-sha1
  phase2alg=3des-sha1,aes-sha1
  rekey=no
  keyingtries=5
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
EOF

/bin/cp -f /etc/ipsec.secrets "/etc/ipsec.secrets.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat > /etc/ipsec.secrets <<EOF
$PUBLIC_IP  %any  : PSK "$IPSEC_PSK"
EOF

/bin/cp -f /etc/xl2tpd/xl2tpd.conf "/etc/xl2tpd/xl2tpd.conf.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

;debug avp = yes
;debug network = yes
;debug state = yes
;debug tunnel = yes

[lns default]
ip range = 192.168.42.10-192.168.42.250
local ip = 192.168.42.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
;ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

/bin/cp -f /etc/ppp/options.xl2tpd "/etc/ppp/options.xl2tpd.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
crtscts
idle 1800
mtu 1280
mru 1280
lock
lcp-echo-failure 10
lcp-echo-interval 60
connect-delay 5000
EOF

/bin/cp -f /etc/ppp/chap-secrets "/etc/ppp/chap-secrets.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null

cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client  server  secret  IP addresses
"$VPN_USER" l2tpd "$VPN_PASSWORD" *
EOF

if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then

/bin/cp -f /etc/sysctl.conf "/etc/sysctl.conf.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat >> /etc/sysctl.conf <<EOF

# Added by hwdsl2 VPN script
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = 68719476736
kernel.shmall = 4294967296
kernel.randomize_va_space = 1

net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.lo.send_redirects = 0
net.ipv4.conf.eth0.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF

fi

if ! grep -qs "hwdsl2 VPN script" /etc/sysconfig/iptables; then

/bin/cp -f /etc/sysconfig/iptables "/etc/sysconfig/iptables.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
/sbin/service fail2ban stop >/dev/null 2>&1
if [ "$(/sbin/iptables-save | grep -c '^\-')" = "0" ]; then

cat > /etc/sysconfig/iptables <<EOF
# Added by hwdsl2 VPN script
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:ICMPALL - [0:0]
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -d 127.0.0.0/8 -j REJECT
-A INPUT -p icmp --icmp-type 255 -j ICMPALL
-A INPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
-A INPUT -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
-A INPUT -p udp --dport 1701 -j DROP
-A INPUT -j DROP
-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -i eth+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i ppp+ -o eth+ -j ACCEPT
# If you wish to allow traffic between VPN clients themselves, uncomment this line:
# -A FORWARD -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j ACCEPT
-A FORWARD -j DROP
-A ICMPALL -p icmp -f -j DROP
-A ICMPALL -p icmp --icmp-type 0 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 3 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 4 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 8 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 11 -j ACCEPT
-A ICMPALL -p icmp -j DROP
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 192.168.42.0/24 -o eth+ -j SNAT --to-source "${PRIVATE_IP}"
COMMIT
EOF

else

iptables -I INPUT 1 -p udp -m multiport --dports 500,4500 -j ACCEPT
iptables -I INPUT 2 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
iptables -I INPUT 3 -p udp --dport 1701 -j DROP

iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
iptables -I FORWARD 2 -i eth+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 3 -i ppp+ -o eth+ -j ACCEPT
# If you wish to allow traffic between VPN clients themselves, uncomment this line:
# iptables -I FORWARD 4 -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j ACCEPT
iptables -A FORWARD -j DROP

iptables -t nat -I POSTROUTING -s 192.168.42.0/24 -o eth+ -j SNAT --to-source "${PRIVATE_IP}"

/sbin/iptables-save > /etc/sysconfig/iptables
echo "# Modified by hwdsl2 VPN script" >> /etc/sysconfig/iptables

fi
fi

if ! grep -qs "hwdsl2 VPN script" /etc/sysconfig/ip6tables; then

/bin/cp -f /etc/sysconfig/ip6tables "/etc/sysconfig/ip6tables.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat > /etc/sysconfig/ip6tables <<EOF
# Added by hwdsl2 VPN script
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m rt --rt-type 0 -j DROP
-A INPUT -s fe80::/10 -j ACCEPT
-A INPUT -p ipv6-icmp -j ACCEPT
-A INPUT -j DROP
COMMIT
EOF

fi

if [ ! -f /etc/fail2ban/jail.local ] ; then

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 600
findtime  = 600
maxretry = 5
backend = auto

[ssh-iptables]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=ssh, protocol=tcp]
logpath  = /var/log/secure
EOF

fi

if ! grep -qs "hwdsl2 VPN script" /etc/rc.local; then

/bin/cp -f /etc/rc.local "/etc/rc.local.old-$(date +%Y-%m-%d-%H:%M:%S)" 2>/dev/null
cat >> /etc/rc.local <<EOF

# Added by hwdsl2 VPN script
/sbin/iptables-restore < /etc/sysconfig/iptables
/sbin/ip6tables-restore < /etc/sysconfig/ip6tables
/sbin/service fail2ban restart
/sbin/service ipsec start
/sbin/service xl2tpd start
echo 1 > /proc/sys/net/ipv4/ip_forward
EOF

fi

if [ ! -f /etc/ipsec.d/cert8.db ] ; then
   echo > /var/tmp/libreswan-nss-pwd
   /usr/bin/certutil -N -f /var/tmp/libreswan-nss-pwd -d /etc/ipsec.d
   /bin/rm -f /var/tmp/libreswan-nss-pwd
fi

# Restore SELinux contexts
restorecon /etc/ipsec.d/*db 2>/dev/null
restorecon /usr/local/sbin -Rv 2>/dev/null
restorecon /usr/local/libexec/ipsec -Rv 2>/dev/null

/sbin/sysctl -p
/bin/chmod +x /etc/rc.local
/bin/chmod 600 /etc/ipsec.secrets* /etc/ppp/chap-secrets*

/sbin/iptables-restore < /etc/sysconfig/iptables
/sbin/ip6tables-restore < /etc/sysconfig/ip6tables

/sbin/service fail2ban stop >/dev/null 2>&1
/sbin/service ipsec stop >/dev/null 2>&1
/sbin/service xl2tpd stop >/dev/null 2>&1

/sbin/service fail2ban start
/sbin/service ipsec start
/sbin/service xl2tpd start