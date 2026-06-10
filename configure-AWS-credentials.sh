#!/usr/bin/env bash
# =============================================================================
# configure-aws-credentials.sh
# Interactively configure AWS credentials (~/.aws/credentials)
#
# Usage:
#   bash configure-aws-credentials.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${CYAN}>>> $*${NC}"; }
die()    { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Collect input
# ---------------------------------------------------------------------------
header "AWS Credentials Configuration"

read -rp "  AWS Profile name [default]: " AWS_PROFILE
AWS_PROFILE=${AWS_PROFILE:-default}

read -rp "  AWS Access Key ID: " AWS_ACCESS_KEY
[[ -n "$AWS_ACCESS_KEY" ]] || die "Access Key ID cannot be empty."

read -rsp "  AWS Secret Access Key: " AWS_SECRET_KEY
echo ""
[[ -n "$AWS_SECRET_KEY" ]] || die "Secret Access Key cannot be empty."

read -rp "  Default region [eu-west-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-eu-west-1}

read -rp "  Default output format [json]: " AWS_OUTPUT
AWS_OUTPUT=${AWS_OUTPUT:-json}

# ---------------------------------------------------------------------------
# Create ~/.aws directory
# ---------------------------------------------------------------------------
header "Writing credentials"
AWS_DIR="${HOME}/.aws"
mkdir -p "${AWS_DIR}"
chmod 700 "${AWS_DIR}"

CREDENTIALS_FILE="${AWS_DIR}/credentials"
CONFIG_FILE="${AWS_DIR}/config"

# ---------------------------------------------------------------------------
# Backup existing files if present
# ---------------------------------------------------------------------------
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    cp "${CREDENTIALS_FILE}" "${CREDENTIALS_FILE}.bak"
    warn "Existing credentials backed up to credentials.bak"
fi

if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
    warn "Existing config backed up to config.bak"
fi

# ---------------------------------------------------------------------------
# Write credentials file
# ---------------------------------------------------------------------------
cat > "${CREDENTIALS_FILE}" <<CREDS
[${AWS_PROFILE}]
aws_access_key_id = ${AWS_ACCESS_KEY}
aws_secret_access_key = ${AWS_SECRET_KEY}
CREDS

chmod 600 "${CREDENTIALS_FILE}"

# ---------------------------------------------------------------------------
# Write config file
# ---------------------------------------------------------------------------
CONFIG_PROFILE=$( [[ "$AWS_PROFILE" == "default" ]] && echo "default" || echo "profile ${AWS_PROFILE}" )

cat > "${CONFIG_FILE}" <<CONFIG
[${CONFIG_PROFILE}]
region = ${AWS_REGION}
output = ${AWS_OUTPUT}
CONFIG

chmod 600 "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
header "Verification"
if command -v aws &>/dev/null; then
    aws sts get-caller-identity --profile "${AWS_PROFILE}" 2>/dev/null \
        && log "✓ AWS credentials verified successfully." \
        || warn "Could not verify credentials via sts:GetCallerIdentity — check key validity."
else
    warn "AWS CLI not installed — skipping live verification."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  AWS credentials configured successfully!            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Profile     : %-37s${GREEN}║${NC}\n" "${AWS_PROFILE}"
printf  "${GREEN}║${NC}  Region      : %-37s${GREEN}║${NC}\n" "${AWS_REGION}"
printf  "${GREEN}║${NC}  Credentials : %-37s${GREEN}║${NC}\n" "${CREDENTIALS_FILE}"
printf  "${GREEN}║${NC}  Config      : %-37s${GREEN}║${NC}\n" "${CONFIG_FILE}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
