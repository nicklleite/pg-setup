# pg-setup

Bash scripts for installing and configuring PostgreSQL on Arch Linux.

## Purpose

These scripts automate the full PostgreSQL setup process — from package installation to hardware-based performance tuning — so that a clean Arch Linux installation can have a properly configured PostgreSQL server in minutes.

The goal is to have a reproducible, well-documented setup that can be reused across machines while keeping every configuration decision visible and intentional.

## Scripts

### `setup-server.sh`

Installs and configures the PostgreSQL server. Run **once per machine**.

What it does:

1. Installs the `postgresql` package via `pacman`
2. Generates `pt_BR.UTF-8` locale if missing
3. Initializes the database cluster (`initdb`)
4. Secures `pg_hba.conf` — removes default `trust` authentication, sets `peer` for the `postgres` superuser
5. Detects hardware (RAM, disk type) and calculates performance parameters
6. Displays proposed values and asks for confirmation before applying
7. Enables and starts the PostgreSQL service

The script is **idempotent**: it detects completed steps and skips them.

```bash
sudo ./setup-server.sh
```

#### Performance parameters calculated

| Parameter | Formula | Purpose |
|---|---|---|
| `shared_buffers` | RAM / 4 | Data page cache |
| `effective_cache_size` | RAM × 3/4 | Query planner hint (does not allocate memory) |
| `work_mem` | RAM / 512 | Per-operation memory for sorts and hashes |
| `maintenance_work_mem` | RAM / 64 | Memory for VACUUM, CREATE INDEX, ALTER TABLE |
| `random_page_cost` | SSD: 1.1 / HDD: 4.0 | I/O cost estimate for the query planner |
| `effective_io_concurrency` | SSD: 200 / HDD: 2 | Parallel I/O requests |

### `setup-project.sh`

Creates a dedicated role and database for a specific project. Run **once per project**.

What it does:

1. Creates a role named `<project_name>db` with `LOGIN`, `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`
2. Prompts for a password (with confirmation)
3. Creates a database named `<project_name>` owned by the new role
4. Adds `scram-sha-256` authentication rules to `pg_hba.conf` (IPv4 + IPv6)
5. Reloads PostgreSQL to apply the new rules

The script is **idempotent**: it detects existing roles, databases, and rules, and skips them.

```bash
sudo ./setup-project.sh alma
# → Creates role 'almadb', database 'alma', authentication rules
```

## Requirements

- Arch Linux
- Root access (`sudo`)

## Authentication model

| User | Connection type | Method | Scope |
|---|---|---|---|
| `postgres` (superuser) | Unix socket (`local`) | `peer` | All databases |
| Project roles | TCP (`host`, `127.0.0.1`) | `scram-sha-256` | Own database only |

## License

MIT
