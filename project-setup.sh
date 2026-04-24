#!/bin/bash

# =============================================================================
# PostgreSQL Project Setup Script
# =============================================================================
#
# Creates a database and role for a specific project:
# - Role: <project_name>db (LOGIN, no superuser, no createdb, no createrole)
# - Database: <project_name> (owned by the role)
# - pg_hba.conf: scram-sha-256 rules for localhost (IPv4 + IPv6)
#
# Must be run with sudo.
#
# Usage: sudo ./setup-project.sh <project_name>
# Example: sudo ./setup-project.sh alma
#   -> Creates role 'almadb', database 'alma'
# =============================================================================

set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PGDATA="/var/lib/postgres/data"
PG_HBA="${PGDATA}/pg_hba.conf"

# =============================================================================
# Helper functions
# =============================================================================

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }
error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

confirm() {
    local prompt="$1"
    local response
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" response
    [[ "${response}" =~ ^[Yy]$ ]]
}

# =============================================================================
# Pre-flight checks
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    error "This script must be run with sudo."
fi

if [[ $# -lt 1 ]]; then
    error "Usage: sudo ./setup-project.sh <project_name>"
fi

if ! systemctl is-active postgresql &>/dev/null; then
    error "PostgreSQL is not running. Start it first or run setup-server.sh."
fi

# =============================================================================
# Variables
# =============================================================================

PROJECT_NAME="$1"
ROLE_NAME="${PROJECT_NAME}db"
DB_NAME="${PROJECT_NAME}"

# Validate project name (alphanumeric and underscores only)
if [[ ! "${PROJECT_NAME}" =~ ^[a-z][a-z0-9_]*$ ]]; then
    error "Project name must start with a lowercase letter and contain only lowercase letters, numbers and underscores."
fi

echo ""
echo "========================================="
echo " PostgreSQL Project Setup"
echo "========================================="
echo ""
info "Project name: ${PROJECT_NAME}"
info "Role name:    ${ROLE_NAME}"
info "Database:     ${DB_NAME}"
echo ""

# =============================================================================
# Step 1: Create role
# =============================================================================

echo "========================================="
echo " Step 1: Role"
echo "========================================="

ROLE_EXISTS=$(sudo -iu postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${ROLE_NAME}'" 2>/dev/null || echo "")

if [[ "${ROLE_EXISTS}" == "1" ]]; then
    warn "Role '${ROLE_NAME}' already exists. Skipping."
else
    # Prompt for password
    while true; do
        read -srp "$(echo -e "${CYAN}Enter password for role '${ROLE_NAME}': ${NC}")" ROLE_PASSWORD
        echo ""
        read -srp "$(echo -e "${CYAN}Confirm password: ${NC}")" ROLE_PASSWORD_CONFIRM
        echo ""

        if [[ "${ROLE_PASSWORD}" == "${ROLE_PASSWORD_CONFIRM}" ]]; then
            if [[ -z "${ROLE_PASSWORD}" ]]; then
                echo -e "${RED}Password cannot be empty.${NC}"
                continue
            fi
            break
        else
            echo -e "${RED}Passwords do not match. Try again.${NC}"
        fi
    done

    info "Creating role '${ROLE_NAME}'..."
    sudo -iu postgres psql -c "CREATE ROLE ${ROLE_NAME} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${ROLE_PASSWORD}'" &>/dev/null
    success "Role '${ROLE_NAME}' created."
fi

# =============================================================================
# Step 2: Create database
# =============================================================================

echo ""
echo "========================================="
echo " Step 2: Database"
echo "========================================="

DB_EXISTS=$(sudo -iu postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" 2>/dev/null || echo "")

if [[ "${DB_EXISTS}" == "1" ]]; then
    warn "Database '${DB_NAME}' already exists. Skipping."
else
    info "Creating database '${DB_NAME}' with owner '${ROLE_NAME}'..."
    sudo -iu postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${ROLE_NAME}" &>/dev/null
    success "Database '${DB_NAME}' created."
fi

# =============================================================================
# Step 3: pg_hba.conf rules
# =============================================================================

echo ""
echo "========================================="
echo " Step 3: Authentication Rules"
echo "========================================="

# Check if rules already exist for this role
if grep -q "host\s\+${DB_NAME}\s\+${ROLE_NAME}" "${PG_HBA}" 2>/dev/null; then
    warn "Authentication rules for '${ROLE_NAME}' already exist in pg_hba.conf. Skipping."
else
    info "Adding scram-sha-256 rules for '${ROLE_NAME}' to pg_hba.conf..."

    {
        echo ""
        echo "# [pg-setup] Project: ${PROJECT_NAME}"
        echo "host    ${DB_NAME}            ${ROLE_NAME}          127.0.0.1/32            scram-sha-256"
        echo "host    ${DB_NAME}            ${ROLE_NAME}          ::1/128                 scram-sha-256"
    } >>"${PG_HBA}"

    # Reload to apply changes
    systemctl reload postgresql

    success "Authentication rules added and PostgreSQL reloaded."
fi

# =============================================================================
# Step 4: Validate connection
# =============================================================================

echo ""
echo "========================================="
echo " Step 4: Validation"
echo "========================================="

info "Testing connection as '${ROLE_NAME}' to database '${DB_NAME}'..."
echo ""
info "Run the following command to test manually:"
echo ""
echo "  psql -U ${ROLE_NAME} -d ${DB_NAME} -h 127.0.0.1"
echo ""

# =============================================================================
# Done
# =============================================================================

echo "========================================="
echo -e " ${GREEN}Project '${PROJECT_NAME}' setup complete.${NC}"
echo "========================================="
echo ""
info "Role:     ${ROLE_NAME} (login, no superuser, no createdb, no createrole)"
info "Database: ${DB_NAME} (owner: ${ROLE_NAME})"
info "Auth:     scram-sha-256 via localhost (IPv4 + IPv6)"
echo ""
info "Add these to your application's .env:"
echo ""
echo "  DB_CONNECTION=pgsql"
echo "  DB_HOST=127.0.0.1"
echo "  DB_PORT=5432"
echo "  DB_DATABASE=${DB_NAME}"
echo "  DB_USERNAME=${ROLE_NAME}"
echo "  DB_PASSWORD=<your_password>"
echo ""
