#!/usr/bin/env bash
# disable.sh: stops and disables the timer and removes the links install.sh created. Run as root.
# Keeps data/, secrets/, the config and the shelly-certs user; install.sh turns it back on.
set -euo pipefail

SC_ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=lib/install.sh
source "$SC_ROOT/lib/install.sh"

if [[ $# -gt 0 ]]; then
	err "disable.sh takes no arguments"
	exit 2
fi
require_root
disable_install
log "disabled. data/, secrets/ and the config are kept"
