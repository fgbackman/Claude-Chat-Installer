#!/bin/bash
# Double-click to build, install and launch Claude Chat.
cd "$(dirname "$0")" && bash ./install.sh
echo ""
read -n 1 -s -r -p "Press any key to close this window."
