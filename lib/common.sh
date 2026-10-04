# shellcheck shell=bash
# Shared helpers: folder paths, logging and small utilities.
# The calling script sets SC_ROOT (the real tool folder, found with readlink -f) before sourcing this.
# The paths below are used by the files that source this one.
# shellcheck disable=SC2034

if ((BASH_VERSINFO[0] < 5)); then
	echo "shelly-certs needs bash 5 or newer" >&2
	exit 1
fi

SC_CONFIG_DIR="$SC_ROOT/config"
SC_GLOBAL_CONFIG="$SC_CONFIG_DIR/shelly-certs.conf"
SC_DEVICES_DIR="$SC_CONFIG_DIR/devices.d"
SC_DATA_DIR="$SC_ROOT/data"
# lego keeps certificates in <--path>/certificates/<cert name>.{crt,key,issuer.crt,json}.
SC_CERT_DIR="$SC_DATA_DIR/certificates"
SC_STATUS_DIR="$SC_DATA_DIR/status"
SC_LOCK_FILE="$SC_DATA_DIR/.lock"

# Log lines start with "<device>: " while LOG_PREFIX is set, so journald output shows which device
# a line is about.
LOG_PREFIX=""

log() { printf '%s%s\n' "${LOG_PREFIX:+$LOG_PREFIX: }" "$*"; }
warn() { printf '%sWARNING: %s\n' "${LOG_PREFIX:+$LOG_PREFIX: }" "$*" >&2; }
err() { printf '%sERROR: %s\n' "${LOG_PREFIX:+$LOG_PREFIX: }" "$*" >&2; }
die() {
	err "$@"
	exit 1
}

# Turns a path from a config file into an absolute path. Relative paths are relative to the tool folder.
abs_path() {
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s\n' "$SC_ROOT/$1" ;;
	esac
}

# Warns when a secret file can be read by group or others.
check_secret_mode() {
	local file=$1 mode
	mode=$(stat -c '%a' "$file") || return 0
	if ((8#$mode & 8#077)); then
		warn "$file can be read by other users (mode $mode), use chmod 600"
	fi
}

# plural COUNT WORD prints "1 word" or "N words".
plural() {
	if [[ $1 == 1 ]]; then printf '1 %s\n' "$2"; else printf '%s %ss\n' "$1" "$2"; fi
}

# Creates a private temporary folder in WORKDIR that is removed when the script exits. It replaces
# any EXIT trap set before.
make_workdir() {
	WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/shelly-certs.XXXXXX")
	trap 'rm -rf "$WORKDIR"' EXIT
}

# Takes the lock in data/ so two shelly-certs processes can't work at the same time. The lock is
# held until the process exits, so it is still held while lego and the deploy hook run. The hook
# must not try to take it: it would find it taken by the shelly-certs run that started it.
acquire_lock() {
	mkdir -p "$SC_DATA_DIR"
	exec {SC_LOCK_FD}>>"$SC_LOCK_FILE"
	flock -n "$SC_LOCK_FD" || die "another shelly-certs process holds $SC_LOCK_FILE, try again later"
}

# Prints the names of the environment variables the deploy hook keeps. lego hands the hook its
# whole environment, which can include DNS credentials; everything not listed here is dropped.
hook_env_keep_names() {
	compgen -e | grep -E '^(PATH|HOME|LANG|LC_[A-Z_]+|TZ|TMPDIR|LEGO_HOOK_[A-Z_]+|SHELLY_CERTS_[A-Z_]+|CURL_CA_BUNDLE|SSL_CERT_FILE|SSL_CERT_DIR)$' |
		LC_ALL=C sort
}
