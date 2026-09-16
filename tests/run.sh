#!/bin/bash
set -u

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$project_dir/tests/fixtures"
guard="$project_dir/bin/clash-verge-guarded"
test_root="$(mktemp -d)"
test_log="$test_root/actions.log"

cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "${first_guard_pid:-}" ]; then
    kill -TERM "$first_guard_pid" 2>/dev/null || true
    wait "$first_guard_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

fail() { echo "guard test failed: $*" >&2; exit 1; }
wait_for_file() {
  local path="$1" attempt=0
  while [ ! -e "$path" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 100 ] || fail "timeout: $path"
    sleep 0.02
  done
}
wait_for_pattern() {
  local pattern="$1" path="$2" attempt=0
  until grep -Fqx "$pattern" "$path" 2>/dev/null; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 100 ] || fail "timeout: $pattern"
    sleep 0.02
  done
}

handler="$test_root/applications/clash-verge-handler.desktop"
common_env=(
  "CLASH_GUARD_RUNTIME_DIR=$test_root/runtime"
  "CLASH_GUARD_LAUNCHER_PATH=$guard"
  "CLASH_GUARD_BINARY=$fixtures/fake-clash"
  "CLASH_GUARD_UI_EXE=/definitely/not/a/real/clash-ui"
  "CLASH_GUARD_SUDO=$fixtures/fake-sudo"
  "CLASH_GUARD_SYSTEMCTL=$fixtures/fake-systemctl"
  "CLASH_GUARD_GSETTINGS=$fixtures/fake-gsettings"
  "CLASH_GUARD_XDG_MIME=$fixtures/fake-xdg-mime"
  "CLASH_GUARD_APPLICATIONS_DIR=$test_root/applications"
  "CLASH_GUARD_PROTOCOL_REPAIR_ATTEMPTS=4"
  "CLASH_GUARD_PROTOCOL_REPAIR_INTERVAL=0.02"
  "FAKE_CLASH_HANDLER_PATH=$handler"
  "LAUNCHER_TEST_LOG=$test_log"
)

mkdir -p "$test_root/runtime/clash-verge-ui-leases"
printf '0\n' > "$test_root/runtime/clash-verge-ui-leases/$$"

env "${common_env[@]}" "FAKE_CLASH_EXIT_FILE=$test_root/first.exit" "$guard" &
first_guard_pid=$!
wait_for_file "$test_root/runtime/clash-verge-ui-leases/$first_guard_pid"
wait_for_pattern "Exec=$guard %u" "$handler"
[ ! -e "$test_root/runtime/clash-verge-ui-leases/$$" ] || fail "stale lease remains"

touch "$test_root/second.exit"
env "${common_env[@]}" "FAKE_CLASH_EXIT_FILE=$test_root/second.exit" "$guard" &
second_guard_pid=$!
wait "$second_guard_pid" || fail "second guard failed"
wait_for_pattern "Exec=$guard %u" "$handler"
grep -q '^systemctl stop ' "$test_log" && fail "second launch stopped primary core"

touch "$test_root/first.exit"
wait "$first_guard_pid" || fail "first guard failed"
first_guard_pid=""

[ "$(grep -c '^systemctl stop ' "$test_log")" -eq 1 ] || fail "service stop count"
[ "$(grep -c '^gsettings set org.gnome.system.proxy mode none$' "$test_log")" -eq 2 ] || fail "proxy reset count"
[ ! -d "$test_root/runtime/clash-verge-ui-leases" ] || fail "lease directory remains"
[ "$(grep -c '^xdg-mime default clash-verge-handler.desktop x-scheme-handler/' "$test_log")" -ge 4 ] || fail "protocol repair missing"

echo "clash guard integration tests passed"
