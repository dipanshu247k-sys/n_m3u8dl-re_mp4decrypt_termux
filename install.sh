#!/usr/bin/env bash
set -euo pipefail

# Unified variable you can use elsewhere in this script:
#   SELECTED_DIR -> the folder you chose (or a fallback working dir)
SELECTED_DIR=""

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

print_selected_dir() {
  # Blue output if stdout is a TTY and NO_COLOR isn't set.
  # This prints the unified folder selection variable (same role as in select.sh).
  local msg
  msg="SELECTED_DIR=${SELECTED_DIR:-}"

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[34m%s\033[0m\n' "$msg"
  else
    say "$msg"
  fi
}

is_termux() {
  # Termux typically exports PREFIX=/data/data/com.termux/files/usr
  # and has `termux-setup-storage` available.
  [[ -n "${PREFIX:-}" && "${PREFIX:-}" == /data/data/com.termux/files/usr* ]] || have termux-setup-storage
}

bin_dir() {
  # bash is usually in $PREFIX/bin. Use it to find the correct bin dir.
  local bash_path
  bash_path="$(command -v bash)"
  dirname "$bash_path"
}

cpu_count() {
  if have nproc; then
    nproc
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
  fi
}

ensure_termux_storage() {
  # On Termux, /sdcard is available after running termux-setup-storage.
  if [[ -d "/sdcard/" && -r "/sdcard/" ]]; then
    return 0
  fi

  if is_termux && have termux-setup-storage; then
    say "Storage access not available yet. Run: termux-setup-storage"
    die "After granting permission, re-run this script."
  fi

  die "/sdcard is not accessible on this system."
}

choose_folder_from_sdcard() {
  ensure_termux_storage

  have fzf || die "fzf is required for folder selection. Install it (Termux: pkg install -y fzf)."

  # Efficient directory listing:
  # - prune Android/data and Android/obb (huge + often restricted)
  # - prune hidden folders (*/.*)
  # Note: trailing slash on /sdcard/ matters on your system because /sdcard is a symlink.
  local choice
  choice="$(find /sdcard/ \
      \( -path '/sdcard/Android/data' -o -path '/sdcard/Android/obb' -o -path '*/.*' \) -prune -o \
      -type d -print 2>/dev/null \
    | fzf --prompt='Select a folder: ' --height=40% --layout=reverse --no-multi)" || true

  if [[ -z "${choice:-}" ]]; then
    die "No folder selected."
  fi

  SELECTED_DIR="$choice"
  export SELECTED_DIR
}

ensure_deps_termux() {
  # Install missing dependencies on Termux (if `pkg` exists).
  have pkg || return 0

  local -a needed=()

  have curl  || needed+=(curl)
  have jq    || needed+=(jq)
  have fzf   || needed+=(fzf)
  have tar   || needed+=(tar)
  have unzip || needed+=(unzip)

  # Build dependencies for Bento4/mp4decrypt
  have cmake || needed+=(cmake)
  have make  || needed+=(make)
  have clang || needed+=(clang)

  if ((${#needed[@]} > 0)); then
    say "Installing dependencies: ${needed[*]}"
    pkg install -y "${needed[@]}"
  fi
}

select_from_list_fzf_or_prompt() {
  # Args:
  #   $1: prompt
  #   stdin: lines to select from
  # Returns:
  #   echoes the selected line
  local prompt
  prompt="$1"

  if have fzf; then
    fzf --prompt="$prompt" --height=40% --layout=reverse --no-multi
  else
    # Fallback: numbered prompt
    local -a lines=()
    local line
    while IFS= read -r line; do
      lines+=("$line")
    done

    ((${#lines[@]} > 0)) || return 1

    local i
    for i in "${!lines[@]}"; do
      printf '[%s] %s\n' "$((i+1))" "${lines[$i]}"
    done

    local choice
    read -r -p "Enter number (1-${#lines[@]}): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= ${#lines[@]} )) || return 1

    printf '%s\n' "${lines[$((choice-1))]}"
  fi
}

install_n_m3u8dl_re() {
  have curl || die "curl is required"
  have jq   || die "jq is required"

  local repo api_url release_json
  repo="nilaoda/N_m3u8DL-RE"
  api_url="https://api.github.com/repos/${repo}/releases/latest"

  say "Fetching latest release info for ${repo}..."
  release_json="$(curl -fsSL "$api_url")"

  # TSV: name \t url
  local assets_tsv
  assets_tsv="$(jq -r '.assets[] | [.name, .browser_download_url] | @tsv' <<<"$release_json")"

  [[ -n "$assets_tsv" ]] || die "No assets found in latest release."

  say "Choose the N_m3u8DL-RE asset to install:"

  local selected_line name url
  selected_line="$(printf '%s\n' "$assets_tsv" | select_from_list_fzf_or_prompt 'Asset: ' )" || die "No asset selected."
  name="${selected_line%%$'\t'*}"
  url="${selected_line#*$'\t'}"

  [[ -n "$name" && -n "$url" ]] || die "Failed to parse selected asset."

  local work_root dl_dir tmp_dir archive_path
  work_root="${SELECTED_DIR:-$PWD}"
  dl_dir="${work_root%/}/.downloads"
  mkdir -p "$dl_dir"
  tmp_dir="$(mktemp -d)"
  archive_path="${dl_dir%/}/$name"

  say "Downloading: $name"
  curl -fL --retry 3 --retry-delay 1 -o "$archive_path" "$url"

  say "Extracting..."
  case "$name" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
      tar -xf "$archive_path" -C "$tmp_dir"
      ;;
    *.zip)
      unzip -q "$archive_path" -d "$tmp_dir"
      ;;
    *)
      # Could be a raw binary
      cp -f "$archive_path" "$tmp_dir/"
      ;;
  esac

  # Try to locate the binary in extracted contents
  local candidate
  candidate="$(find "$tmp_dir" -maxdepth 3 -type f \( -name 'N_m3u8DL-RE*' -o -name 'n_m3u8dl-re*' \) 2>/dev/null | head -n 1)" || true

  if [[ -z "${candidate:-}" ]]; then
    # Fallback: if there is exactly one file (not counting dirs), install it.
    local file_count
    file_count="$(find "$tmp_dir" -type f | wc -l | tr -d ' ')"
    if [[ "$file_count" == "1" ]]; then
      candidate="$(find "$tmp_dir" -type f | head -n 1)"
    fi
  fi

  [[ -n "${candidate:-}" ]] || die "Could not find extracted N_m3u8DL-RE binary. Inspect: $tmp_dir"

  local dest
  dest="$(bin_dir)/$(basename "$candidate")"
  say "Installing to: $dest"
  cp -f "$candidate" "$dest"
  chmod +x "$dest" || true

  rm -rf "$tmp_dir"
  say "Installed: $(basename "$dest")"
}

install_mp4decrypt_from_bento4() {
  have curl  || die "curl is required"
  have jq    || die "jq is required"
  have unzip || die "unzip is required"
  have cmake || die "cmake is required"
  have make  || die "make is required"

  local repo api_url zip_url
  repo="axiomatic-systems/Bento4"
  api_url="https://api.github.com/repos/${repo}/tags"

  say "Fetching latest tag for ${repo}..."
  zip_url="$(curl -fsSL "$api_url" | jq -r '.[0].zipball_url')"
  [[ -n "$zip_url" && "$zip_url" != "null" ]] || die "Failed to find Bento4 zipball_url."

  local work_root dl_dir zip_path build_root src_dir
  work_root="${SELECTED_DIR:-$PWD}"
  dl_dir="${work_root%/}/.downloads"
  mkdir -p "$dl_dir"
  zip_path="${dl_dir%/}/Bento4-latest.zip"

  say "Downloading Bento4 source..."
  curl -fL --retry 3 --retry-delay 1 -o "$zip_path" "$zip_url"

  build_root="$(mktemp -d)"
  say "Extracting source..."
  unzip -q "$zip_path" -d "$build_root"

  # Zipball extracts into a single top-level directory.
  src_dir="$(find "$build_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)" || true
  [[ -n "${src_dir:-}" ]] || die "Could not find extracted source directory."

  say "Configuring build..."
  mkdir -p "$src_dir/cmakebuild"
  (
    cd "$src_dir/cmakebuild"
    cmake -DCMAKE_BUILD_TYPE=Release ..

    say "Building mp4decrypt..."
    make mp4decrypt -j"$(cpu_count)"

    local dest
    dest="$(bin_dir)/mp4decrypt"
    say "Installing to: $dest"
    cp -f "mp4decrypt" "$dest"
    chmod +x "$dest" || true
  )

  rm -rf "$build_root"
  say "Installed: mp4decrypt"
}

main() {
  # If running on Termux, auto-install deps where possible.
  if is_termux; then
    ensure_deps_termux
  fi

  # Always pick a folder from /sdcard on Termux (this is the unified variable).
  if is_termux; then
    choose_folder_from_sdcard
    say "Using SELECTED_DIR: $SELECTED_DIR"
  else
    SELECTED_DIR="$PWD"
    export SELECTED_DIR
    say "Non-Termux environment detected; using SELECTED_DIR=$SELECTED_DIR"
  fi

  say "What do you want to install?"
  local action
  action="$(printf '%s\n' \
      'Install N_m3u8DL-RE' \
      'Build & install mp4decrypt (Bento4)' \
      'Install both' \
      | select_from_list_fzf_or_prompt 'Action: ' )" || die "No action selected."

  case "$action" in
    'Install N_m3u8DL-RE')
      install_n_m3u8dl_re
      ;;
    'Build & install mp4decrypt (Bento4)')
      install_mp4decrypt_from_bento4
      ;;
    'Install both')
      install_n_m3u8dl_re
      install_mp4decrypt_from_bento4
      ;;
    *)
      die "Unknown action: $action"
      ;;
  esac

  say "Done."
  say "BIN_DIR=$(bin_dir)"
  print_selected_dir
}

main "$@"
