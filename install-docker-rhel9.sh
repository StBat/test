#!/usr/bin/env bash
# =============================================================================
# install-docker-rhel9.sh
# Docker CE installatiescript voor Red Hat Enterprise Linux 9
#
# Gebruik:
#   sudo bash install-docker-rhel9.sh
#   sudo bash install-docker-rhel9.sh --data-root /apps/data/docker
#
# Opties:
#   --data-root DIR   Pad voor Docker data (standaard: /var/lib/docker)
#   --no-compose      Sla Docker Compose plugin over
#   --help            Toon deze hulp
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Kleurcodes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DOCKER_DATA_ROOT="/var/lib/docker"
INSTALL_COMPOSE=true

# ---------------------------------------------------------------------------
# Hulpfuncties
# ---------------------------------------------------------------------------
log()     { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${CYAN}>>> $* ${NC}"; }

die() {
    error "$*"
    exit 1
}

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Argumenten verwerken
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
            die "Onbekende optie: $1  (gebruik --help voor hulp)"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Precheck: root vereist
# ---------------------------------------------------------------------------
header "Voorbereidingen"
[[ $EUID -eq 0 ]] || die "Dit script moet als root (of via sudo) uitgevoerd worden."

# ---------------------------------------------------------------------------
# Precheck: RHEL 9
# ---------------------------------------------------------------------------
if [[ -f /etc/redhat-release ]]; then
    RHEL_VERSION=$(rpm -E '%{rhel}')
    log "Gevonden OS: $(cat /etc/redhat-release)"
    [[ "$RHEL_VERSION" -eq 9 ]] || warn "Dit script is getest op RHEL 9. Gevonden major versie: ${RHEL_VERSION}"
else
    die "Geen Red Hat-gebaseerd systeem gevonden (/etc/redhat-release ontbreekt)."
fi

# ---------------------------------------------------------------------------
# Verwijder eventuele conflicterende pakketten
# ---------------------------------------------------------------------------
header "Conflicterende pakketten opruimen"
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
    runc
)

for pkg in "${CONFLICT_PKGS[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
        log "Verwijder conflicterend pakket: $pkg"
        dnf remove -y "$pkg"
    fi
done

# ---------------------------------------------------------------------------
# Docker CE repository toevoegen
# ---------------------------------------------------------------------------
header "Docker CE repository configureren"
dnf install -y dnf-plugins-core

dnf config-manager --add-repo \
    https://download.docker.com/linux/rhel/docker-ce.repo

log "Docker repository toegevoegd."

# ---------------------------------------------------------------------------
# Docker CE installeren
# ---------------------------------------------------------------------------
header "Docker CE installeren"
dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin

log "Docker CE pakket geïnstalleerd."

# ---------------------------------------------------------------------------
# Docker Compose plugin (optioneel)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_COMPOSE" == true ]]; then
    header "Docker Compose plugin installeren"
    dnf install -y docker-compose-plugin
    log "Docker Compose plugin geïnstalleerd."
fi

# ---------------------------------------------------------------------------
# Aangepaste data-root configureren (indien afwijkend van standaard)
# ---------------------------------------------------------------------------
if [[ "$DOCKER_DATA_ROOT" != "/var/lib/docker" ]]; then
    header "Docker data-root instellen op: ${DOCKER_DATA_ROOT}"
    mkdir -p "$DOCKER_DATA_ROOT"
    chmod 710 "$DOCKER_DATA_ROOT"

    mkdir -p /etc/docker
    # Bewaar bestaande config als die er al is
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        warn "Bestaande daemon.json geback-upt naar daemon.json.bak"
    fi

    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
    log "daemon.json aangemaakt met data-root ${DOCKER_DATA_ROOT}"
fi

# ---------------------------------------------------------------------------
# SELinux — container_manage_cgroup indien nodig
# ---------------------------------------------------------------------------
header "SELinux controleren"
if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is actief (Enforcing). Docker CE is SELinux-compatibel op RHEL 9."
    # Optioneel: stel de juiste context in op de data-root
    if [[ "$DOCKER_DATA_ROOT" != "/var/lib/docker" ]]; then
        if command -v semanage &>/dev/null; then
            semanage fcontext -a -e /var/lib/docker "${DOCKER_DATA_ROOT}" 2>/dev/null || true
            restorecon -Rv "$DOCKER_DATA_ROOT" 2>/dev/null || true
            log "SELinux bestandscontext ingesteld voor ${DOCKER_DATA_ROOT}"
        else
            warn "semanage niet gevonden — installeer policycoreutils-python-utils voor SELinux-contextbeheer."
        fi
    fi
else
    log "SELinux is niet in Enforcing modus, geen aanpassingen nodig."
fi

# ---------------------------------------------------------------------------
# Firewall — Docker bridge toestaan (optioneel, pas aan naar wens)
# ---------------------------------------------------------------------------
header "Firewalld controleren"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --zone=trusted --add-interface=docker0 2>/dev/null || true
    firewall-cmd --reload
    log "docker0 interface toegevoegd aan trusted zone in firewalld."
else
    log "firewalld is niet actief, geen aanpassingen."
fi

# ---------------------------------------------------------------------------
# Docker service starten & inschakelen
# ---------------------------------------------------------------------------
header "Docker service starten"
systemctl enable --now docker
log "Docker service ingeschakeld en gestart."

# ---------------------------------------------------------------------------
# Huidige gebruiker toevoegen aan docker-groep (optioneel)
# ---------------------------------------------------------------------------
if [[ -n "${SUDO_USER:-}" ]]; then
    header "Gebruiker '${SUDO_USER}' toevoegen aan docker-groep"
    usermod -aG docker "$SUDO_USER"
    warn "Log uit en opnieuw in als '${SUDO_USER}' om docker zonder sudo te gebruiken."
fi

# ---------------------------------------------------------------------------
# Verificatie
# ---------------------------------------------------------------------------
header "Verificatie"
docker --version
docker info --format '{{.ServerVersion}}' 2>/dev/null | { read -r ver; log "Docker server versie: ${ver}"; }

if [[ "$INSTALL_COMPOSE" == true ]]; then
    docker compose version
fi

# ---------------------------------------------------------------------------
# Samenvatting
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Docker CE succesvol geïnstalleerd op RHEL 9!        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Data-root : %-39s${GREEN}║${NC}\n" "$DOCKER_DATA_ROOT"
printf  "${GREEN}║${NC}  Compose   : %-39s${GREEN}║${NC}\n" "$( [[ $INSTALL_COMPOSE == true ]] && echo 'ja' || echo 'nee' )"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
log "Test met:  docker run --rm hello-world"
