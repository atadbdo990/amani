#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  AMANI-MORA — Xray Cloud Run Deployment Tool (VLESS / VMESS / TROJAN)
#
#  This script talks to exactly two places, and only if you ask it to:
#    1) Google Cloud (gcloud) — to deploy the service to Cloud Run
#    2) Telegram — ONLY if you supply your own bot token + chat id below
#  It does not phone home to any third-party server, does not use any
#  hardcoded API key, and does not delete itself or its own folder.
# ============================================================================

export TZ='Etc/GMT-1'

# ========== COLORS ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BRIGHT_RED='\033[0;91m'; BRIGHT_GREEN='\033[0;92m'; BRIGHT_YELLOW='\033[0;93m'
BRIGHT_CYAN='\033[0;96m'; BRIGHT_WHITE='\033[0;97m'; BRIGHT_BLUE='\033[0;94m'
BRIGHT_MAGENTA='\033[0;95m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

print_error()   { echo -e "${BRIGHT_RED}${BOLD}✗${NC} ${RED}$1${NC}"; }
print_warning() { echo -e "${BRIGHT_YELLOW}${BOLD}⚠${NC} ${YELLOW}$1${NC}"; }
print_success() { echo -e "${BRIGHT_GREEN}${BOLD}✓${NC} ${GREEN}$1${NC}"; }
print_info()    { echo -e "${BRIGHT_CYAN}${BOLD}ℹ${NC} ${CYAN}$1${NC}"; }
print_header() {
  echo -e "\n${BRIGHT_CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BRIGHT_CYAN}${BOLD}║${NC}  ${BRIGHT_GREEN}🚀 AMANI-MORA — Xray Cloud Run Deploy${NC}          ${BRIGHT_CYAN}${BOLD}║${NC}"
  echo -e "${BRIGHT_CYAN}${BOLD}║${NC}  ${BRIGHT_MAGENTA}(VLESS / VMESS / TROJAN)${NC}                       ${BRIGHT_CYAN}${BOLD}║${NC}"
  echo -e "${BRIGHT_CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
}
print_section() {
  local title=$1
  echo -e "\n${BRIGHT_BLUE}${BOLD}────────────────────────────────────────${NC}"
  echo -e "${BRIGHT_BLUE}${BOLD}▶${NC} ${BRIGHT_WHITE}${BOLD}${title}${NC}"
  echo -e "${BRIGHT_BLUE}${BOLD}────────────────────────────────────────${NC}"
}

# ========== CLEANUP ==========
TMP_CONFIG=""
cleanup_temp() {
  [ -n "$TMP_CONFIG" ] && rm -f "$TMP_CONFIG" 2>/dev/null || true
}
trap cleanup_temp EXIT

on_error() {
  print_error "Script failed at line $1."
  if [ -n "${CURRENT_SERVICE:-}" ]; then
    print_warning "If a Cloud Run service named '${CURRENT_SERVICE}' was partially created, you can remove it with:"
    echo "    gcloud run services delete ${CURRENT_SERVICE} --region ${REGION:-us-central1} --quiet"
  fi
}
trap 'on_error ${LINENO}' ERR

# ========== REQUIRED GCP APIs ==========
declare -A REQUIRED_APIS=(
  [run]="run.googleapis.com|Cloud Run"
  [cloudbuild]="cloudbuild.googleapis.com|Cloud Build"
)

enable_required_apis() {
  print_section "Enabling Required GCP Services"
  if ! command -v gcloud >/dev/null 2>&1; then
    print_error "gcloud CLI not found. Install and authenticate first."
    exit 1
  fi
  print_success "gcloud CLI found"

  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "${PROJECT:-}" ]; then
    print_error "No GCP project set. Run 'gcloud init' or 'gcloud config set project PROJECT_ID'."
    exit 1
  fi
  print_success "GCP Project: ${PROJECT}"

  ENABLED_APIS=$(gcloud services list --enabled --format="value(name)" 2>/dev/null || true)
  APIS_TO_ENABLE=()
  for api_key in "${!REQUIRED_APIS[@]}"; do
    IFS='|' read -r api_name api_display <<< "${REQUIRED_APIS[$api_key]}"
    if echo "$ENABLED_APIS" | grep -q "$api_name"; then
      echo -e "  ${BRIGHT_GREEN}✓${NC} ${api_display} ${DIM}(${api_name})${NC} already enabled"
    else
      APIS_TO_ENABLE+=("$api_name")
    fi
  done
  if [ ${#APIS_TO_ENABLE[@]} -gt 0 ]; then
    print_info "Enabling ${#APIS_TO_ENABLE[@]} API(s)..."
    gcloud services enable "${APIS_TO_ENABLE[@]}" --quiet
    print_success "APIs enabled"
  fi
}

# Detect interactive mode
if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=true; else INTERACTIVE=false; fi

enable_required_apis
print_header

# ========== PRESETS ==========
declare -A PRESETS=(
  [production]="memory=2048|cpu=1|instances=16|concurrency=1000|timeout=3600"
  [budget]="memory=2048|cpu=2|instances=8|concurrency=1000|timeout=3600"
  [trojan-ws]="proto=trojan|memory=2048|cpu=1|instances=16|concurrency=1000|timeout=3600"
  [vless-ws]="proto=vless|memory=2048|cpu=1|instances=16|concurrency=1000|timeout=3600"
  [vmess-ws]="proto=vmess|memory=2048|cpu=1|instances=16|concurrency=1000|timeout=3600"
)

apply_preset() {
  local preset=$1
  [[ -v PRESETS[$preset] ]] || return
  local config="${PRESETS[$preset]}"
  IFS='|' read -ra settings <<< "$config"
  for setting in "${settings[@]}"; do
    IFS='=' read -r key value <<< "$setting"
    case "$key" in
      memory) MEMORY="$value" ;;
      cpu) CPU="$value" ;;
      instances) MAX_INSTANCES="$value" ;;
      concurrency) CONCURRENCY="$value" ;;
      timeout) TIMEOUT="$value" ;;
      proto) PRESET_PROTO="$value" ;;
    esac
  done
}

generate_random_service_name() {
  local chars="abcdefghijklmnopqrstuvwxyz"
  local name=""
  for i in {1..4}; do name="${name}${chars:$((RANDOM % ${#chars})):1}"; done
  echo "${name}sn"
}

# ========== REGIONS ==========
# Show every Cloud Run region returned by Google Cloud and let the user choose.
# Project/org location policies are intentionally not used to hide regions here:
# the project/lab is responsible for enforcing its own allowed locations.
# If a selected region is not permitted, Google Cloud will reject the deploy.

declare -A REGION_NAMES=(
  # Africa
  [africa-south1]="🇿🇦 South Africa — Johannesburg"

  # Asia
  [asia-east1]="🇹🇼 Taiwan — Taiwan"
  [asia-east2]="🇭🇰 Hong Kong — Hong Kong"
  [asia-northeast1]="🇯🇵 Japan — Tokyo"
  [asia-northeast2]="🇯🇵 Japan — Osaka"
  [asia-northeast3]="🇰🇷 South Korea — Seoul"
  [asia-south1]="🇮🇳 India — Mumbai"
  [asia-south2]="🇮🇳 India — Delhi"
  [asia-southeast1]="🇸🇬 Singapore — Singapore"
  [asia-southeast2]="🇮🇩 Indonesia — Jakarta"
  [asia-southeast3]="🇹🇭 Thailand — Bangkok"
  [asia-southeast4]="🇲🇾 Malaysia — Kuala Lumpur"

  # Australia
  [australia-southeast1]="🇦🇺 Australia — Sydney"
  [australia-southeast2]="🇦🇺 Australia — Melbourne"

  # Europe
  [europe-central2]="🇵🇱 Poland — Warsaw"
  [europe-north1]="🇫🇮 Finland — Hamina"
  [europe-north2]="🇸🇪 Sweden — Stockholm"
  [europe-southwest1]="🇪🇸 Spain — Madrid"
  [europe-west1]="🇧🇪 Belgium — St. Ghislain"
  [europe-west2]="🇬🇧 United Kingdom — London"
  [europe-west3]="🇩🇪 Germany — Frankfurt"
  [europe-west4]="🇳🇱 Netherlands — Eemshaven"
  [europe-west6]="🇨🇭 Switzerland — Zurich"
  [europe-west8]="🇮🇹 Italy — Milan"
  [europe-west9]="🇫🇷 France — Paris"
  [europe-west10]="🇩🇪 Germany — Berlin"
  [europe-west12]="🇮🇹 Italy — Turin"

  # Middle East
  [me-central1]="🇶🇦 Qatar — Doha"
  [me-central2]="🇸🇦 Saudi Arabia — Dammam"
  [me-west1]="🇮🇱 Israel — Tel Aviv"

  # North America
  [northamerica-northeast1]="🇨🇦 Canada — Montreal"
  [northamerica-northeast2]="🇨🇦 Canada — Toronto"
  [northamerica-south1]="🇲🇽 Mexico — Mexico"

  # South America
  [southamerica-east1]="🇧🇷 Brazil — São Paulo"
  [southamerica-west1]="🇨🇱 Chile — Santiago"

  # United States
  [us-central1]="🇺🇸 USA — Iowa"
  [us-east1]="🇺🇸 USA — South Carolina"
  [us-east4]="🇺🇸 USA — Northern Virginia"
  [us-east5]="🇺🇸 USA — Columbus"
  [us-east7]="🇺🇸 USA — Alabama"
  [us-south1]="🇺🇸 USA — Dallas"
  [us-west1]="🇺🇸 USA — Oregon"
  [us-west2]="🇺🇸 USA — Los Angeles"
  [us-west3]="🇺🇸 USA — Salt Lake City"
  [us-west4]="🇺🇸 USA — Las Vegas"
  [us-west8]="🇺🇸 USA — Phoenix"
)

get_region_name() { echo "${REGION_NAMES[$1]:-$1}"; }

load_cloud_run_regions() {
  SUGGESTED_REGIONS=()

  local available_regions
  available_regions="$(gcloud run regions list --platform=managed --format='value(name)' 2>/dev/null || true)"

  if [ -z "$available_regions" ]; then
    print_error "Could not retrieve the Cloud Run region list."
    print_info "Run: gcloud run regions list --platform=managed"
    return 1
  fi

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    SUGGESTED_REGIONS+=("$r")
  done <<< "$available_regions"

  [ "${#SUGGESTED_REGIONS[@]}" -gt 0 ]
}

show_regions() {
  echo ""
  echo "🌍 Cloud Run Regions:"
  echo ""
  local i=1
  for r in "${SUGGESTED_REGIONS[@]}"; do
    printf "%2d) %-42s (%s)\n" "$i" "$(get_region_name "$r")" "$r"
    ((i++))
  done
  echo ""
}

validate_region() {
  local requested="$1"

  if ! printf '%s\n' "${SUGGESTED_REGIONS[@]}" | grep -Fxq "$requested"; then
    print_error "Region '$requested' is not available in the Cloud Run region list."
    return 1
  fi

  return 0
}

# ========== PRESET SELECTION ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${PRESET_CHOICE:-}" ]; then
  print_section "Quick Start with Presets"
  echo -e "  ${BOLD}1${NC} production  ${DIM}2048MB, 1 CPU, 16 instances${NC}"
  echo -e "  ${BOLD}2${NC} trojan-ws   ${DIM}TROJAN protocol${NC}"
  echo -e "  ${BOLD}3${NC} vless-ws    ${DIM}VLESS protocol${NC}"
  echo -e "  ${BOLD}4${NC} vmess-ws    ${DIM}VMESS protocol${NC}"
  echo -e "  ${BOLD}5${NC} custom      ${DIM}configure everything manually${NC}"
  read -rp "Select preset [1-5] (default: 1): " PRESET_CHOICE
fi
PRESET_CHOICE="${PRESET_CHOICE:-1}"
case "$PRESET_CHOICE" in
  1) apply_preset "production"; PRESET_MODE="production" ;;
  2) apply_preset "trojan-ws"; PRESET_MODE="trojan-ws" ;;
  3) apply_preset "vless-ws"; PRESET_MODE="vless-ws" ;;
  4) apply_preset "vmess-ws"; PRESET_MODE="vmess-ws" ;;
  *) PRESET_MODE="custom" ;;
esac
print_success "Preset: $PRESET_MODE"

# ========== TELEGRAM (OPTIONAL — your own bot, your own chat) ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${BOT_TOKEN:-}" ]; then
  print_section "Telegram Notification (Optional — uses YOUR bot only)"
  read -rp "🤖 Bot Token (press Enter to skip): " BOT_TOKEN
fi
BOT_TOKEN="${BOT_TOKEN:-}"
if [ "${INTERACTIVE}" = true ] && [ -n "${BOT_TOKEN}" ] && [ -z "${CHAT_ID:-}" ]; then
  read -rp "💬 Chat ID: " CHAT_ID
fi
CHAT_ID="${CHAT_ID:-}"

send_telegram() {
  [ -z "${BOT_TOKEN}" ] || [ -z "${CHAT_ID}" ] && return 0
  local msg="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    -d "parse_mode=HTML" > /dev/null 2>&1 || true
}

# ========== PROTOCOL ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${PRESET_PROTO:-}" ]; then
  print_section "Choose Protocol"
  echo -e "  ${BOLD}1${NC} VLESS   ${DIM}Fast, modern, lightweight${NC}"
  echo -e "  ${BOLD}2${NC} VMESS   ${DIM}Compatible, widely supported${NC}"
  echo -e "  ${BOLD}3${NC} TROJAN  ${DIM}Camouflages as an HTTPS server${NC}"
  read -rp "Select protocol [1-3] (default: 1): " PROTO_CHOICE
  case "${PROTO_CHOICE:-1}" in
    1) PROTO="vless" ;; 2) PROTO="vmess" ;; 3) PROTO="trojan" ;; *) PROTO="vless" ;;
  esac
else
  PROTO="${PRESET_PROTO:-vless}"
fi
print_success "Protocol: $PROTO"

# ========== WS PATH ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${WSPATH:-}" ]; then
  read -rp "📡 WebSocket path (default: /ws): " WSPATH
fi
WSPATH="${WSPATH:-/ws}"
[[ "$WSPATH" == /* ]] || WSPATH="/$WSPATH"

# ========== REGION ==========
# Always show the complete Cloud Run region list returned by gcloud.
# We do not inspect/filter Organization Policy here; the lab/project itself
# will enforce any location restrictions when deployment is attempted.
if ! load_cloud_run_regions; then
  exit 1
fi

if [ "${INTERACTIVE}" = true ] && [ -z "${REGION:-}" ]; then
  show_regions
  read -rp "Select region [1-${#SUGGESTED_REGIONS[@]}] (default: 1): " REGION_IDX
  REGION_IDX="${REGION_IDX:-1}"

  if [[ "$REGION_IDX" =~ ^[0-9]+$ ]] &&
     [ "$REGION_IDX" -ge 1 ] &&
     [ "$REGION_IDX" -le "${#SUGGESTED_REGIONS[@]}" ]; then
    REGION="${SUGGESTED_REGIONS[$((REGION_IDX-1))]}"
  else
    print_error "Invalid region selection."
    exit 1
  fi
fi

REGION="${REGION:-${SUGGESTED_REGIONS[0]:-us-central1}}"

if ! validate_region "$REGION"; then
  exit 1
fi

print_success "Region: $REGION ($(get_region_name "$REGION"))"

# ========== SERVICE NAME ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${SERVICE:-}" ]; then
  SUGGESTED_NAME="$(generate_random_service_name)"
  read -rp "🪪 Service name (default: ${SUGGESTED_NAME}): " SERVICE
fi
SERVICE="${SERVICE:-$(generate_random_service_name)}"
CURRENT_SERVICE="$SERVICE"

UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"

# ========== OPTIONAL EXPIRATION NOTE ==========
if [ "${INTERACTIVE}" = true ] && [ -z "${TIMEEND:-}" ]; then
  read -rp "⏳ Planned teardown time, for your own notes (optional, e.g. '7d' or blank): " TIMEEND
fi
TIMEEND="${TIMEEND:-}"

# ========== PERFORMANCE SETTINGS ==========
print_section "Performance Settings"
[ -z "${MEMORY:-}" ] && [ "${INTERACTIVE}" = true ] && read -rp "💾 Memory MB [2048]: " MEMORY
MEMORY="${MEMORY:-2048}"
[ -z "${CPU:-}" ] && [ "${INTERACTIVE}" = true ] && read -rp "⚙️  CPU cores [1]: " CPU
CPU="${CPU:-1}"
[ -z "${TIMEOUT:-}" ] && [ "${INTERACTIVE}" = true ] && read -rp "⏱️  Timeout seconds [3600]: " TIMEOUT
TIMEOUT="${TIMEOUT:-3600}"
[ -z "${MAX_INSTANCES:-}" ] && [ "${INTERACTIVE}" = true ] && read -rp "📊 Max instances [16]: " MAX_INSTANCES
MAX_INSTANCES="${MAX_INSTANCES:-16}"
[ -z "${CONCURRENCY:-}" ] && [ "${INTERACTIVE}" = true ] && read -rp "🔗 Concurrency [1000]: " CONCURRENCY
CONCURRENCY="${CONCURRENCY:-1000}"

# ========== SUMMARY ==========
print_section "Configuration Summary"
echo "  Service   : $SERVICE"
echo "  Protocol  : $PROTO"
echo "  Path      : $WSPATH"
echo "  Region    : $REGION"
echo "  UUID      : $UUID"
echo "  Memory    : ${MEMORY}MB   CPU: ${CPU}   Timeout: ${TIMEOUT}s"
echo "  Instances : ${MAX_INSTANCES}   Concurrency: ${CONCURRENCY}"
[ -n "$TIMEEND" ] && echo "  Planned teardown (manual): $TIMEEND"

# ========== BUILD & DEPLOY ==========
PROJECT=$(gcloud config get-value project 2>/dev/null)
IMAGE="gcr.io/${PROJECT}/${SERVICE}:latest"

print_section "Building & Deploying"
print_info "Building image ${IMAGE} from this directory's Dockerfile..."
gcloud builds submit --tag "$IMAGE" .

gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --set-env-vars "PROTO=${PROTO},USER_ID=${UUID},WS_PATH=${WSPATH},NETWORK=ws,HOST=${SERVICE}.run.app" \
  --memory "${MEMORY}Mi" \
  --cpu "${CPU}" \
  --timeout "${TIMEOUT}" \
  --max-instances "${MAX_INSTANCES}" \
  --concurrency "${CONCURRENCY}" \
  --quiet

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)" 2>/dev/null)
HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"

# ========== SHARE LINK ==========
case "$PROTO" in
  vless)  SHARE_LINK="vless://${UUID}@${HOST}:443?type=ws&security=tls&path=${WSPATH}#amani-mora" ;;
  trojan) SHARE_LINK="trojan://${UUID}@${HOST}:443?type=ws&security=tls&path=${WSPATH}#amani-mora" ;;
  vmess)
    VMESS_JSON=$(cat <<EOF
{"v":"2","ps":"$SERVICE","add":"$HOST","port":"443","id":"$UUID","aid":"0","net":"ws","type":"none","host":"$HOST","path":"$WSPATH","tls":"tls"}
EOF
)
    SHARE_LINK="vmess://$(echo "$VMESS_JSON" | base64 -w 0)"
    ;;
esac

print_section "Deployment Complete"
echo "Host     : $HOST"
echo "Protocol : $PROTO"
echo "UUID     : $UUID"
echo "Path     : $WSPATH"
echo ""
echo "📎 Share link:"
echo "$SHARE_LINK"
echo ""
print_info "This link is shown to you only — nothing is sent anywhere else."

# Send to YOUR Telegram bot only, if configured
send_telegram "<b>AMANI-MORA deployment</b>%0AService: ${SERVICE}%0AHost: ${HOST}%0AProtocol: ${PROTO^^}%0ALink: ${SHARE_LINK}"
