#!/bin/bash
set -eu

project_dir="$(cd "$(dirname "$0")" && pwd)"
guard_target="/usr/local/bin/clash-verge-guarded"
override_dir="/etc/systemd/system/clash-verge-service.service.d"
applications_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
autostart_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/autostart"

sudo install -m 0755 "$project_dir/bin/clash-verge-guarded" "$guard_target"
sudo install -d -m 0755 "$override_dir"
sudo install -m 0644 "$project_dir/systemd/exit-with-ui.conf" "$override_dir/exit-with-ui.conf"
sudo systemctl daemon-reload

mkdir -p "$applications_dir" "$autostart_dir"
install -m 0644 "$project_dir/desktop/clash-verge-guarded.desktop" "$applications_dir/clash-verge.desktop"
install -m 0644 "$project_dir/desktop/clash-verge-guarded.desktop" "$autostart_dir/clash-verge.desktop"
install -m 0644 "$project_dir/desktop/clash-verge-handler.desktop" "$applications_dir/clash-verge-handler.desktop"
xdg-mime default clash-verge-handler.desktop x-scheme-handler/clash-verge
xdg-mime default clash-verge-handler.desktop x-scheme-handler/clash

echo "Installed $guard_target without restarting the current Clash session."

