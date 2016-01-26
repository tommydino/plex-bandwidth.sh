## All credit goes to this thread https://forums.plex.tv/discussion/39823/howto-limit-plex-media-server-bandwidth-on-linux



cat << EOF > /usr/local/bin/plex-traffic-shape
#!/bin/sh
# Setup Traffic Control to limit outgoing bandwidth
# Sourced from:
#   * http://www.cyberciti.biz/faq/linux-traffic-shaping-using-tc-to-control-http-traffic
#   * https://forums.plex.tv/index.php/topic/39823-howto-limit-plex-media-server-bandwidth-on-linux/?p=466013
#   * http://serverfault.com/questions/174010/limit-network-bandwith-for-an-ip
#   * http://luxik.cdi.cz/~devik/qos/htb/manual/userg.htm
#
# Ensure that the sch_htb module is available.
# For very high rates, you may need to adjust the quantum values. See: http://mailman.ds9a.nl/pipermail/lartc/2003q1/007508.html

usage() {
  echo "\$0 ifdev rate maxrate ipblock"
  echo -e "\tifdev is usually eth0"
  echo -e "\trate and maxrate are a rate accepted by tc (e.g. 500kbit, 1mbit)"
  echo -e "\tipblock is a IP block per iptables syntax (e.g. 192.168.1.0/24"
  exit 1
}

IFDEV=\$1
RATE=\$2
MAXRATE=\$3
R2Q=\$4
IPBLOCK=\$5

if [ -z \$IFDEV ] || [ -z \$RATE ] || [ -z \$MAXRATE ] || [ -z \$R2Q ] || [ -z \$IPBLOCK ];then
  usage;
fi

### Modules
modprobe sch_htb

### Sleep for a second
sleep 1

### Delete all TC rules for \$IFDEV
/sbin/tc qdisc del dev \$IFDEV root 2> /dev/null || /bin/true

### Delete the iptables mangle rule if it exists
/sbin/iptables -D OUTPUT -t mangle -p tcp --sport 32400 ! --dst "\$IPBLOCK" -j MARK --set-mark 10  2> /dev/null || /bin/true

### Activate queueing discipline
/sbin/tc qdisc add dev \$IFDEV root handle 1: htb default 20 r2q "\$R2Q"

### Define class with limited allowed bandwidth

/sbin/tc class add dev \$IFDEV parent 1: classid 1:1 htb rate "\$MAXRATE" ceil "\$MAXRATE"
/sbin/tc class add dev \$IFDEV parent 1:1 classid 1:10 htb rate "\$RATE" ceil "\$MAXRATE"
 
### Send packets in round-robin if we have too many clients and too little BW
/sbin/tc qdisc add dev \$IFDEV parent 1:10 handle 100: sfq perturb 10
 
### Create iptables mangle rule for outgoing port 32400 (Plex Media Server)
/sbin/iptables -A OUTPUT -t mangle -p tcp --sport 32400 ! --dst "\$IPBLOCK" -j MARK --set-mark 10
 
### Assign the rule to the proper qdisc
/sbin/tc filter add dev \$IFDEV parent 1: prio 3 protocol all handle 10 fw flowid 1:10
 
### Notes
## Source variables
# . /etc/sysconfig/plex-traffic-shape
## show TC rules
# /sbin/tc -s -d class show dev \$IFDEV
## Show iptables mangle rules
# /sbin/iptables -t mangle -n -v -L
## Show actual bandwidth being used on 32400
# watch -n 1 /sbin/tc -s -d class show dev \$IFDEV
EOF

chmod +x /usr/local/bin/plex-traffic-shape

cat << EOF > /etc/sysconfig/plex-traffic-shape
# Interface to enable traffic shaping on.
IFDEV="enp3s0"

# Define your "fair-share" rate and maximum uplink for Plex.
# Valid suffixes:
# kbit - kilobits/s;
# mbit - megabits/s;
# kbps - kilobytes/s;
# mbps - megabytes/s;
RATE="50mbit"
MAXRATE="60mbit"

# The rates above converted to bytes/s divided by this number should fall
# anywhere between 1500 and 60,000. It's used to evenly distribute surplus
# bandwith: http://www.docum.org/faq/cache/31.html
R2Q=220

# Your local IP block to exclude from traffic shaping. To disable traffic
# shaping exclusion (i.e., to enable it on your LAN as well) enter '127.0.0.1'
# as-is with no subnet modifier.
IPBLOCK="192.168.1.0/24"

EOF

cat << EOF > /etc/systemd/system/plex-traffic-shape.service
[Unit]
Description=Starts traffic shaping for Plex Media Server
After=plexmediaserver.target
 
[Service]
EnvironmentFile=-/etc/sysconfig/plex-traffic-shape
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/local/bin/plex-traffic-shape $IFDEV $RATE $MAXRATE $R2Q $IPBLOCK
 
[Install]
WantedBy=multi-user.target
EOF
 
systemctl daemon-reload
systemctl enable plex-traffic-shape