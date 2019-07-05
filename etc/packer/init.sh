#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get -yq update
apt-get -yq upgrade
apt-get -yq install chrony
id -u stressgrid &>/dev/null || useradd -r stressgrid
mkdir -p /opt/stressgrid/$RELEASE
chown stressgrid:stressgrid /opt/stressgrid/$RELEASE
cd /opt/stressgrid/$RELEASE
sudo -u stressgrid tar -xvf /tmp/release.tar.gz &>/dev/null
rm /tmp/release.tar.gz
echo "
net.ipv4.ip_local_port_range=15000 65000
" > /etc/sysctl.d/10-stressgrid-$RELEASE.conf
sysctl -p /etc/sysctl.d/10-stressgrid-$RELEASE.conf
echo "[Unit]
Description=Stressgrid $RELEASE
After=network.target

[Service]
WorkingDirectory=/opt/stressgrid/$RELEASE
Environment=HOME=/opt/stressgrid/$RELEASE
EnvironmentFile=/etc/default/stressgrid-$RELEASE.env
ExecStart=/opt/stressgrid/$RELEASE/bin/$RELEASE daemon
ExecStop=/opt/stressgrid/$RELEASE/bin/$RELEASE stop
User=stressgrid
RemainAfterExit=yes
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/stressgrid-$RELEASE.service
echo "" > /etc/default/stressgrid-$RELEASE.env
systemctl daemon-reload
systemctl enable stressgrid-$RELEASE
