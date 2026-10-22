#!/bin/bash
# Double-click to remove Claude Chat.
cd "$(dirname "$0")" && bash ./uninstall.sh
echo ""
read -n 1 -s -r -p "Press any key to close this window."
