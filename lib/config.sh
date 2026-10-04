# shellcheck shell=bash
# Reads the KEY=VALUE config files. The files are parsed line by line and never sourced, so a
# config file can't run code.

GLOBAL_REQUIRED_KEYS=(ACME_EMAIL ACME_SERVER DNS_PROVIDER DNS_ENV_FILE KEY_TYPE RENEW_DAYS REBOOT_TIMEOUT)
GLOBAL_OPTIONAL_KEYS=(DNS_RESOLVERS DEFAULT_SHELLY_USER ALLOW_INSECURE_DEPLOY DEVICE_CA_FILE)
DEVICE_REQUIRED_KEYS=(DOMAINS ADDRESS)
DEVICE_OPTIONAL_KEYS=(SHELLY_USER SHELLY_PASSWORD_FILE REBOOT)
# The key types lego v5 accepts, except RSA8192. lego has no P-521.
KEY_TYPES=(ec256 ec384 rsa2048 rsa3072 rsa4096)

# Global settings, filled by load_global_config.
declare -gA CFG=()
# Settings of one device, filled by load_device. Besides the config keys it holds NAME, FILE and
# FIRST_DOMAIN.
declare -gA DEV=()

# kv_parse FILE ARRAY_NAME KEY...
# Reads FILE into the associative array ARRAY_NAME. Only the listed keys are allowed.
# Format: KEY=VALUE per line, blank lines and lines starting with '#' are ignored, a ' #' after an
# unquoted value starts a comment, and a value may be wrapped in "double" or 'single' quotes.
# Prints every problem with file and line, and returns 1 if there was any.
kv_parse() {
	local file=$1
	local -n kv_out=$2
	shift 2
	local allowed=" $* " line key value lineno=0 rc=0

	if [[ ! -r $file ]]; then
		err "$file: cannot read file"
		return 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}
		[[ -z $line || $line == \#* ]] && continue
		if [[ ! $line =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
			err "$file:$lineno: expected KEY=VALUE"
			rc=1
			continue
		fi
		key=${BASH_REMATCH[1]}
		value=${BASH_REMATCH[2]}
		if [[ $value =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || $value =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
			value=${BASH_REMATCH[1]}
		elif [[ $value == \#* ]]; then
			value=""
		else
			value=${value%%[[:space:]]#*}
			value=${value%"${value##*[![:space:]]}"}
		fi
		if [[ $allowed != *" $key "* ]]; then
			err "$file:$lineno: unknown key $key"
			rc=1
			continue
		fi
		if [[ -v "kv_out[$key]" ]]; then
			err "$file:$lineno: key $key is set twice"
			rc=1
			continue
		fi
		kv_out["$key"]=$value
	done <"$file"
	return $rc
}

# require_keys FILE ARRAY_NAME KEY... prints an error for every listed key that is missing or empty.
require_keys() {
	local file=$1
	local -n rk_cfg=$2
	shift 2
	local key rc=0
	for key in "$@"; do
		if [[ -z ${rk_cfg[$key]:-} ]]; then
			err "$file: missing required key $key"
			rc=1
		fi
	done
	return $rc
}

is_yes_no() { [[ $1 == yes || $1 == no ]]; }
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
is_positive_int() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }

# A lowercase DNS host name with at least two labels. Wildcards are not supported.
is_hostname() {
	local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
	[[ ${#1} -le 253 && $1 =~ ^($label\.)+$label$ ]]
}

# Loads and checks config/shelly-certs.conf into CFG. Prints every problem and returns 1 if there was any.
load_global_config() {
	local file=$SC_GLOBAL_CONFIG rc=0
	CFG=()
	kv_parse "$file" CFG "${GLOBAL_REQUIRED_KEYS[@]}" "${GLOBAL_OPTIONAL_KEYS[@]}" || rc=1
	[[ -r $file ]] || return 1
	require_keys "$file" CFG "${GLOBAL_REQUIRED_KEYS[@]}" || rc=1

	: "${CFG[DEFAULT_SHELLY_USER]:=admin}"
	: "${CFG[ALLOW_INSECURE_DEPLOY]:=no}"
	: "${CFG[DNS_RESOLVERS]:=}"
	: "${CFG[DEVICE_CA_FILE]:=}"

	CFG[KEY_TYPE]=${CFG[KEY_TYPE]:-}
	CFG[KEY_TYPE]=${CFG[KEY_TYPE],,}
	if [[ -n ${CFG[KEY_TYPE]} && " ${KEY_TYPES[*]} " != *" ${CFG[KEY_TYPE]} "* ]]; then
		err "$file: KEY_TYPE must be one of: ${KEY_TYPES[*]}"
		rc=1
	fi
	if [[ -n ${CFG[RENEW_DAYS]:-} ]] && ! is_uint "${CFG[RENEW_DAYS]}"; then
		err "$file: RENEW_DAYS must be a whole number of days"
		rc=1
	fi
	if [[ -n ${CFG[REBOOT_TIMEOUT]:-} ]] && ! is_positive_int "${CFG[REBOOT_TIMEOUT]}"; then
		err "$file: REBOOT_TIMEOUT must be a whole number of seconds above 0"
		rc=1
	fi
	if ! is_yes_no "${CFG[ALLOW_INSECURE_DEPLOY]}"; then
		err "$file: ALLOW_INSECURE_DEPLOY must be yes or no"
		rc=1
	fi
	if [[ -n ${CFG[DNS_ENV_FILE]:-} ]]; then
		CFG[DNS_ENV_FILE]=$(abs_path "${CFG[DNS_ENV_FILE]}")
		# lego only logs a missing --env-file and carries on without credentials, so check it here.
		if [[ ! -f ${CFG[DNS_ENV_FILE]} ]]; then
			err "$file: DNS_ENV_FILE: file ${CFG[DNS_ENV_FILE]} does not exist"
			rc=1
		fi
	fi
	if [[ -n ${CFG[DEVICE_CA_FILE]} ]]; then
		CFG[DEVICE_CA_FILE]=$(abs_path "${CFG[DEVICE_CA_FILE]}")
	fi
	return $rc
}

# Prints the names of all configured devices, sorted. Only files ending in .conf count.
device_names() {
	local file
	for file in "$SC_DEVICES_DIR"/*.conf; do
		[[ -e $file ]] || continue
		file=${file##*/}
		printf '%s\n' "${file%.conf}"
	done | LC_ALL=C sort
}

# load_device NAME loads and checks config/devices.d/NAME.conf into DEV. Needs CFG loaded first.
# Prints every problem and returns 1 if there was any.
load_device() {
	local name=$1 file="$SC_DEVICES_DIR/$1.conf" rc=0 domain
	DEV=()
	if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		err "$file: device name may only contain letters, digits, '.', '_' and '-'"
		rc=1
	fi
	kv_parse "$file" DEV "${DEVICE_REQUIRED_KEYS[@]}" "${DEVICE_OPTIONAL_KEYS[@]}" || rc=1
	[[ -r $file ]] || return 1
	require_keys "$file" DEV "${DEVICE_REQUIRED_KEYS[@]}" || rc=1

	DEV[NAME]=$name
	DEV[FILE]=$file
	: "${DEV[SHELLY_USER]:=${CFG[DEFAULT_SHELLY_USER]:-admin}}"
	: "${DEV[SHELLY_PASSWORD_FILE]:=}"
	: "${DEV[REBOOT]:=auto}"

	# DOMAINS is space-separated; normalise it to single spaces.
	local -a domains
	read -r -a domains <<<"${DEV[DOMAINS]:-}"
	DEV[DOMAINS]="${domains[*]}"
	DEV[FIRST_DOMAIN]=${domains[0]:-}
	for domain in "${domains[@]}"; do
		if ! is_hostname "$domain"; then
			err "$file: DOMAINS: '$domain' is not a valid lowercase host name"
			rc=1
		fi
	done
	if [[ -n ${DEV[ADDRESS]:-} && ! ${DEV[ADDRESS]} =~ ^[A-Za-z0-9.-]+$ && ! ${DEV[ADDRESS]} =~ ^[0-9A-Fa-f:]+$ ]]; then
		err "$file: ADDRESS must be an IP address or host name without scheme or port"
		rc=1
	fi
	if [[ ${DEV[REBOOT]} != auto && ${DEV[REBOOT]} != manual ]]; then
		err "$file: REBOOT must be auto or manual"
		rc=1
	fi
	if [[ -n ${DEV[SHELLY_PASSWORD_FILE]} ]]; then
		DEV[SHELLY_PASSWORD_FILE]=$(abs_path "${DEV[SHELLY_PASSWORD_FILE]}")
		if [[ ! -f ${DEV[SHELLY_PASSWORD_FILE]} ]]; then
			err "$file: SHELLY_PASSWORD_FILE: file ${DEV[SHELLY_PASSWORD_FILE]} does not exist"
			rc=1
		fi
	fi
	return $rc
}

# Loads every device config and checks that no two devices share a first domain.
# Prints every problem and returns 1 if there was any. Needs CFG loaded first.
validate_devices() {
	local name rc=0
	local -A owner_of_domain=()
	while IFS= read -r name; do
		load_device "$name" || rc=1
		[[ -n ${DEV[FIRST_DOMAIN]:-} ]] || continue
		if [[ -n ${owner_of_domain[${DEV[FIRST_DOMAIN]}]:-} ]]; then
			err "${DEV[FILE]}: DOMAINS: first domain ${DEV[FIRST_DOMAIN]} is already used by device ${owner_of_domain[${DEV[FIRST_DOMAIN]}]}"
			rc=1
		else
			owner_of_domain[${DEV[FIRST_DOMAIN]}]=$name
		fi
	done < <(device_names)
	return $rc
}

# Prints the name of the device whose first domain is $1. Fails if there is none.
find_device_by_domain() {
	local name
	while IFS= read -r name; do
		load_device "$name" 2>/dev/null || true
		if [[ ${DEV[FIRST_DOMAIN]:-} == "$1" ]]; then
			printf '%s\n' "$name"
			return 0
		fi
	done < <(device_names)
	return 1
}
