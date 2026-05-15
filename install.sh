#!/usr/bin/env bash
set -euo pipefail

# Unified variable (chosen at the end).
# You can copy/paste it or use it when sourcing this script.
SELECTED_DIR=""

# Internal working directories (not user-facing)
WORK_ROOT=""
DL_DIR=""

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

print_selected_dir() {
  # Blue output if stdout is a TTY and NO_COLOR isn't set.
  local msg
  msg=" --save-dir ${SELECTED_DIR:-} "

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[34m%s\033[0m\n' "$msg"
  else
    say "$msg"
  fi
}

is_termux() {
  [[ -n "${PREFIX:-}" && "${PREFIX:-}" == /data/data/com.termux/files/usr* ]] || have termux-setup-storage
}

bin_dir() {
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

setup_work_dirs() {
  WORK_ROOT="$(mktemp -d)"
  DL_DIR="${WORK_ROOT%/}/.downloads"
  mkdir -p "$DL_DIR"

  # Cleanup even if something fails.
  trap 'rm -rf "$WORK_ROOT" 2>/dev/null || true' EXIT
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
  have ffmpeg || needed+=(ffmpeg)

  # Build dependencies for Bento4/mp4decrypt
  have cmake || needed+=(cmake)
  have make  || needed+=(make)
  have clang || needed+=(clang)

  if ((${#needed[@]} > 0)); then
    say "Installing dependencies: ${needed[*]}"
    pkg install -y "${needed[@]}"
  fi
}

choose_folder_from_sdcard_end() {
  # Ask user at the END (as requested). If not possible, fall back to $PWD.

  if [[ ! -d "/sdcard/" || ! -r "/sdcard/" ]]; then
    if is_termux && have termux-setup-storage; then
      say "Note: /sdcard is not accessible. To enable folder picking, run: termux-setup-storage"
    else
      say "Note: /sdcard is not accessible on this system."
    fi

    SELECTED_DIR="$PWD"
    export SELECTED_DIR
    return 0
  fi

  if ! have fzf; then
    say "Note: fzf is not installed; falling back to SELECTED_DIR=$PWD"
    SELECTED_DIR="$PWD"
    export SELECTED_DIR
    return 0
  fi

  # Efficient directory listing:
  # - prune Android/data and Android/obb (huge + often restricted)
  # - prune hidden folders (*/.*)
  # Note: trailing slash on /sdcard/ matters on some systems where /sdcard is a symlink.
  local choice
  choice="$(find /sdcard/ \
  \( -path '/sdcard/Android' -o -path '/sdcard/Android/*' -o -path '*/.*' \) -prune -o \
      -type d -print 2>/dev/null \
    | fzf --prompt='Select a folder: ' --height=40% --layout=reverse --no-multi)" || true

  if [[ -z "${choice:-}" ]]; then
    say "No folder selected; falling back to SELECTED_DIR=$PWD"
    SELECTED_DIR="$PWD"
  else
    SELECTED_DIR="$choice"
  fi

  export SELECTED_DIR
}

install_n_m3u8dl_re() {
  have curl || die "curl is required"
  have jq   || die "jq is required"

  local repo api_url release_json
  repo="nilaoda/N_m3u8DL-RE"
  api_url="https://api.github.com/repos/${repo}/releases/latest"

  say "Fetching latest release info for ${repo}..."
  release_json="$(curl -fsSL "$api_url")"

  local -a asset_names=()
  local -a asset_urls=()

  mapfile -t asset_names < <(jq -r '.assets[].name' <<<"$release_json")
  mapfile -t asset_urls  < <(jq -r '.assets[].browser_download_url' <<<"$release_json")

  ((${#asset_names[@]} > 0)) || die "No assets found in latest release."
  ((${#asset_names[@]} == ${#asset_urls[@]})) || die "Asset list mismatch from GitHub API."

  say "Choose the N_m3u8DL-RE file to download (URLs hidden):"

  local selected_name=""
  if have fzf; then
    selected_name="$(printf '%s\n' "${asset_names[@]}" | fzf --prompt='Asset: ' --height=40% --layout=reverse --no-multi)" || true
  else
    local i
    for i in "${!asset_names[@]}"; do
      printf '[%s] %s\n' "$((i+1))" "${asset_names[$i]}"
    done
    local choice
    read -r -p "Enter the number (1-${#asset_names[@]}): " choice
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

  local archive_path tmp_dir
  archive_path="${DL_DIR%/}/${selected_name}"
  tmp_dir="$(mktemp -d)"

  say "Downloading: $selected_name"
  curl -fL --retry 3 --retry-delay 1 -o "$archive_path" "$selected_url"

  say "Extracting..."
  case "$selected_name" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
      tar -xf "$archive_path" -C "$tmp_dir"
      ;;
    *.zip)
      unzip -q "$archive_path" -d "$tmp_dir"
      ;;
    *)
      cp -f "$archive_path" "$tmp_dir/"
      ;;
  esac

  local candidate
  candidate="$(find "$tmp_dir" -maxdepth 3 -type f \( -name 'N_m3u8DL-RE*' -o -name 'n_m3u8dl-re*' \) 2>/dev/null | head -n 1)" || true

  if [[ -z "${candidate:-}" ]]; then
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

  local zip_path build_root src_dir
  zip_path="${DL_DIR%/}/Bento4-latest.zip"

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
  # Termux: install deps first, but do NOT ask for /sdcard folder until the end.
  if is_termux; then
    ensure_deps_termux
  fi

  setup_work_dirs

  # 1) Always install both tools (no prompt).
  install_n_m3u8dl_re
  install_mp4decrypt_from_bento4

  # 2) Ask for choosing folder in the end (as requested).
  choose_folder_from_sdcard_end

  say "Done."
  say "BIN_DIR=$(bin_dir)"
  print_selected_dir
}

main "$@"
