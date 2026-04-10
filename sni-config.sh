#!/bin/bash
# Central SNI configuration — edit here to rotate mirror servers.
# Sourced by setup-eu-exit.sh, setup-ru-bridge.sh, and setup-monitoring.sh.

# EU exit inbound SNIs (matched per port)
SNI_1="debian.snt.utwente.nl"         # EU port 443
SNI_2="nl.archive.ubuntu.com"          # EU port 8443
SNI_3="eclipse.mirror.liteserver.nl"   # EU port 9443

# RU bridge inbound SNI
LOCAL_SNI="vkvideo.ru"

# Ports (rarely need changing)
PORT_1=443
PORT_2=8443
PORT_3=9443
