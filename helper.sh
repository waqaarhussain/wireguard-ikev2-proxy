#!/usr/bin/env bash
set -euo pipefail

# Request root access when a tool is selected; the menu itself needs none.
run_tool() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -- "$1"
  else
    echo "Root access is required. Run helper as root or install sudo." >&2
    return 1
  fi
}

while true; do
  echo
  echo "WireGuard / IKEv2 Proxy"
  echo "  [1] Add a proxy exit"
  echo "  [2] Create a client / Apple profile"
  echo "  [3] Manage proxies, clients and routes"
  echo "  [4] Benchmark proxy exits"
  echo "  [0] Exit"
  echo

  if ! read -r -p "Choice: " choice; then
    echo
    exit 0
  fi

  case "$choice" in
    1) tool=add ;;
    2) tool=new ;;
    3) tool=manage ;;
    4) tool=bench ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice. Select 1 to 4, or 0 to exit."; continue ;;
  esac

  command_path="/usr/local/bin/$tool"
  if [ ! -x "$command_path" ]; then
    echo "Missing command: $command_path" >&2
    echo "This menu needs the project's existing helper commands installed." >&2
    continue
  fi

  echo
  if run_tool "$command_path"; then
    :
  else
    status=$?
    printf '\n%s exited with status %s. Returning to the main menu.\n' "$tool" "$status" >&2
  fi
done
