#!/bin/sh
set -eu
pkill -x Downmix51 2>/dev/null || true
rm -rf /Applications/Downmix51.app
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Downmix51.driver
sudo killall coreaudiod || true
echo "Removed Downmix51 driver and app."
