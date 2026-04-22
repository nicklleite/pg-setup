#!/bin/bash

# ==============================================================================
# PostgreSQL Server Setup — Arch Linux
# ==============================================================================
#
# Installs and configures PostgreSQL from scratch on Arch Linux.
# Designed to be idempotent: detects completed steps and skips them.
#
# What this script does:
#   1. Installs the PostgreSQL package via pacman
#   2. Generates pt_BR.UTF-8 locale if missing
#   3. Initializes the database cluster (initdb)
#   4. Configures pg_hba.conf (removes trust, sets peer for superuser)
#   5. Calculates and applies performance tuning based on hardware
#   6. Enables and starts the PostgreSQL service
#
# Usage: sudo ./setup-server.sh
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
PGDATA="/var/lib/postgres/data"
PG_CONF="${PGDATA}/postgresql.conf"
PG_HBA="${PGDATA}/pg_hba.conf"
LOCALE="pt_BR.UTF-8"
ENCODING="UTF8"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }
error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${CYAN}${prompt} [y/N]:${NC} ")" answer
    [[ "${answer,,}" == "y" ]]
}

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

echo ""
echo "============================================="
echo " PostgreSQL Server Setup — Arch Linux"
echo "============================================="
echo ""

# ==============================================================================
# Step 1 — Install PostgreSQL package
# ==============================================================================
info "Step 1: PostgreSQL package"

if pacman -Qs "^postgresql$" &>/dev/null; then
    PG_VERSION=$(pacman -Q postgresql | awk '{print $2}')
    warn "PostgreSQL already installed (${PG_VERSION}). Skipping."
else
    info "Installing PostgreSQL..."
    pacman -S --noconfirm postgresql
    success "PostgreSQL installed."
fi

echo ""

# ==============================================================================
# Step 2 — Generate locale
# ==============================================================================
info "Step 2: Locale ${LOCALE}"

if locale -a 2>/dev/null | grep -qi "pt_br.utf8"; then
    warn "Locale ${LOCALE} already available. Skipping."
else
    info "Generating locale ${LOCALE}..."

    LOCALE_GEN="/etc/locale.gen"
    if grep -q "^#\s*${LOCALE}" "${LOCALE_GEN}"; then
        sed -i "s/^#\s*\(${LOCALE}\)/\1/" "${LOCALE_GEN}"
    elif ! grep -q "^${LOCALE}" "${LOCALE_GEN}"; then
        echo "${LOCALE} UTF-8" >>"${LOCALE_GEN}"
    fi

    locale-gen
    success "Locale ${LOCALE} generated."
fi

echo ""

# ==============================================================================
# Step 3 — Initialize database cluster
# ==============================================================================
info "Step 3: Database cluster initialization"

if [[ -f "${PGDATA}/PG_VERSION" ]]; then
    warn "Cluster already initialized at ${PGDATA}. Skipping."
else
    info "Initializing cluster..."
    sudo -iu postgres initdb -D "${PGDATA}" -E "${ENCODING}" --locale="${LOCALE}"
    success "Cluster initialized at ${PGDATA}."
fi

echo ""

# ==============================================================================
# Step 4 — Configure pg_hba.conf
# ==============================================================================
info "Step 4: Authentication (pg_hba.conf)"

if grep -q "^local\s\+all\s\+postgres\s\+peer" "${PG_HBA}" &&
    ! grep -q "^local\s\+all\s\+all\s\+trust" "${PG_HBA}" &&
    ! grep -q "^host\s\+all\s\+all.*trust" "${PG_HBA}"; then
    warn "pg_hba.conf already configured. Skipping."
else
    info "Configuring pg_hba.conf..."

    # Comment out all existing trust rules
    sed -i 's/^\(local\s\+all\s\+all\s\+trust\)/#\1/' "${PG_HBA}"
    sed -i 's/^\(host\s\+all\s\+all\s\+.*trust\)/#\1/' "${PG_HBA}"
    sed -i 's/^\(local\s\+replication\s\+all\s\+trust\)/#\1/' "${PG_HBA}"
    sed -i 's/^\(host\s\+replication\s\+all\s\+.*trust\)/#\1/' "${PG_HBA}"

    # Add peer authentication for superuser via Unix socket
    if ! grep -q "^local\s\+all\s\+postgres\s\+peer" "${PG_HBA}"; then
        echo "" >>"${PG_HBA}"
        echo "# Added by pg-setup" >>"${PG_HBA}"
        echo "local   all             postgres                                peer" >>"${PG_HBA}"
    fi

    success "pg_hba.conf configured (trust removed, peer for postgres)."
fi

echo ""

# ==============================================================================
# Step 5 — Performance tuning
# ==============================================================================
info "Step 5: Performance tuning (postgresql.conf)"

# --- Detect RAM ---
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))
RAM_GB=$((RAM_MB / 1024))

# --- Calculate memory parameters ---
SHARED_BUFFERS_MB=$((RAM_MB / 4))
EFFECTIVE_CACHE_SIZE_MB=$((RAM_MB * 3 / 4))
WORK_MEM_MB=$((RAM_MB / 512))
MAINTENANCE_WORK_MEM_MB=$((RAM_MB / 64))

# Minimum safeguards
[[ ${WORK_MEM_MB} -lt 4 ]] && WORK_MEM_MB=4
[[ ${MAINTENANCE_WORK_MEM_MB} -lt 64 ]] && MAINTENANCE_WORK_MEM_MB=64

# --- Format values for display and config ---
if [[ ${SHARED_BUFFERS_MB} -ge 1024 ]]; then
    SHARED_BUFFERS_VAL="$((SHARED_BUFFERS_MB / 1024))GB"
else
    SHARED_BUFFERS_VAL="${SHARED_BUFFERS_MB}MB"
fi

if [[ ${EFFECTIVE_CACHE_SIZE_MB} -ge 1024 ]]; then
    EFFECTIVE_CACHE_SIZE_VAL="$((EFFECTIVE_CACHE_SIZE_MB / 1024))GB"
else
    EFFECTIVE_CACHE_SIZE_VAL="${EFFECTIVE_CACHE_SIZE_MB}MB"
fi

WORK_MEM_VAL="${WORK_MEM_MB}MB"
MAINTENANCE_WORK_MEM_VAL="${MAINTENANCE_WORK_MEM_MB}MB"

# --- Detect disk type ---
PG_MOUNT=$(df "${PGDATA}" 2>/dev/null | tail -1 | awk '{print $1}')
PG_DISK=$(lsblk -no PKNAME "${PG_MOUNT}" 2>/dev/null | head -1)

if [[ -z "${PG_DISK}" ]]; then
    PG_DISK=$(echo "${PG_MOUNT}" | sed 's|/dev/||' | sed 's/[0-9]*$//' | sed 's/p$//')
fi

IS_ROTATIONAL=$(lsblk -dno ROTA "/dev/${PG_DISK}" 2>/dev/null || echo "1")

if [[ "${IS_ROTATIONAL}" == "0" ]]; then
    DISK_TYPE="SSD/NVMe"
    RANDOM_PAGE_COST="1.1"
    EFFECTIVE_IO_CONCURRENCY="200"
else
    DISK_TYPE="HDD"
    RANDOM_PAGE_COST="4.0"
    EFFECTIVE_IO_CONCURRENCY="2"
fi

# --- Display calculated values ---
echo ""
echo "  Hardware detected:"
echo "    RAM:  ${RAM_GB}GB (${RAM_MB}MB)"
echo "    Disk: ${DISK_TYPE} (/dev/${PG_DISK})"
echo ""
echo "  Proposed configuration:"
echo "    shared_buffers           = ${SHARED_BUFFERS_VAL}"
echo "    effective_cache_size     = ${EFFECTIVE_CACHE_SIZE_VAL}"
echo "    work_mem                 = ${WORK_MEM_VAL}"
echo "    maintenance_work_mem     = ${MAINTENANCE_WORK_MEM_VAL}"
echo "    random_page_cost         = ${RANDOM_PAGE_COST}"
echo "    effective_io_concurrency = ${EFFECTIVE_IO_CONCURRENCY}"
echo ""

if confirm "Apply these settings?"; then
    # Updates a postgresql.conf parameter.
    # Handles both commented (#param = value) and uncommented (param = value) lines.
    apply_param() {
        local param="$1"
        local value="$2"
        local file="${PG_CONF}"

        if grep -qE "^\s*#?\s*${param}\s*=" "${file}"; then
            sed -i -E "s|^\s*#?\s*${param}\s*=.*|${param} = ${value}|" "${file}"
        else
            echo "${param} = ${value}" >>"${file}"
        fi
    }

    apply_param "shared_buffers" "${SHARED_BUFFERS_VAL}"
    apply_param "effective_cache_size" "${EFFECTIVE_CACHE_SIZE_VAL}"
    apply_param "work_mem" "${WORK_MEM_VAL}"
    apply_param "maintenance_work_mem" "${MAINTENANCE_WORK_MEM_VAL}"
    apply_param "random_page_cost" "${RANDOM_PAGE_COST}"
    apply_param "effective_io_concurrency" "${EFFECTIVE_IO_CONCURRENCY}"

    success "Performance settings applied to postgresql.conf."
else
    warn "Performance tuning skipped by user."
fi

echo ""

# ==============================================================================
# Step 6 — Enable and start service
# ==============================================================================
info "Step 6: PostgreSQL service"

if systemctl is-active --quiet postgresql; then
    info "Service is running. Restarting to apply changes..."
    systemctl restart postgresql
    success "PostgreSQL restarted."
elif systemctl is-enabled --quiet postgresql; then
    info "Service is enabled but not running. Starting..."
    systemctl start postgresql
    success "PostgreSQL started."
else
    info "Enabling and starting PostgreSQL..."
    systemctl enable --now postgresql
    success "PostgreSQL enabled and started."
fi

echo ""

# ==============================================================================
# Done
# ==============================================================================
echo "============================================="
echo -e " ${GREEN}PostgreSQL server setup complete.${NC}"
echo "============================================="
echo ""
echo "  Next step: use setup-project.sh to create"
echo "  a database and role for your project."
echo ""
