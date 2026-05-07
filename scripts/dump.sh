#!/usr/bin/env bash
# Automated Samsung Firmware Partition Extractor
# Optimized for GitHub Actions + Local Use
set -euo pipefail
shopt -s nullglob

# Configuration
readonly WORK_DIR="${PWD}"
readonly PROCESSED_DIR="${WORK_DIR}/processed"
readonly TEMP_DIR="${WORK_DIR}/.tmp_fw"
readonly BIN_DIR="${WORK_DIR}/bin"

# Map compression input (0/3/6/9) to xz flags
map_compression() {
  case "$1" in
    0) echo "-0 -T0 --memlimit-compress=30%" ;;
    3) echo "-3 -T0 --memlimit-compress=50%" ;;
    6) echo "-6 -T0 --memlimit-compress=75%" ;;
    9) echo "-9 -T0 --memlimit-compress=90%" ;;
    *) echo "-6 -T0 --memlimit-compress=75%" ;;
  esac
}

# Auto-fix image: decompress + sparse convert + verify
auto_fix_image() {
  local img="$1"
  local tmp="${TEMP_DIR}/fix_$$.img"
  
  # Decompress
  if [[ "$img" == *.lz4 ]]; then
    lz4 -d -q -T0 "$img" "$tmp" 2>/dev/null || return 1
    img="$tmp"
  elif [[ "$img" == *.xz ]]; then
    xz -d -q -T0 "$img" -c > "$tmp" 2>/dev/null || return 1
    img="$tmp"
  fi
  
  # Convert sparse → raw (fixes "failed to read superblock")
  if file "$img" 2>/dev/null | grep -qi "android sparse"; then
    local raw="${img%.img}_raw.img"
    if command -v simg2img &>/dev/null; then
      simg2img "$img" "$raw" 2>/dev/null || return 1
    elif [[ -x "${BIN_DIR}/ext4/simg2img" ]]; then
      "${BIN_DIR}/ext4/simg2img" "$img" "$raw" 2>/dev/null || return 1
    else
      return 1
    fi
    mv "$raw" "$img"
  fi
  
  echo "$img"
}

# Process single image: fix + verify + compress
process_image() {
  local src="$1" dest_dir="$2" xz_flags="$3"
  
  src=$(auto_fix_image "$src") || return 0
  [[ -z "$src" || ! -f "$src" ]] && return 0
  
  # Verify filesystem before compressing
  if ! extract.erofs -l "$src" &>/dev/null && ! e2fsck -n "$src" &>/dev/null 2>&1; then
    echo "⚠️  Skip invalid: $(basename "$src")" >&2
    return 0
  fi
  
  local bname=$(basename "$src")
  xz $xz_flags -q "$src" -c > "${dest_dir}/${bname}.xz.tmp" 2>/dev/null && \
    mv "${dest_dir}/${bname}.xz.tmp" "${dest_dir}/${bname}.xz" || \
    cp "$src" "${dest_dir}/${bname}"
}

# Main execution
main() {
  local URL="${1:?Usage: $0 <URL> <COMPRESSION> <PARTITIONS...>}"
  local COMP_LEVEL="${2:-6}"
  shift 2
  local PARTITIONS="$*"
  
  [[ -z "$PARTITIONS" ]] && { echo "❌ No partitions specified"; exit 1; }
  
  local XZ_FLAGS
  XZ_FLAGS=$(map_compression "$COMP_LEVEL")
  local MAX_JOBS=$(nproc 2>/dev/null || echo 2)
  
  mkdir -p "$PROCESSED_DIR" "$TEMP_DIR"
  
  echo "📥 Downloading firmware..."
  wget -q --no-check-certificate -O "firmware.zip" "$URL" || { echo "❌ Download failed"; exit 1; }
  [[ ! -s "firmware.zip" ]] && { echo "❌ Empty download"; exit 1; }
  
  echo "📦 Extracting ZIP..."
  unzip -q -o firmware.zip -d "${TEMP_DIR}/zip" || exit 1
  rm -f firmware.zip
  
  echo "🔍 Locating AP tar..."
  local AP_FILE
  AP_FILE=$(find "${TEMP_DIR}/zip" -type f \( -name "AP_*.tar.md5" -o -name "AP_*.tar" \) | head -n1)
  [[ -z "$AP_FILE" ]] && { echo "❌ AP tar not found"; exit 1; }
  [[ "$AP_FILE" == *.md5 ]] && { cp "$AP_FILE" "${AP_FILE%.md5}"; AP_FILE="${AP_FILE%.md5}"; }
  
  echo "📂 Extracting partitions from AP..."
  mkdir -p "${TEMP_DIR}/ap"
  local -a patterns=()
  for p in $PARTITIONS; do
    patterns+=("*${p}.img" "*${p}.img.lz4" "*${p}.img.xz" "*${p}_a.img" "*${p}_a.img.lz4" "*${p}_b.img" "*${p}_b.img.lz4")
  done
  # Add super.img if needed
  local SUPER_PARTS="system system_ext product vendor vendor_dlkm system_dlkm odm odm_dlkm"
  for p in $PARTITIONS; do
    if [[ " $SUPER_PARTS " == *" $p "* ]]; then
      patterns+=("*super.img" "*super.img.lz4"); break
    fi
  done
  
  if ! tar --no-anchored --wildcards -xf "$AP_FILE" "${patterns[@]}" -C "${TEMP_DIR}/ap" 2>/dev/null; then
    echo "⚠️  Wildcard failed, extracting full tar..." >&2
    tar -xf "$AP_FILE" -C "${TEMP_DIR}/ap" || exit 1
  fi
  rm -f "$AP_FILE"
  
  echo "⚙️  Processing partitions (parallel: $MAX_JOBS)..."
  
  # Collect files to process
  local -a entries=()
  for p in $PARTITIONS; do
    for pat in "${p}.img" "${p}.img.lz4" "${p}.img.xz" "${p}_a.img" "${p}_a.img.lz4" "${p}_b.img" "${p}_b.img.lz4"; do
      local f; f=$(find "${TEMP_DIR}/ap" -maxdepth 3 -name "$pat" -type f 2>/dev/null | head -n1)
      [[ -n "$f" ]] && { entries+=("$f|$PROCESSED_DIR|$XZ_FLAGS"); break; }
    done
  done
  
  # Handle super.img dynamic partitions
  local SUPER_FILE
  SUPER_FILE=$(find "${TEMP_DIR}/ap" -maxdepth 3 -name "super.img*" -type f | head -n1)
  if [[ -n "$SUPER_FILE" ]]; then
    local work_super="${TEMP_DIR}/super.img"
    [[ "$SUPER_FILE" == *.lz4 ]] && lz4 -d -q -T0 "$SUPER_FILE" "$work_super" || cp "$SUPER_FILE" "$work_super"
    
    if file "$work_super" 2>/dev/null | grep -qi "android sparse"; then
      local raw="${TEMP_DIR}/super.raw.img"
      command -v simg2img &>/dev/null && simg2img "$work_super" "$raw" || \
      [[ -x "${BIN_DIR}/ext4/simg2img" ]] && "${BIN_DIR}/ext4/simg2img" "$work_super" "$raw" || true
      [[ -f "$raw" ]] && mv "$raw" "$work_super"
    fi
    
    mkdir -p "${TEMP_DIR}/super_dump"
    if [[ -x "${BIN_DIR}/lp/lpunpack" ]]; then
      "${BIN_DIR}/lp/lpunpack" "$work_super" "${TEMP_DIR}/super_dump" 2>/dev/null || true
    elif command -v lpunpack &>/dev/null; then
      lpunpack "$work_super" "${TEMP_DIR}/super_dump" 2>/dev/null || true
    fi
    
    for p in $PARTITIONS; do
      [[ " $SUPER_PARTS " != *" $p "* ]] && continue
      for suf in "_a" "" "_b"; do
        local img="${TEMP_DIR}/super_dump/${p}${suf}.img"
        [[ -f "$img" ]] && { entries+=("$img|$PROCESSED_DIR|$XZ_FLAGS"); break; }
      done
    done
    rm -rf "${TEMP_DIR}/super_dump" "$work_super"
  fi
  
  # Parallel processing with xargs
  [[ ${#entries[@]} -gt 0 ]] && printf '%s\n' "${entries[@]}" | xargs -P "$MAX_JOBS" -I '{}' bash -c '
    IFS="|" read -r src dest flags <<< "{}"
    process_image "$src" "$dest" "$flags"
  '
  
  # Cleanup
  rm -rf "$TEMP_DIR"
  
  # Report
  echo ""
  echo "════════════════════════════"
  echo "✅ Extraction complete"
  cd "$PROCESSED_DIR"
  local count=$(find . -maxdepth 1 -type f | wc -l)
  echo "Files: $count"
  echo "Size: $(du -sh . | cut -f1)"
  ls -lh
  echo "════════════════════════════"
}

main "$@"
