#!/bin/bash
# Shorthand script to launch CS2 and connect to a server in spectator mode
# Usage: ./connect-cs2.sh <server-ip:port>
# Example: ./connect-cs2.sh 10.0.2.222:27015

if [ -z "$1" ]; then
    echo "Usage: $0 <server-ip:port>"
    echo "Example: $0 10.0.2.222:27015"
    exit 1
fi

SERVER_ADDR="$1"

# Launch CS2 via Steam with spectator connection
steam -silent -no-browser -nochatui -skipinitialbootstrap -console -applaunch 730 +connect_tv "$SERVER_ADDR"

echo "Launched CS2 and connecting to spectator server: $SERVER_ADDR"


