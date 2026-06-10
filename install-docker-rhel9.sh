#!/usr/bin/env bash
# =============================================================================
# install-docker-rhel9.sh
# Docker CE installation script for Red Hat Enterprise Linux 9
#
# Usage:
#   sudo bash install-docker-rhel9.sh
#   sudo bash install-docker-rhel9.sh --data-root /apps/data/docker
#
# Options:
#   --data-root DIR   Path for Docker data (default: /apps/data/docker)
#   --no-compose      Skip Docker Compose plugin
#   --help            Show this help
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${CYAN}>>> $*${NC}"; }
die()    { error "$*"; exit 1; }

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DOCKER_DATA_ROOT="/apps/data/docker"
INSTALL_COMPOSE=true

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-root)
            DOCKER_DATA_ROOT="$2"
            shift 2
            ;;
        --no-compose)
            INSTALL_COMPOSE=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1  (use --help for usage)"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Precheck: root required
# ---------------------------------------------------------------------------
header "Pre-flight checks"
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."

# Precheck: RHEL 9
if [[ -f /etc/redhat-release ]]; then
    RHEL_VERSION=$(rpm -E '%{rhel}')
    log "Detected OS: $(cat /etc/redhat-release)"
    [[ "$RHEL_VERSION" -eq 9 ]] || warn "This script was tested on RHEL 9. Detected major version: ${RHEL_VERSION}"
else
    die "No Red Hat-based system detected (/etc/redhat-release not found)."
fi

# Precheck: disk space on data-root parent
DATA_PARENT=$(dirname "${DOCKER_DATA_ROOT}")
mkdir -p "${DATA_PARENT}"
AVAIL=$(df -BG "${DATA_PARENT}" | awk 'NR==2 {gsub("G",""); print $4}')
log "Available space on ${DATA_PARENT}: ${AVAIL}GiB"
[[ "$AVAIL" -ge 10 ]] || warn "Less than 10GiB free on ${DATA_PARENT} — consider freeing up disk space."

# ---------------------------------------------------------------------------
# Remove conflicting packages (podman, old docker variants)
# ---------------------------------------------------------------------------
header "Removing conflicting packages"
CONFLICT_PKGS=(
    docker
    docker-client
    docker-client-latest
    docker-common
    docker-latest
    docker-latest-logrotate
    docker-logrotate
    docker-engine
    podman
    podman-docker
    runc
)

for pkg in "${CONFLICT_PKGS[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
        log "Removing conflicting package: $pkg"
        dnf remove -y "$pkg"
    fi
done

# Clean up any leftover DOCKER_HOST set by podman-docker
if grep -r "DOCKER_HOST" /etc/environment /etc/profile.d/ 2>/dev/null | grep -q podman; then
    warn "Found podman DOCKER_HOST override — removing..."
    sed -i '/DOCKER_HOST.*podman/d' /etc/environment 2>/dev/null || true
    find /etc/profile.d/ -name "*.sh" -exec sed -i '/DOCKER_HOST.*podman/d' {} \; 2>/dev/null || true
    log "Cleaned up DOCKER_HOST overrides."
fi

# ---------------------------------------------------------------------------
# Add Docker CE repository
# ---------------------------------------------------------------------------
header "Configuring Docker CE repository"
dnf install -y dnf-plugins-core

# Only add repo if not already present
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    log "Docker CE repository added."
else
    log "Docker CE repository already present — skipping."
fi

# ---------------------------------------------------------------------------
# Install Docker CE
# ---------------------------------------------------------------------------
header "Installing Docker CE"
dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin

log "Docker CE packages installed."

# Docker Compose plugin
if [[ "$INSTALL_COMPOSE" == true ]]; then
    header "Installing Docker Compose plugin"
    dnf install -y docker-compose-plugin
    log "Docker Compose plugin installed."
fi

# ---------------------------------------------------------------------------
# Configure data-root
# ---------------------------------------------------------------------------
header "Configuring Docker data-root: ${DOCKER_DATA_ROOT}"
mkdir -p "${DOCKER_DATA_ROOT}"
chmod 710 "${DOCKER_DATA_ROOT}"

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<DAEMON
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DAEMON

log "daemon.json written:"
cat /etc/docker/daemon.json

# ---------------------------------------------------------------------------
# SELinux — set file context on custom data-root
# ---------------------------------------------------------------------------
header "Configuring SELinux"
if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is active (Enforcing)."
    if command -v semanage &>/dev/null; then
        semanage fcontext -a -e /var/lib/docker "${DOCKER_DATA_ROOT}" 2>/dev/null || \
        semanage fcontext -m -e /var/lib/docker "${DOCKER_DATA_ROOT}" 2>/dev/null || true
        restorecon -Rv "${DOCKER_DATA_ROOT}" 2>/dev/null || true
        log "SELinux file context set for ${DOCKER_DATA_ROOT}"
    else
        warn "semanage not found — install policycoreutils-python-utils for SELinux context management."
    fi
else
    log "SELinux not in Enforcing mode — no changes needed."
fi

# ---------------------------------------------------------------------------
# Firewalld — let Docker manage its own rules, do NOT add docker0 manually
# ---------------------------------------------------------------------------
header "Checking firewalld"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    # Remove docker0 from any zone in case it was added previously
    for zone in $(firewall-cmd --get-active-zones 2>/dev/null | grep -v "interfaces\|sources" | tr -d ' '); do
        firewall-cmd --permanent --zone="${zone}" --remove-interface=docker0 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    log "Firewalld cleaned up — Docker will manage its own rules."
else
    log "firewalld is not active — no changes needed."
fi

# ---------------------------------------------------------------------------
# Enable and start Docker
# ---------------------------------------------------------------------------
header "Starting Docker service"
systemctl daemon-reload
systemctl enable --now docker

# Wait up to 10 seconds for Docker to become ready
for i in {1..10}; do
    if docker info &>/dev/null; then
        break
    fi
    sleep 1
done

if ! docker info &>/dev/null; then
    error "Docker started but API is not responding. Check: journalctl -xeu docker.service"
    exit 1
fi

log "Docker service enabled and running."

# ---------------------------------------------------------------------------
# Add invoking user to docker group (avoids sudo for docker commands)
# ---------------------------------------------------------------------------
if [[ -n "${SUDO_USER:-}" ]]; then
    header "Adding '${SUDO_USER}' to docker group"
    usermod -aG docker "$SUDO_USER"
    warn "Log out and back in as '${SUDO_USER}' to use Docker without sudo."
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
header "Verification"
docker --version
ACTUAL_ROOT=$(docker info --format '{{.DockerRootDir}}')
log "Docker server version : $(docker info --format '{{.ServerVersion}}')"
log "Docker root dir       : ${ACTUAL_ROOT}"

if [[ "$ACTUAL_ROOT" != "$DOCKER_DATA_ROOT" ]]; then
    warn "Data-root mismatch! Expected: ${DOCKER_DATA_ROOT} — Got: ${ACTUAL_ROOT}"
else
    log "✓ Data-root correctly set to ${DOCKER_DATA_ROOT}"
fi

if [[ "$INSTALL_COMPOSE" == true ]]; then
    docker compose version
fi

log "Running hello-world container test..."
docker run --rm hello-world && log "✓ Container test passed." || warn "Container test failed — check Docker logs."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Docker CE successfully installed on RHEL 9!         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Data-root : %-39s${GREEN}║${NC}\n" "${DOCKER_DATA_ROOT}"
printf  "${GREEN}║${NC}  Containers: %-39s${GREEN}║${NC}\n" "${DOCKER_DATA_ROOT}/containers"
printf  "${GREEN}║${NC}  Images    : %-39s${GREEN}║${NC}\n" "${DOCKER_DATA_ROOT}/image"
printf  "${GREEN}║${NC}  Volumes   : %-39s${GREEN}║${NC}\n" "${DOCKER_DATA_ROOT}/volumes"
printf  "${GREEN}║${NC}  Compose   : %-39s${GREEN}║${NC}\n" "$( [[ $INSTALL_COMPOSE == true ]] && echo 'yes' || echo 'no' )"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
