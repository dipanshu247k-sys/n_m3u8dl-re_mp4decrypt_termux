#!/usr/bin/env bash
set -euo pipefail

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_termux_deps() {
  local -a pkgs=()
  local p

  have pkg || return 0

  for p in "$@"; do
    if ! have "$p"; then
      pkgs+=("$p")
    fi
  done

  if ((${#pkgs[@]} > 0)); then
    pkg install -y "${pkgs[@]}"
  fi
}

print_selected_dir_blue() {
  local msg
  msg="--save-dir ${SELECTED_DIR:-}"

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[34m%s\033[0m\n' "$msg"
  else
    say "$msg"
  fi
}

choose_dir_no_storage_checks() {
  STORAGE_LOCATION="$PWD"

  have fzf || return 0
  [[ -d /sdcard && -r /sdcard ]] || return 0

  local choice
  choice="$(find /sdcard/ \
      \( -path '/sdcard/Android' -o -path '/sdcard/Android/*' -o -path '*/.*' \) -prune -o \
      -type d -print \
    | fzf --prompt='Select a folder: ' --height=40% --layout=reverse --no-multi)" || true

  if [[ -n "${choice:-}" ]]; then
    STORAGE_LOCATION="$choice"
  fi

  SELECTED_DIR="$STORAGE_LOCATION"
  export SELECTED_DIR STORAGE_LOCATION
}

main() {
  ensure_termux_deps fzf
  choose_dir_no_storage_checks
  print_selected_dir_blue
}

main "$@"
