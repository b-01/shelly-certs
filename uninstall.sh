#!/usr/bin/env bash
# uninstall.sh: does what disable.sh does, then deletes the config, secrets, certificates and
# status files (everything .gitignore lists) and the shelly-certs user. Run as root. The code
# itself stays. Asks for confirmation unless --yes is given.
set -euo pipefail

SC_ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=lib/install.sh
source "$SC_ROOT/lib/install.sh"

yes=0
case $* in
"") ;;
--yes) yes=1 ;;
*)
	err "usage: uninstall.sh [--yes]"
	exit 2
	;;
esac
require_root

if [[ $yes == 0 ]]; then
	cat <<EOF
This deletes, with no way back:
  $SC_ROOT/data/ (certificates, Let's Encrypt account keys, status files)
  $SC_ROOT/secrets/ (DNS token, device passwords)
  $SC_ROOT/config/shelly-certs.conf and config/devices.d/*.conf
  the system user $SERVICE_USER
EOF
	read -r -p "Type yes to continue: " answer || answer=""
	[[ $answer == yes ]] || die "nothing changed"
fi

disable_install
remove_user_files
log "deleted config, secrets and data in $SC_ROOT"
if getent passwd "$SERVICE_USER" >/dev/null; then
	userdel "$SERVICE_USER"
	log "deleted system user $SERVICE_USER"
fi
if getent group "$SERVICE_USER" >/dev/null; then
	groupdel "$SERVICE_USER"
fi
log "uninstalled. The code in $SC_ROOT is still there"
