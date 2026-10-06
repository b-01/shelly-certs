# shellcheck shell=bash
# Helpers shared by install.sh, disable.sh and uninstall.sh. Needs lib/common.sh (SC_ROOT, log, die).

# shellcheck disable=SC2034 # used by the scripts that source this file
SERVICE_USER=shelly-certs
UNITS=(shelly-certs.service shelly-certs.timer)
# Tests point this at a temp folder, so they never see the links of a real install.
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}

require_root() {
	[[ $EUID -eq 0 ]] || die "run this as root: sudo $0"
}

# Prints every link the install creates as "LINK TARGET", one per line. Paths never contain
# spaces (check_install_path refuses them). systemctl link creates the unit links.
install_links() {
	local unit
	for unit in "${UNITS[@]}"; do
		printf '%s %s\n' "$SYSTEMD_DIR/$unit" "$SC_ROOT/systemd/generated/$unit"
	done
}

# check_install_path DIR fails when the service could not run from DIR.
check_install_path() {
	local dir=$1
	if [[ $dir == *[[:space:]]* ]]; then
		err "the folder '$dir' contains a space, and lego can't call the deploy hook from there. Move the folder, for example to /opt/shelly-certs"
		return 1
	fi
	case $dir/ in
	/home/* | /root/* | /run/user/*)
		err "the service can't read $dir (its unit has ProtectHome=yes). Move the folder, for example to /opt/shelly-certs"
		return 1
		;;
	esac
}

# check_lego_version OUTPUT succeeds when OUTPUT (from `lego --version`) is lego v5. shelly-certs
# uses lego v5's `run` command and hook variables, which v4 doesn't have.
check_lego_version() {
	[[ $1 =~ version\ v?5\.[0-9]+\. ]]
}

# Fails with a list of the missing commands, or when lego isn't v5.
check_dependencies() {
	local cmd version
	local -a missing=()
	for cmd in curl jq openssl flock column getent timeout stat mktemp systemctl useradd runuser lego; do
		command -v "$cmd" >/dev/null || missing+=("$cmd")
	done
	if ((${#missing[@]} > 0)); then
		err "missing commands: ${missing[*]}"
		return 1
	fi
	version=$(lego --version 2>&1) || version=""
	if ! check_lego_version "$version"; then
		err "shelly-certs needs lego v5 (checked with v5.5.2), found: ${version:-no version output}"
		return 1
	fi
}

# render_unit TEMPLATE OUT ROOT writes TEMPLATE to OUT with @SC_ROOT@ replaced by ROOT.
render_unit() {
	sed "s|@SC_ROOT@|$3|g" "$1" >"$2"
}

# link_state LINK TARGET prints absent, ours (a symlink to TARGET) or foreign (anything else).
link_state() {
	local link=$1 target=$2
	if [[ ! -e $link && ! -L $link ]]; then
		echo absent
	elif [[ -L $link && $(readlink "$link") == "$target" ]]; then
		echo ours
	else
		echo foreign
	fi
}

# remove_own_link LINK TARGET removes LINK only if it is a symlink to TARGET.
remove_own_link() {
	local link=$1 target=$2
	case $(link_state "$link" "$target") in
	ours)
		rm "$link"
		log "removed $link"
		;;
	foreign) warn "left $link alone: it is not a link to $target" ;;
	esac
}

# Stops and disables the timer and the service, then removes the links the install created.
# Never touches data/ or secrets/.
disable_install() {
	local link target
	if [[ $(link_state "$SYSTEMD_DIR/shelly-certs.timer" "$SC_ROOT/systemd/generated/shelly-certs.timer") == ours ]]; then
		# For a linked unit, `systemctl disable` also removes its link in /etc/systemd/system and
		# reloads systemd. So stop first: `disable --now` reloads before it stops, and the running
		# timer then fails because its service is gone.
		systemctl stop "${UNITS[@]}" || warn "systemctl stop failed, disabling anyway"
		systemctl disable "${UNITS[@]}" || warn "systemctl disable failed, removing the links anyway"
	fi
	while read -r link target; do
		remove_own_link "$link" "$target"
	done < <(install_links)
	systemctl daemon-reload
}

# Deletes everything the user or install.sh created inside the tool folder: config, secrets, data,
# generated units and the staging test settings. These are exactly the paths .gitignore lists.
remove_user_files() {
	rm -rf "$SC_ROOT/data" "$SC_ROOT/secrets" "$SC_ROOT/systemd/generated" \
		"$SC_ROOT/config/shelly-certs.conf" "$SC_ROOT/tests/staging.env"
	rm -f "$SC_ROOT"/config/devices.d/*.conf
}
