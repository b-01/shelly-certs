#!/usr/bin/env bash
# install.sh: sets up shelly-certs in the folder this script is in. Run as root. Running it again
# is safe: it only adds what is missing and rewrites the generated units.
#
# It runs in two parts. Part 1 creates the system user shelly-certs, the folders, sets ownership
# and modes, and checks the config with `shelly-certs validate`. Only when the config is valid,
# part 2 writes the systemd units to systemd/generated/, links the units into systemd and enables
# the timer. Otherwise it says what to fix and stops, and the next run tries part 2 again. It
# refuses to replace any file that isn't one of its own links.
set -euo pipefail

SC_ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=lib/install.sh
source "$SC_ROOT/lib/install.sh"

if [[ $# -gt 0 ]]; then
	err "install.sh takes no arguments, it sets up the folder it is in ($SC_ROOT)"
	exit 2
fi
require_root
check_install_path "$SC_ROOT" || exit 1
check_dependencies || exit 1

# Check every link first, so nothing changes when one of them is in the way.
links_ok=1
while read -r link target; do
	if [[ $(link_state "$link" "$target") == foreign ]]; then
		err "$link exists and is not a link to $target. Remove it yourself if it is no longer needed"
		links_ok=0
	fi
done < <(install_links)
[[ $links_ok == 1 ]] || exit 1

if ! getent passwd "$SERVICE_USER" >/dev/null; then
	# The data folder is the home folder, so nothing the service writes ends up elsewhere.
	useradd --system --user-group --no-create-home --home-dir "$SC_ROOT/data" \
		--shell "$(command -v nologin || echo /bin/false)" "$SERVICE_USER"
	log "created system user $SERVICE_USER"
fi

# Ownership and modes: the service user owns data/ (the only place it writes) and secrets/ (which
# it reads). The rest of the folder, config/ included, stays owned by root and readable by everyone.
mkdir -p "$SC_ROOT/data" "$SC_ROOT/secrets"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SC_ROOT/data" "$SC_ROOT/secrets"
chmod 700 "$SC_ROOT/data" "$SC_ROOT/secrets"
find "$SC_ROOT/secrets" -type f -exec chmod 600 {} +
if ! runuser -u "$SERVICE_USER" -- test -x "$SC_ROOT/bin/shelly-certs"; then
	die "user $SERVICE_USER can't run $SC_ROOT/bin/shelly-certs. Make $SC_ROOT and its parent folders readable (for example chmod 755)"
fi

# Part 2 only starts with a valid config, so the timer never runs without one. Checked as the
# service user, so it also catches files the service can't read.
if ! runuser -u "$SERVICE_USER" -- "$SC_ROOT/bin/shelly-certs" validate; then
	err "the config is missing or has errors, so the systemd units are not installed yet"
	log "next: finish the config (see README.md, 'Configuration'), then run: sudo $SC_ROOT/install.sh"
	exit 1
fi

mkdir -p "$SC_ROOT/systemd/generated"
for unit in "${UNITS[@]}"; do
	render_unit "$SC_ROOT/systemd/$unit" "$SC_ROOT/systemd/generated/$unit" "$SC_ROOT"
done
chmod 644 "$SC_ROOT"/systemd/generated/*

for unit in "${UNITS[@]}"; do
	if [[ $(link_state "$SYSTEMD_DIR/$unit" "$SC_ROOT/systemd/generated/$unit") == absent ]]; then
		systemctl link "$SC_ROOT/systemd/generated/$unit"
	fi
done
systemctl daemon-reload
systemctl enable --now shelly-certs.timer

log "installed in $SC_ROOT"
log "next: sudo -u $SERVICE_USER $SC_ROOT/bin/shelly-certs run (or wait for the timer)"
