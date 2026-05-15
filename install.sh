#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Functions (definitions first)
# ------------------------------

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

init_logging() {
  LOG_FILE="${LOG_FILE:-nmt.logs}"
  : >"$LOG_FILE"
  say "Logs: $LOG_FILE"
}

log() {
  # Log a line to the log file (never to stdout).
  printf '%s\n' "$*" >>"$LOG_FILE"
}

run() {
  # Run a command and log all output.
  # Usage: run cmd arg1 arg2 ...
  (($# > 0)) || die "run: missing command"
  local -a cmd=("$@")

  {
    printf '\n$ %q' "${cmd[0]}"
    for a in "${cmd[@]:1}"; do printf ' %q' "$a"; done
    printf '\n'
  } >>"$LOG_FILE"

  "${cmd[@]}" >>"$LOG_FILE" 2>&1
}

step_start() { say "[START] $*"; }
step_done() { say "[DONE ] $*"; }
TERMUX_PKG_UPDATED=0

print_selected_dir_blue() {
  # Print selected dir at the end in blue (TTY only).
  local msg
  msg="--save-dir ${SELECTED_DIR:-}"

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[34m%s\033[0m\n' "$msg"
  else
    say "$msg"
  fi
}

ensure_termux_deps() {
  # Installs missing deps via `pkg` if available.
  # Args are Termux package names.
  local -a pkgs=()
  local p

  have pkg || return 0

  for p in "$@"; do
    # Heuristic: package name matches its main binary.
    # If not found, install it.
    if ! have "$p"; then
      pkgs+=("$p")
    fi
  done

  if ((${#pkgs[@]} > 0)); then
    if ((TERMUX_PKG_UPDATED == 0)); then
      run pkg update -y
      TERMUX_PKG_UPDATED=1
    fi
    run pkg install -y "${pkgs[@]}"
  fi
}

install_n_m3u8dl_re() {
  have curl || die "curl is required"
  have jq || die "jq is required"

  local repo api_url release_json
  repo="nilaoda/N_m3u8DL-RE"
  api_url="https://api.github.com/repos/${repo}/releases/latest"

  release_json="$(curl -fsSL "$api_url")"

  local -a asset_names=()
  local -a asset_urls=()
  mapfile -t asset_names < <(jq -r '.assets[].name' <<<"$release_json")
  mapfile -t asset_urls < <(jq -r '.assets[].browser_download_url' <<<"$release_json")

  ((${#asset_names[@]} > 0)) || die "No assets found for ${repo}."

  local selected_name=""
  if have fzf; then
    selected_name="$(printf '%s\n' "${asset_names[@]}" | fzf --prompt='N_m3u8DL-RE asset: ' --height=40% --layout=reverse --no-multi)" || true
  else
    # Fallback prompt
    local i
    for i in "${!asset_names[@]}"; do
      printf '[%s] %s\n' "$((i+1))" "${asset_names[$i]}"
    done
    local choice
    read -r -p "Enter number (1-${#asset_names[@]}): " choice
    [[ "${choice:-}" =~ ^[0-9]+$ ]] || die "Invalid selection"
    (( choice >= 1 && choice <= ${#asset_names[@]} )) || die "Invalid selection"
    selected_name="${asset_names[$((choice-1))]}"
  fi

  [[ -n "${selected_name:-}" ]] || die "No asset selected."

  local selected_url=""
  local idx
  for idx in "${!asset_names[@]}"; do
    if [[ "${asset_names[$idx]}" == "$selected_name" ]]; then
      selected_url="${asset_urls[$idx]}"
      break
    fi
  done
  [[ -n "${selected_url:-}" ]] || die "Failed to map selected asset to its download URL."

  local tmp_dir archive_path
  tmp_dir="$(mktemp -d)"
  archive_path="${tmp_dir%/}/${selected_name}"

  run curl -fL --retry 3 --retry-delay 1 -o "$archive_path" "$selected_url"

  # Extract into tmp_dir/extract
  local extract_dir
  extract_dir="${tmp_dir%/}/extract"
  mkdir -p "$extract_dir"

  case "$selected_name" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
      run tar -xf "$archive_path" -C "$extract_dir"
      ;;
    *.zip)
      run unzip -q "$archive_path" -d "$extract_dir"
      ;;
    *)
      run cp -f "$archive_path" "$extract_dir/"
      ;;
  esac

  # Find the binary
  local candidate
  candidate="$(find "$extract_dir" -maxdepth 4 -type f \( -name 'N_m3u8DL-RE*' -o -name 'n_m3u8dl-re*' \) 2>/dev/null | head -n 1)" || true
  [[ -n "${candidate:-}" ]] || die "Could not find extracted N_m3u8DL-RE binary. See $LOG_FILE"

  : "${PREFIX:=/data/data/com.termux/files/usr}"
  mkdir -p "$PREFIX/bin" "$PREFIX/lib"

  # Install to $PREFIX/bin (explicit, no basename)
  run cp -f "$candidate" "$PREFIX/bin/N_m3u8DL-RE"
  run chmod +x "$PREFIX/bin/N_m3u8DL-RE" || true

  # Patch rpath
  have patchelf || die "patchelf is required"
  run patchelf --set-rpath "$PREFIX/lib" "$PREFIX/bin/N_m3u8DL-RE"

  run rm -rf "$tmp_dir"
}

install_mp4decrypt_from_bento4() {
  have curl || die "curl is required"
  have jq || die "jq is required"
  have unzip || die "unzip is required"
  have cmake || die "cmake is required"
  have make || die "make is required"

  local repo api_url zip_url
  repo="axiomatic-systems/Bento4"
  api_url="https://api.github.com/repos/${repo}/tags"

  zip_url="$(curl -fsSL "$api_url" | jq -r '.[0].zipball_url')"
  [[ -n "$zip_url" && "$zip_url" != "null" ]] || die "Failed to find Bento4 zipball_url."

  local tmp_dir zip_path
  tmp_dir="$(mktemp -d)"
  zip_path="${tmp_dir%/}/Bento4.zip"

  run curl -fL --retry 3 --retry-delay 1 -o "$zip_path" "$zip_url"

  local src_root
  src_root="${tmp_dir%/}/src"
  mkdir -p "$src_root"
  run unzip -q "$zip_path" -d "$src_root"

  # Zipball extracts into a single top-level directory.
  local src_dir
  src_dir="$(find "$src_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)" || true
  [[ -n "${src_dir:-}" ]] || die "Could not find extracted Bento4 source directory."

  local build_dir
  build_dir="${src_dir%/}/cmakebuild"
  mkdir -p "$build_dir"

  run cmake -S "$src_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBRARY=OFF
  run cmake --build "$build_dir" --target mp4decrypt -- -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

  : "${PREFIX:=/data/data/com.termux/files/usr}"
  mkdir -p "$PREFIX/bin"

  local mp4decrypt_bin
  mp4decrypt_bin="${build_dir%/}/mp4decrypt"
  if [[ ! -f "$mp4decrypt_bin" ]]; then
    mp4decrypt_bin="$(find "$build_dir" -maxdepth 4 -type f -name 'mp4decrypt' 2>/dev/null | head -n 1)"
  fi
  [[ -n "${mp4decrypt_bin:-}" && -f "$mp4decrypt_bin" ]] || die "Could not find built mp4decrypt binary in $build_dir. Check CMake/build output in $LOG_FILE"

  run cp -f "$mp4decrypt_bin" "$PREFIX/bin/mp4decrypt"
  run chmod +x "$PREFIX/bin/mp4decrypt" || true

  run rm -rf "$tmp_dir"
}

choose_dir_no_storage_checks() {
  # No storage permission prompts/checks.
  # If /sdcard is not readable or fzf is missing, fall back to $PWD.
  SELECTED_DIR="$PWD"

  have fzf || return 0

  local choice
  choice="$(find /sdcard/ \
      \( -path '/sdcard/Android' -o -path '/sdcard/Android/*' -o -path '*/.*' \) -prune -o \
      -type d -print 2>/dev/null \
    | fzf --prompt='Select a folder: ' --height=40% --layout=reverse --no-multi)" || true

  if [[ -n "${choice:-}" ]]; then
    SELECTED_DIR="$choice"
  fi

  export SELECTED_DIR
}

# ------------------------------
# Calls (customizable at the end)
# ------------------------------

TERMUX_BOOTSTRAP_DEPS=(curl jq tar unzip)
TERMUX_BUILD_DEPS=(cmake make clang patchelf ffmpeg fzf)

main() {
  init_logging

  step_start "Step 1: dependencies"
  ensure_termux_deps "${TERMUX_BOOTSTRAP_DEPS[@]}" || true
  ensure_termux_deps "${TERMUX_BUILD_DEPS[@]}" || true
  step_done "Step 1: dependencies"

  step_start "Step 2: install N_m3u8DL-RE"
  install_n_m3u8dl_re
  step_done "Step 2: install N_m3u8DL-RE"

  step_start "Step 3: build/install mp4decrypt"
  install_mp4decrypt_from_bento4
  step_done "Step 3: build/install mp4decrypt"

  step_start "Step 4: choose folder"
  choose_dir_no_storage_checks
  step_done "Step 4: choose folder"

  print_selected_dir_blue
}

main "$@"
