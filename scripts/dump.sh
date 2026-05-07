#!/bin/bash
# =============================================================================
# SamFWDumper v2.0 — High-Performance Samsung Firmware Extractor
# Copyright (C) 2026 Xiatsuma | Modified for ExtremeROM-MTK
# Licensed under PolyForm Noncommercial License 1.0.0
# =============================================================================
set -euo pipefail
shopt -s nullglob

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN_DIR="${SCRIPT_DIR}/bin"
readonly WORK_DIR="${PWD}"
readonly PROCESSED_DIR="${WORK_DIR}/processed"
readonly TEMP_DIR="${WORK_DIR}/.tmp_samfw"
readonly LOG_FILE="${WORK_DIR}/samfw_$(date +%Y%m%d_%H%M%S).log"

# Compression presets (balance speed/size for ROM dev workflow)
declare -A XZ_PRESETS=(
  [fast]="-3 --mt=0 --memlimit-compress=50%"   # ~3x faster, ~15% larger
  [balanced]="-6 --mt=0 --memlimit-compress=75%" # default
  [small]="-9 --mt=0 --memlimit-compress=90%"   # smallest, slowest
)
readonly DEFAULT_PRESET="balanced"

# Known Samsung dynamic partitions (extend as needed)
readonly SUPER_PARTS="system system_ext product vendor vendor_dlkm system_dlkm odm odm_dlkm"

# A346E/MTK specific defaults (override via --partitions)
readonly A346E_DEFAULT_PARTS="system system_ext vendor vendor_dlkm"

# ═══════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info() { log "ℹ️  $*"; }
ok()   { log "✅ $*"; }
warn() { log "⚠️  $*" >&2; }
err()  { log "❌ ERROR: $*" >&2; exit 1; }

cleanup() {
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  # Keep super_dump only if extraction succeeded
  [[ "${EXTRACTION_SUCCESS:-false}" == "true" ]] || rm -rf "${WORK_DIR}/super_dump" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] <FIRMWARE_URL>

High-performance Samsung firmware extractor for ROM development.

Arguments:
  URL                     Direct link to firmware ZIP (AP_*.tar.md5 inside)

Options:
  -p, --partitions LIST   Space-separated partitions to extract (default: A346E defaults)
  -c, --compression PRESET fast|balanced|small (default: balanced)
  -j, --jobs N            Parallel extraction jobs (default: auto = CPU cores)
  -k, --keep-tar          Keep extracted AP tar (default: delete)
  -r, --resume            Resume interrupted download (wget -c)
  -v, --verbose           Enable debug logging
  -n, --dry-run           Show what would be done, don't execute
  -h, --help              Show this help

Examples:
  $(basename "$0") https://.../A346EXXU1ABC1.zip
  $(basename "$0") -p "system vendor" -c fast https://.../firmware.zip
  $(basename "$0") -j 4 -r https://.../firmware.zip

EOF
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════
COMPRESSION_PRESET="$DEFAULT_PRESET"
SELECTED_PARTITIONS=""
PARALLEL_JOBS=$(nproc 2>/dev/null || echo 4)
KEEP_TAR=false
RESUME_DOWNLOAD=false
VERBOSE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--partitions) SELECTED_PARTITIONS="$2"; shift 2 ;;
    -c|--compression) COMPRESSION_PRESET="$2"; shift 2 ;;
    -j|--jobs) PARALLEL_JOBS="$2"; shift 2 ;;
    -k|--keep-tar) KEEP_TAR=true; shift ;;
    -r|--resume) RESUME_DOWNLOAD=true; shift ;;
    -v|--verbose) VERBOSE=true; set -x; shift ;;
    -n|--dry-run) DRY_RUN=true; info "🔍 DRY RUN MODE"; shift ;;
    -h|--help) usage ;;
    -*) err "Unknown option: $1" ;;
    *) FIRMWARE_URL="$1"; shift ;;
  esac
done

[[ -z "${FIRMWARE_URL:-}" ]] && err "Missing firmware URL. Use -h for help."
[[ -z "$SELECTED_PARTITIONS" ]] && {
  info "No partitions specified; using A346E defaults: $A346E_DEFAULT_PARTS"
  SELECTED_PARTITIONS="$A346E_DEFAULT_PARTS"
}
[[ -z "${XZ_PRESETS[$COMPRESSION_PRESET]:-}" ]] && err "Invalid compression preset: $COMPRESSION_PRESET"

XZ_FLAGS="${XZ_PRESETS[$COMPRESSION_PRESET]}"
info "Compression: $COMPRESSION_PRESET → xz $XZ_FLAGS"
info "Partitions: $SELECTED_PARTITIONS"
info "Parallel jobs: $PARALLEL_JOBS"

# ═══════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════
check_deps() {
  local deps=("wget" "unzip" "tar" "xz" "lz4" "file")
  # Optional but recommended
  local opt_deps=("simg2img" "lpunpack")
  
  for cmd in "${deps[@]}"; do
    command -v "$cmd" &>/dev/null || err "Missing required dependency: $cmd"
  done
  for cmd in "${opt_deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null && [[ ! -x "${BIN_DIR}/ext4/$cmd" && ! -x "${BIN_DIR}/lp/$cmd" ]]; then
      warn "Optional tool not found: $cmd (may be needed for super.img)"
    fi
  done
}

mkdir -p "$PROCESSED_DIR" "$TEMP_DIR"
check_deps

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 1: DOWNLOAD (with resume + integrity hint)
# ═══════════════════════════════════════════════════════════════════════════
download_firmware() {
  local url="$1" output="firmware.zip"
  local wget_args=(
    --no-check-certificate
    --progress=bar:force
    --timeout=30
    --tries=3
  )
  $RESUME_DOWNLOAD && wget_args+=(-c)
  
  info "[1/5] Downloading firmware..."
  if $DRY_RUN; then
    info "  [DRY] Would download: $url → $output"
    return 0
  fi
  
  if ! wget "${wget_args[@]}" -O "$output" "$url" 2>&1 | tee -a "$LOG_FILE"; then
    err "Download failed"
  fi
  
  # Basic sanity checks
  [[ ! -s "$output" ]] && err "Downloaded file is empty"
  local size=$(numfmt --to=iec $(stat -c%s "$output"))
  ok "Downloaded: $size"
  
  # Optional: hint about checksum file if present in same dir
  if [[ -f "${url%.zip}.sha256" ]] || [[ -f "${url%.zip}.md5" ]]; then
    info "💡 Checksum file detected — verify manually for production use"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 2: EXTRACT ZIP + LOCATE AP
# ═══════════════════════════════════════════════════════════════════════════
extract_ap_tar() {
  info "[2/5] Extracting firmware ZIP..."
  $DRY_RUN && { info "  [DRY] Would unzip firmware.zip"; return 0; }
  
  unzip -q -o firmware.zip -d "${TEMP_DIR}/zip" || err "Failed to extract firmware ZIP"
  rm -f firmware.zip
  
  # Find AP file (prioritize .tar.md5 → .tar)
  local ap_file
  ap_file=$(find "${TEMP_DIR}/zip" -type f \( -name "AP_*.tar.md5" -o -name "AP_*.tar" \) | head -n1)
  [[ -z "$ap_file" ]] && err "AP_*.tar[.md5] not found in firmware"
  
  info "  Found: $(basename "$ap_file")"
  
  # Strip .md5 suffix if present (tar can handle it, but cleaner to remove)
  if [[ "$ap_file" == *.md5 ]]; then
    local clean_tar="${ap_file%.md5}"
    cp "$ap_file" "$clean_tar"  # copy to avoid modifying original
    ap_file="$clean_tar"
  fi
  
  echo "$ap_file"
}

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 3: EXTRACT SELECTED PARTITIONS FROM AP TAR
# ═══════════════════════════════════════════════════════════════════════════
extract_from_tar() {
  local tar_file="$1"
  local -a patterns=()
  
  info "[3/5] Extracting partitions from AP tar..."
  
  # Build wildcard patterns for selected partitions (support _a/_b/none)
  for part in $SELECTED_PARTITIONS; do
    patterns+=("*${part}.img" "*${part}.img.lz4" "*${part}_a.img" "*${part}_a.img.lz4" "*${part}_b.img" "*${part}_b.img.lz4")
  done
  # Add super.img patterns if any selected part is in SUPER_PARTS
  for part in $SELECTED_PARTITIONS; do
    if [[ " $SUPER_PARTS " == *" $part "* ]]; then
      patterns+=("*super.img" "*super.img.lz4")
      break
    fi
  done
  
  $DRY_RUN && { info "  [DRY] Would extract patterns: ${patterns[*]}"; return 0; }
  
  # Extract with wildcards; fallback to full extract if needed (with warning)
  if ! tar --no-anchored --wildcards -xf "$tar_file" "${patterns[@]}" -C "${TEMP_DIR}/ap" 2>/dev/null; then
    warn "Wildcard extraction failed; falling back to full extract (slower)"
    tar -xf "$tar_file" -C "${TEMP_DIR}/ap" || err "Full tar extraction failed"
  fi
  
  $KEEP_TAR || rm -f "$tar_file"
  ok "AP extraction complete"
}

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 4: PROCESS PARTITIONS (PARALLEL + SMART)
# ═══════════════════════════════════════════════════════════════════════════

# Helper: decompress + compress a single image
process_image() {
  local src="$1" dest_dir="$2" part_name="$3"
  local tmp_img="${TEMP_DIR}/work.img"
  
  # Decompress LZ4 if needed
  if [[ "$src" == *.lz4 ]]; then
    lz4 -d -q "$src" "$tmp_img" || return 1
    src="$tmp_img"
  fi
  
  # Preserve original basename (with _a/_b suffix)
  local basename=$(basename "$src")
  local dest="${dest_dir}/${basename}.xz"
  
  # Atomic write: compress to temp, then move
  if xz $XZ_FLAGS -q -T0 "$src" -c > "${dest}.tmp"; then
    mv "${dest}.tmp" "$dest"
  else
    rm -f "${dest}.tmp"
    # Fallback: copy uncompressed (better than nothing)
    warn "xz failed for $basename; copying uncompressed"
    cp "$src" "${dest_dir}/${basename}"
  fi
  return 0
}

# Parallel worker for individual partitions
process_individual_partitions() {
  info "[4a/5] Processing individual partitions (parallel: $PARALLEL_JOBS)..."
  
  local -a jobs=()
  for part in $SELECTED_PARTITIONS; do
    # Skip if already processed (idempotent)
    [[ -f "${PROCESSED_DIR}/${part}.img.xz" || -f "${PROCESSED_DIR}/${part}_a.img.xz" || -f "${PROCESSED_DIR}/${part}_b.img.xz" ]] && continue
    
    # Find source file (any variant)
    local src=""
    for pattern in "${part}.img" "${part}.img.lz4" "${part}_a.img" "${part}_a.img.lz4" "${part}_b.img" "${part}_b.img.lz4"; do
      local found
      found=$(find "${TEMP_DIR}/ap" -maxdepth 3 -name "$pattern" -type f 2>/dev/null | head -n1)
      [[ -n "$found" ]] && { src="$found"; break; }
    done
    
    [[ -z "$src" ]] && { warn "Not found: $part*"; continue; }
    info "  ✓ Found: $(basename "$src")"
    
    # Queue job
    jobs+=("process_image '$src' '$PROCESSED_DIR' '$part'")
  done
  
  # Execute in parallel (simple GNU parallel fallback)
  if command -v parallel &>/dev/null; then
    printf '%s\n' "${jobs[@]}" | parallel -j "$PARALLEL_JOBS" bash -c '{}'
  else
    # Fallback: simple background jobs with wait
    for job in "${jobs[@]}"; do
      bash -c "$job" &
      # Limit concurrent jobs
      while (( $(jobs -r | wc -l) >= PARALLEL_JOBS )); do sleep 0.5; done
    done
    wait
  fi
}

# Extract & process super.img dynamic partitions
process_super_img() {
  # Check if any selected partition requires super.img
  local need_super=false
  for part in $SELECTED_PARTITIONS; do
    [[ " $SUPER_PARTS " == *" $part "* ]] && { need_super=true; break; }
  done
  $need_super || return 0
  
  info "[4b/5] Processing super.img (dynamic partitions)..."
  
  # Locate super.img
  local super_src
  super_src=$(find "${TEMP_DIR}/ap" -maxdepth 3 -name "super.img*" -type f | head -n1)
  [[ -z "$super_src" ]] && { warn "super.img not found; skipping dynamic partitions"; return 0; }
  
  local work_super="${TEMP_DIR}/super.img"
  
  # Decompress LZ4
  if [[ "$super_src" == *.lz4 ]]; then
    info "  Decompressing super.img.lz4..."
    $DRY_RUN || lz4 -d -q "$super_src" "$work_super" || err "LZ4 decompression failed"
  else
    cp "$super_src" "$work_super"
  fi
  
  # Convert sparse → raw if needed
  if file "$work_super" 2>/dev/null | grep -qi sparse; then
    info "  Converting sparse image..."
    local raw_img="${TEMP_DIR}/super.raw.img"
    if command -v simg2img &>/dev/null; then
      simg2img "$work_super" "$raw_img" 2>/dev/null
    elif [[ -x "${BIN_DIR}/ext4/simg2img" ]]; then
      "${BIN_DIR}/ext4/simg2img" "$work_super" "$raw_img" 2>/dev/null
    else
      err "simg2img not found; cannot convert sparse super.img"
    fi
    mv "$raw_img" "$work_super"
  fi
  
  # Unpack with lpunpack
  local dump_dir="${TEMP_DIR}/super_dump"
  mkdir -p "$dump_dir"
  info "  Unpacking dynamic partitions..."
  
  if [[ -x "${BIN_DIR}/lp/lpunpack" ]]; then
    "${BIN_DIR}/lp/lpunpack" "$work_super" "$dump_dir" 2>/dev/null || err "lpunpack failed"
  elif command -v lpunpack &>/dev/null; then
    lpunpack "$work_super" "$dump_dir" 2>/dev/null || err "lpunpack failed"
  else
    err "lpunpack not found; cannot extract dynamic partitions"
  fi
  
  # Compress ONLY selected partitions (preserve _a/_b suffixes)
  info "  Compressing selected dynamic partitions..."
  local -a super_jobs=()
  
  for part in $SELECTED_PARTITIONS; do
    [[ " $SUPER_PARTS " != *" $part "* ]] && continue
    
    for suffix in "_a" "" "_b"; do
      local img="${dump_dir}/${part}${suffix}.img"
      [[ ! -f "$img" ]] && continue
      
      info "    ✓ ${part}${suffix}.img"
      super_jobs+=("process_image '$img' '$PROCESSED_DIR' '${part}${suffix}'")
      break # found this partition
    done
  done
  
  # Parallel compress
  if command -v parallel &>/dev/null; then
    printf '%s\n' "${super_jobs[@]}" | parallel -j "$PARALLEL_JOBS" bash -c '{}'
  else
    for job in "${super_jobs[@]}"; do
      bash -c "$job" &
      while (( $(jobs -r | wc -l) >= PARALLEL_JOBS )); do sleep 0.5; done
    done
    wait
  fi
  
  # Cleanup super intermediates
  rm -rf "$dump_dir" "$work_super"
}

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 5: REPORT & INTEGRITY HINTS
# ═══════════════════════════════════════════════════════════════════════════
generate_report() {
  info "[5/5] Extraction complete!"
  
  cd "$PROCESSED_DIR"
  local count=$(find . -maxdepth 1 -type f \( -name "*.img.xz" -o -name "*.img" \) | wc -l)
  [[ "$count" -eq 0 ]] && err "No partitions extracted — check logs"
  
  local total_size=$(du -sh . | cut -f1)
  
  echo ""
  echo "═══════════════════════════════════════"
  echo "✅ SamFWDumper v2.0 — Summary"
  echo "═══════════════════════════════════════"
  echo "Partitions extracted: $count"
  echo "Total size: $total_size"
  echo "Compression preset: $COMPRESSION_PRESET"
  echo "Log file: $LOG_FILE"
  echo ""
  echo "Files:"
  ls -lh --group-directories-first | tail -n +2
  echo "═══════════════════════════════════════"
  
  # 💡 Integration hint for ExtremeROM-MTK pipeline
  if [[ "$SELECTED_PARTITIONS" == *"system"* && "$SELECTED_PARTITIONS" == *"vendor"* ]]; then
    echo ""
    echo "🔗 Next steps for ExtremeROM-MTK:"
    echo "   1. unxz -k processed/*.img.xz"
    echo "   2. Run your FIX_SYSTEM_EXT / FIX_SELINUX scripts"
    echo "   3. Repack with erofs-utils: mkfs.erofs -T0 system.erofs system/"
    echo ""
  fi
  
  EXTRACTION_SUCCESS=true
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════
main() {
  local start_time=$(date +%s)
  
  download_firmware "$FIRMWARE_URL"
  
  local ap_tar
  ap_tar=$(extract_ap_tar)
  
  mkdir -p "${TEMP_DIR}/ap"
  extract_from_tar "$ap_tar"
  
  process_individual_partitions
  process_super_img
  
  generate_report
  
  local elapsed=$(($(date +%s) - start_time))
  info "⏱️  Total time: $((elapsed/60))m $((elapsed%60))s"
}

# Run
main "$@"
