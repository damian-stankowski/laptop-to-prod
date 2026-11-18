#!/usr/bin/env bash
#
# Download a Debian installer image and verify it end to end:
#
#   1. Every signing key file contains exactly the key pinned in the manifest.
#   2. SHA256SUMS carries a valid OpenPGP signature from a pinned key (gpgv
#      against a keyring built only from pinned keys).
#   3. The SHA256 signed by Debian equals the one pinned in the manifest.
#   4. The downloaded image matches that SHA256.
#
# The image is published to the output directory only after all checks pass.
# Interrupted downloads resume on the next run.
#
# Compatible with bash 3.2 (macOS) and later. Run with --help for usage.

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Constants and configuration
# ------------------------------------------------------------------------------

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR

readonly EX_FAILURE=1 EX_USAGE=2 EX_DEPENDENCY=3 EX_VERIFY=4 EX_NETWORK=5

readonly REQUIRED_COMMANDS="awk curl date gpg gpgv mktemp uname yq"
readonly STEP_TOTAL=4

# Options. Each has an environment default; command-line flags override it.
ARCH="${IMAGE_ARCH:-}"
MANIFEST="${IMAGE_MANIFEST:-$SCRIPT_DIR/manifest.yml}"
OUTPUT_DIR="${IMAGE_OUTPUT_DIR:-$SCRIPT_DIR/downloads}"
CURL_RETRIES="${IMAGE_CURL_RETRIES:-3}"
CURL_CONNECT_TIMEOUT="${IMAGE_CURL_CONNECT_TIMEOUT:-15}"
LOG_LEVEL="${IMAGE_LOG_LEVEL:-info}"
LOG_FORMAT="${IMAGE_LOG_FORMAT:-auto}"
FORCE=false
VERIFY_ONLY=false

# Runtime state.
WORK_DIR=""
STEP=0
SHA256_CMD=()

# ------------------------------------------------------------------------------
# Logging
#
# Logs go to stderr; stdout only receives the image path, and only when it is
# not a terminal, so `iso="$(download.sh)"` works.
#
#   pretty  human-oriented, steps and check marks, colored when supported
#   plain   one timestamped line per event, for CI and log collectors
# ------------------------------------------------------------------------------

LOG_THRESHOLD=20
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""

log_init() {
  case "$LOG_LEVEL" in
    debug) LOG_THRESHOLD=10 ;;
    info) LOG_THRESHOLD=20 ;;
    warn) LOG_THRESHOLD=30 ;;
    error) LOG_THRESHOLD=40 ;;
    *) die "$EX_USAGE" "invalid IMAGE_LOG_LEVEL '$LOG_LEVEL' (expected debug, info, warn or error)" ;;
  esac

  case "$LOG_FORMAT" in
    auto) if [[ -t 2 ]]; then LOG_FORMAT=pretty; else LOG_FORMAT=plain; fi ;;
    pretty | plain) ;;
    *) die "$EX_USAGE" "invalid IMAGE_LOG_FORMAT '$LOG_FORMAT' (expected auto, pretty or plain)" ;;
  esac

  if [[ "$LOG_FORMAT" == pretty && -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m'
  fi
}

# _log <numeric level> <kind> <message>
_log() {
  local level="$1" kind="$2" message="$3"
  ((level >= LOG_THRESHOLD)) || return 0

  if [[ "$LOG_FORMAT" == pretty ]]; then
    case "$kind" in
      STEP) printf '%s==>%s %s%s\n' "$C_BLUE$C_BOLD" "$C_RESET$C_BOLD" "$message" "$C_RESET" ;;
      OK) printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$message" ;;
      INFO) printf '    %s\n' "$message" ;;
      DEBUG) printf '    %s%s%s\n' "$C_DIM" "$message" "$C_RESET" ;;
      WARN) printf '  %s! %s%s\n' "$C_YELLOW" "$message" "$C_RESET" ;;
      ERROR) printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$message" ;;
    esac >&2
  else
    case "$kind" in STEP | OK) kind=INFO ;; esac
    printf '%s %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$message" >&2
  fi
}

log_debug() { _log 10 DEBUG "$*"; }
log_info() { _log 20 INFO "$*"; }
log_ok() { _log 20 OK "$*"; }
log_warn() { _log 30 WARN "$*"; }
log_error() { _log 40 ERROR "$*"; }

# log_step <title> [detail]
log_step() {
  local title="$1" detail="${2:-}"
  STEP=$((STEP + 1))
  if [[ "$LOG_FORMAT" == pretty && -n "$detail" ]]; then
    detail="  $C_DIM$detail$C_RESET"
  elif [[ -n "$detail" ]]; then
    detail=" ($detail)"
  fi
  _log 20 STEP "[$STEP/$STEP_TOTAL] $title$detail"
}

# die <exit code> <message>
die() {
  local code="$1"
  shift
  log_error "$*"
  exit "$code"
}

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

on_error() {
  local code="$1" line="$2" command="$3"
  log_error "unexpected failure at line $line (exit $code): $command"
  exit "$code"
}

on_signal() {
  echo >&2
  log_warn "interrupted; partial downloads are kept and will resume on the next run"
  exit 130
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Download a Debian installer image and verify its authenticity against the
pinned release manifest.

Options:
  -a, --arch ARCH         Architecture to download (default: host architecture)
  -o, --output-dir DIR    Directory for images (default: images/downloads)
  -m, --manifest FILE     Release manifest (default: images/manifest.yml)
  -f, --force             Download again even if a valid image exists
      --verify-only       Verify the local image without downloading it
  -v, --verbose           Show debug output
  -q, --quiet             Only show warnings and errors
  -h, --help              Show this help

Environment:
  IMAGE_ARCH, IMAGE_OUTPUT_DIR, IMAGE_MANIFEST
                              Defaults for --arch, --output-dir and --manifest
  IMAGE_LOG_LEVEL             debug | info | warn | error       (default: info)
  IMAGE_LOG_FORMAT            auto | pretty | plain             (default: auto)
  IMAGE_CURL_RETRIES          Retries per mirror                (default: 3)
  IMAGE_CURL_CONNECT_TIMEOUT  Connection timeout in seconds     (default: 15)
  NO_COLOR                    Disable colored output when set

Exit codes:
  0 success, 1 error, 2 usage, 3 missing dependency,
  4 verification failed, 5 network failure
EOF
}

# ------------------------------------------------------------------------------
# Arguments and environment
# ------------------------------------------------------------------------------

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -a | --arch | -o | --output-dir | -m | --manifest)
        [[ $# -ge 2 && -n "$2" ]] || die "$EX_USAGE" "option $1 requires a value"
        case "$1" in
          -a | --arch) ARCH="$2" ;;
          -o | --output-dir) OUTPUT_DIR="$2" ;;
          -m | --manifest) MANIFEST="$2" ;;
        esac
        shift 2
        ;;
      --arch=*) ARCH="${1#*=}" && shift ;;
      --output-dir=*) OUTPUT_DIR="${1#*=}" && shift ;;
      --manifest=*) MANIFEST="${1#*=}" && shift ;;
      -f | --force) FORCE=true && shift ;;
      --verify-only) VERIFY_ONLY=true && shift ;;
      -v | --verbose) LOG_LEVEL=debug && shift ;;
      -q | --quiet) LOG_LEVEL=warn && shift ;;
      -h | --help) usage && exit 0 ;;
      *) die "$EX_USAGE" "unexpected argument '$1' (see --help)" ;;
    esac
  done

  if [[ "$FORCE" == true && "$VERIFY_ONLY" == true ]]; then
    die "$EX_USAGE" "--force and --verify-only are mutually exclusive"
  fi
  [[ "$CURL_RETRIES" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "IMAGE_CURL_RETRIES must be a non-negative integer"
  [[ "$CURL_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "$EX_USAGE" "IMAGE_CURL_CONNECT_TIMEOUT must be a positive integer"
}

check_dependencies() {
  local cmd missing=""
  for cmd in $REQUIRED_COMMANDS; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  [[ -z "$missing" ]] || die "$EX_DEPENDENCY" "missing required commands:$missing"

  if ! yq --version 2>&1 | grep -Eq 'mikefarah.*version v?4\.'; then
    die "$EX_DEPENDENCY" "yq v4 from https://github.com/mikefarah/yq is required (found: $(yq --version 2>&1 | head -n 1))"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD=(shasum -a 256)
  else
    die "$EX_DEPENDENCY" "missing required command: sha256sum or shasum"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    arm64 | aarch64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# Manifest
# ------------------------------------------------------------------------------

# manifest_query <yq expression>: prints the result, fails on null/missing.
# The current architecture is available to expressions as strenv(YQ_ARCH).
manifest_query() {
  YQ_ARCH="$ARCH" yq -e "$1" "$MANIFEST" 2>/dev/null
}

# manifest_read <variable> <yq expression> <validation regex>
manifest_read() {
  local var="$1" expr="$2" pattern="$3" value
  value="$(manifest_query "$expr")" || die "$EX_FAILURE" "manifest: '$expr' is missing"
  [[ "$value" =~ $pattern ]] || die "$EX_FAILURE" "manifest: '$expr' has an invalid value: $value"
  printf -v "$var" '%s' "$value"
}

# render <template>: expands {distribution} {version} {arch} {type}.
render() {
  local s="$1"
  s="${s//\{distribution\}/$DISTRIBUTION}"
  s="${s//\{version\}/$VERSION}"
  s="${s//\{arch\}/$ARCH}"
  s="${s//\{type\}/$IMAGE_TYPE}"
  printf '%s' "$s"
}

load_manifest() {
  local manifest_dir path_template filename_template raw line fpr file supported
  local -r name='^[a-z0-9][a-z0-9-]*$'
  local -r fname='^[A-Za-z0-9][A-Za-z0-9._-]*$'

  [[ -f "$MANIFEST" ]] || die "$EX_FAILURE" "manifest not found: $MANIFEST"
  manifest_dir="$(cd "$(dirname "$MANIFEST")" && pwd)"

  manifest_read DISTRIBUTION '.release.distribution' "$name"
  manifest_read CODENAME '.release.codename' "$name"
  manifest_read VERSION '.release.version' '^[0-9]+(\.[0-9]+)*$'
  manifest_read IMAGE_TYPE '.release.type' "$name"
  manifest_read path_template '.source.path' '^[A-Za-z0-9{}._/-]+$'
  manifest_read filename_template '.source.filename' '^[A-Za-z0-9{}._-]+$'
  manifest_read CHECKSUMS_FILE '.source.checksums' "$fname"
  manifest_read SIGNATURE_FILE '.source.signature' "$fname"

  # Architecture: explicit, or the host's. Must be listed in the manifest.
  supported="$(manifest_query '.architectures | keys | join(", ")')" ||
    die "$EX_FAILURE" "manifest: '.architectures' is missing"
  if [[ -z "$ARCH" ]]; then
    ARCH="$(detect_arch)" || die "$EX_USAGE" "unsupported host architecture '$(uname -m)'; use --arch ($supported)"
  fi
  if ! [[ "$ARCH" =~ $name ]] || ! manifest_query '.architectures | has(strenv(YQ_ARCH))' >/dev/null; then
    die "$EX_USAGE" "unsupported architecture '$ARCH' (supported: $supported)"
  fi

  manifest_read EXPECTED_SHA256 '.architectures[strenv(YQ_ARCH)].sha256' '^[A-Fa-f0-9]{64}$'
  EXPECTED_SHA256="$(printf '%s' "$EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"

  REMOTE_DIR="$(render "$path_template")"
  IMAGE_FILE="$(render "$filename_template")"
  [[ "$REMOTE_DIR$IMAGE_FILE" != *[{}]* ]] || die "$EX_FAILURE" "manifest: unknown placeholder in '.source.path' or '.source.filename'"
  [[ "$REMOTE_DIR" != *..* ]] || die "$EX_FAILURE" "manifest: '.source.path' must not contain '..'"
  [[ "$IMAGE_FILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] || die "$EX_FAILURE" "manifest: invalid image filename '$IMAGE_FILE'"

  MIRRORS=()
  raw="$(manifest_query '.source.mirrors[]')" || die "$EX_FAILURE" "manifest: '.source.mirrors' is empty"
  while IFS= read -r line; do
    [[ "$line" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$ ]] ||
      die "$EX_FAILURE" "manifest: mirror must be a plain https:// URL: $line"
    MIRRORS+=("${line%/}")
  done <<<"$raw"

  KEY_FINGERPRINTS=()
  KEY_FILES=()
  raw="$(manifest_query '.trusted_keys[] | .fingerprint + " " + .file')" ||
    die "$EX_FAILURE" "manifest: '.trusted_keys' is empty"
  while read -r fpr file; do
    [[ "$fpr" =~ ^[A-F0-9]{40}$ ]] || die "$EX_FAILURE" "manifest: invalid fingerprint '$fpr' (40 uppercase hex chars)"
    [[ "$file" =~ ^[A-Za-z0-9._/-]+$ && "$file" != *..* ]] || die "$EX_FAILURE" "manifest: invalid key path '$file'"
    KEY_FINGERPRINTS+=("$fpr")
    KEY_FILES+=("$manifest_dir/$file")
  done <<<"$raw"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

sha256_of() {
  "${SHA256_CMD[@]}" "$1" | awk '{ print $1 }'
}

# "DF9B9C49EAA9…" -> "DF9B 9C49 EAA9 2984 3258  9D76 DA87 E80D 6294 BE9B"
format_fingerprint() {
  local fpr="$1" out="" i
  for ((i = 0; i < 40; i += 4)); do
    out="$out${fpr:i:4} "
    if ((i == 16)); then out="$out "; fi
  done
  printf '%s' "${out% }"
}

human_size() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB", u); i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.0f %s"), b, u[i]
  }'
}

human_duration() {
  local s="$1"
  if ((s >= 60)); then printf '%dm %02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

is_trusted_fingerprint() {
  local candidate="$1" fpr
  for fpr in "${KEY_FINGERPRINTS[@]}"; do
    [[ "$candidate" == "$fpr" ]] && return 0
  done
  return 1
}

# fetch <remote file> <destination> [image]
# Tries every mirror in order. "image" enables resume and the progress bar.
fetch() {
  local name="$1" dest="$2" kind="${3:-}" mirror url
  local -a opts=(
    --fail --location
    --proto '=https' --proto-redir '=https' --tlsv1.2
    --retry "$CURL_RETRIES" --retry-connrefused
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --output "$dest"
  )

  if [[ "$kind" == image ]]; then
    opts+=(--continue-at -)
  fi
  if [[ "$kind" == image && "$LOG_FORMAT" == pretty && $LOG_THRESHOLD -le 20 ]]; then
    opts+=(--progress-bar)
  else
    opts+=(--silent --show-error)
  fi

  for mirror in "${MIRRORS[@]}"; do
    url="$mirror/$REMOTE_DIR/$name"
    log_debug "GET $url"
    if curl "${opts[@]}" "$url"; then
      FETCHED_FROM="$mirror"
      return 0
    fi
    log_warn "could not download $name from $mirror"
  done
  return 1
}

# ------------------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------------------

build_keyring() {
  local i file fpr primaries uid

  log_step "Loading trusted keys" "${#KEY_FINGERPRINTS[@]} pinned"

  export GNUPGHOME="$WORK_DIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  KEYRING="$WORK_DIR/trusted.gpg"
  : >"$KEYRING"

  for i in "${!KEY_FINGERPRINTS[@]}"; do
    fpr="${KEY_FINGERPRINTS[$i]}"
    file="${KEY_FILES[$i]}"

    [[ -f "$file" ]] || die "$EX_VERIFY" "key file not found: $file"

    # Primary-key fingerprints only; subkeys are covered by their primary.
    primaries="$(
      gpg --batch --show-keys --with-colons "$file" 2>/dev/null |
        awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'
    )" || die "$EX_VERIFY" "cannot read OpenPGP key file: $file"

    [[ "$primaries" == "$fpr" ]] ||
      die "$EX_VERIFY" "${file##*/} must contain exactly key $fpr; found: $(echo "$primaries" | tr '\n' ' ')"

    uid="$(
      gpg --batch --show-keys --with-colons "$file" 2>/dev/null |
        awk -F: '$1 == "uid" { print $10; exit }'
    )"

    gpg --batch --dearmor <"$file" >>"$KEYRING" || die "$EX_VERIFY" "cannot import key file: $file"
    log_ok "$(format_fingerprint "$fpr")  $uid"
  done
}

verify_checksums() {
  local sums="$WORK_DIR/$CHECKSUMS_FILE" sig="$WORK_DIR/$SIGNATURE_FILE"
  local status="$WORK_DIR/gpgv.status" output="$WORK_DIR/gpgv.log"
  local signer="" candidate line

  log_step "Verifying $CHECKSUMS_FILE"

  fetch "$CHECKSUMS_FILE" "$sums" || die "$EX_NETWORK" "could not download $CHECKSUMS_FILE from any mirror"
  fetch "$SIGNATURE_FILE" "$sig" || die "$EX_NETWORK" "could not download $SIGNATURE_FILE from any mirror"
  log_ok "Downloaded from $FETCHED_FROM"

  # gpgv only knows the pinned keys, so any valid signature comes from one of
  # them. The fingerprint check below is defense in depth.
  if ! gpgv --status-fd 1 --keyring "$KEYRING" "$sig" "$sums" >"$status" 2>"$output"; then
    while IFS= read -r line; do log_warn "gpgv: $line"; done <"$output"
    die "$EX_VERIFY" "$CHECKSUMS_FILE does not carry a valid signature from a pinned key"
  fi

  # VALIDSIG field 12 is the primary-key fingerprint, also when signed by a subkey.
  while read -r candidate; do
    if is_trusted_fingerprint "$candidate"; then
      signer="$candidate"
      break
    fi
  done < <(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $12 }' "$status")
  [[ -n "$signer" ]] || die "$EX_VERIFY" "$CHECKSUMS_FILE is not signed by a pinned key"
  log_ok "Good signature from $(format_fingerprint "$signer")"

  SIGNED_SHA256="$(
    awk -v f="$IMAGE_FILE" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$sums"
  )"
  [[ -n "$SIGNED_SHA256" ]] || die "$EX_VERIFY" "$IMAGE_FILE is not listed in $CHECKSUMS_FILE"
  [[ "$SIGNED_SHA256" == "$EXPECTED_SHA256" ]] ||
    die "$EX_VERIFY" "manifest sha256 does not match the one signed by Debian (manifest $EXPECTED_SHA256, signed $SIGNED_SHA256)"
  log_ok "Manifest sha256 matches the signed checksum"
}

# Returns 0 if a valid image is already in place, 1 if it must be downloaded.
check_local_image() {
  local actual

  if [[ ! -f "$DEST" ]]; then
    [[ "$VERIFY_ONLY" == false ]] || die "$EX_VERIFY" "no local image at $DEST"
    log_info "No local copy"
    return 1
  fi
  if [[ "$FORCE" == true ]]; then
    log_info "Ignoring local copy (--force)"
    return 1
  fi

  actual="$(sha256_of "$DEST")"
  if [[ "$actual" == "$SIGNED_SHA256" ]]; then
    log_ok "Local copy is valid"
    return 0
  fi

  [[ "$VERIFY_ONLY" == false ]] || die "$EX_VERIFY" "local image does not match the signed checksum: $DEST"
  log_warn "Local copy does not match the signed checksum; downloading again"
  return 1
}

download_image() {
  # Downloaded next to the destination so the final rename is atomic and an
  # interrupted download can be resumed.
  local part="$DEST.part" actual

  if [[ -s "$part" ]]; then
    log_info "Resuming partial download ($(human_size "$(wc -c <"$part" | tr -d '[:space:]')") already on disk)"
  fi
  if ! fetch "$IMAGE_FILE" "$part" image; then
    [[ -s "$part" ]] || die "$EX_NETWORK" "could not download $IMAGE_FILE from any mirror"
    log_warn "Could not resume the partial download; starting over"
    rm -f "$part"
    fetch "$IMAGE_FILE" "$part" image || die "$EX_NETWORK" "could not download $IMAGE_FILE from any mirror"
  fi
  log_ok "Downloaded from $FETCHED_FROM"

  actual="$(sha256_of "$part")"
  if [[ "$actual" != "$SIGNED_SHA256" ]]; then
    rm -f "$part"
    die "$EX_VERIFY" "downloaded image does not match the signed checksum (expected $SIGNED_SHA256, got $actual)"
  fi
  log_ok "sha256 $actual"

  mv -f "$part" "$DEST"
}

print_summary() {
  local bytes size elapsed shown="$DEST"

  bytes="$(wc -c <"$DEST" | tr -d '[:space:]')"
  size="$(human_size "$bytes")"
  elapsed="$(human_duration "$SECONDS")"
  [[ "$shown" != "$PWD/"* ]] || shown="${shown#"$PWD/"}"

  if [[ "$LOG_FORMAT" == pretty ]]; then
    ((LOG_THRESHOLD > 20)) || printf '\n%sDone%s  %s  %s(%s, %s)%s\n' \
      "$C_GREEN$C_BOLD" "$C_RESET" "$shown" "$C_DIM" "$size" "$elapsed" "$C_RESET" >&2
  else
    log_info "done path=$DEST arch=$ARCH sha256=$SIGNED_SHA256 bytes=$bytes elapsed=${SECONDS}s"
  fi

  if [[ ! -t 1 ]]; then
    printf '%s\n' "$DEST"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup EXIT
  trap on_signal INT TERM

  parse_args "$@"
  log_init
  check_dependencies

  load_manifest
  log_step "Resolving release" "$DISTRIBUTION $VERSION ($CODENAME) $IMAGE_TYPE, $ARCH"
  log_ok "$IMAGE_FILE"
  log_debug "manifest: $MANIFEST"
  log_debug "mirrors: ${MIRRORS[*]}"

  mkdir -p "$OUTPUT_DIR"
  DEST="$(cd "$OUTPUT_DIR" && pwd)/$IMAGE_FILE"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/image-download.XXXXXX")"

  build_keyring
  verify_checksums

  if [[ "$VERIFY_ONLY" == true ]]; then
    log_step "Verifying local image"
  else
    log_step "Fetching image"
  fi
  if ! check_local_image; then
    download_image
  fi

  print_summary
}

main "$@"
