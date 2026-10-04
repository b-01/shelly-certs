#!/usr/bin/env bash
# Offline tests for config parsing and the `list` and `validate` commands.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

# Loads the libraries of an instance in the current (sub)shell.
load_libs() {
	SC_ROOT=$1
	# shellcheck source=../../lib/common.sh
	source "$SC_ROOT/lib/common.sh"
	# shellcheck source=../../lib/config.sh
	source "$SC_ROOT/lib/config.sh"
}

test_parser_handles_comments_quotes_and_whitespace() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" \
		'# a full-line comment' \
		'' \
		'   DNS_RESOLVERS = 1.1.1.1:53,9.9.9.9:53   # inline comment' \
		'DEFAULT_SHELLY_USER="quoted user"  # comment after quotes' \
		$'ALLOW_INSECURE_DEPLOY=no\r'
	out=$(
		load_libs "$dir"
		load_global_config && printf '%s|%s|%s|%s' "${CFG[DNS_RESOLVERS]}" "${CFG[DEFAULT_SHELLY_USER]}" \
			"${CFG[ALLOW_INSECURE_DEPLOY]}" "${CFG[ACME_SERVER]}"
	)
	assert_eq '1.1.1.1:53,9.9.9.9:53|quoted user|no|https://acme-staging-v02.api.letsencrypt.org/directory' "$out"
}

test_hash_inside_value_without_space_is_kept() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'DEFAULT_SHELLY_USER=ad#min'
	out=$(load_libs "$dir" && load_global_config && printf '%s' "${CFG[DEFAULT_SHELLY_USER]}")
	assert_eq 'ad#min' "$out"
}

test_values_are_never_executed() {
	local dir out marker
	dir=$(make_instance)
	marker="$dir/pwned"
	write_global_config "$dir" "DEFAULT_SHELLY_USER=\$(touch $marker)"
	out=$(load_libs "$dir" && load_global_config && printf '%s' "${CFG[DEFAULT_SHELLY_USER]}")
	assert_eq "\$(touch $marker)" "$out"
	[[ ! -e $marker ]] || fail "a config value was executed"
}

test_unknown_key_names_file_and_key() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'ACME_MAIL=typo@example.com'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$dir/config/shelly-certs.conf:8: unknown key ACME_MAIL"
}

test_line_without_equals_is_an_error() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'this is not valid'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "shelly-certs.conf:8: expected KEY=VALUE"
}

test_key_set_twice_is_an_error() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'RENEW_DAYS=20'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "shelly-certs.conf:8: key RENEW_DAYS is set twice"
}

test_missing_required_global_key() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	sed -i '/^ACME_EMAIL=/d' "$dir/config/shelly-certs.conf"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$dir/config/shelly-certs.conf: missing required key ACME_EMAIL"
}

test_empty_required_value_is_an_error() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	sed -i 's/^DNS_PROVIDER=.*/DNS_PROVIDER=/' "$dir/config/shelly-certs.conf"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "shelly-certs.conf: missing required key DNS_PROVIDER"
}

test_missing_global_config_file() {
	local dir out
	dir=$(make_instance)
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$dir/config/shelly-certs.conf: cannot read file"
}

test_invalid_global_values() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'ALLOW_INSECURE_DEPLOY=maybe'
	sed -i -e 's/^RENEW_DAYS=.*/RENEW_DAYS=abc/' -e 's/^KEY_TYPE=.*/KEY_TYPE=ec521/' \
		-e 's/^REBOOT_TIMEOUT=.*/REBOOT_TIMEOUT=-5/' "$dir/config/shelly-certs.conf"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "shelly-certs.conf: RENEW_DAYS must be a whole number of days"
	assert_contains "$out" "shelly-certs.conf: KEY_TYPE must be one of"
	assert_contains "$out" "shelly-certs.conf: REBOOT_TIMEOUT must be a whole number of seconds above 0"
	assert_contains "$out" "shelly-certs.conf: ALLOW_INSECURE_DEPLOY must be yes or no"
}

test_global_defaults() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	out=$(
		load_libs "$dir"
		load_global_config &&
			printf '%s|%s|%s' "${CFG[DEFAULT_SHELLY_USER]}" "${CFG[ALLOW_INSECURE_DEPLOY]}" \
				"${CFG[DNS_RESOLVERS]}"
	)
	assert_eq 'admin|no|' "$out"
}

test_relative_paths_are_resolved_against_tool_folder() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'DEVICE_CA_FILE=/etc/ssl/custom.pem'
	out=$(load_libs "$dir" && load_global_config && printf '%s|%s' "${CFG[DNS_ENV_FILE]}" "${CFG[DEVICE_CA_FILE]}")
	assert_eq "$dir/secrets/dns.env|/etc/ssl/custom.pem" "$out"
}

test_missing_dns_env_file() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	rm "$dir/secrets/dns.env"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "shelly-certs.conf: DNS_ENV_FILE: file $dir/secrets/dns.env does not exist"
}

test_missing_token_file_named_in_dns_env() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	rm "$dir/secrets/hetzner.token"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$dir/secrets/dns.env: HETZNER_API_TOKEN_FILE: file $dir/secrets/hetzner.token does not exist"
}

test_device_defaults_and_fields() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir" 'DEFAULT_SHELLY_USER=owner'
	write_device "$dir" livingroom \
		'DOMAINS=livingroom.shelly.example.com  extra.shelly.example.com' 'ADDRESS=192.168.1.50'
	out=$(
		load_libs "$dir"
		load_global_config && load_device livingroom &&
			printf '%s|%s|%s|%s|%s|%s' "${DEV[NAME]}" "${DEV[FIRST_DOMAIN]}" "${DEV[DOMAINS]}" \
				"${DEV[SHELLY_USER]}" "${DEV[REBOOT]}" "${DEV[SHELLY_PASSWORD_FILE]}"
	)
	assert_eq 'livingroom|livingroom.shelly.example.com|livingroom.shelly.example.com extra.shelly.example.com|owner|auto|' "$out"
}

test_device_password_file_is_resolved() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	printf 'secret\n' >"$dir/secrets/livingroom.password"
	chmod 600 "$dir/secrets/livingroom.password"
	write_device "$dir" livingroom 'DOMAINS=livingroom.shelly.example.com' \
		'ADDRESS=192.168.1.50' 'SHELLY_PASSWORD_FILE=secrets/livingroom.password'
	out=$(load_libs "$dir" && load_global_config && load_device livingroom && printf '%s' "${DEV[SHELLY_PASSWORD_FILE]}")
	assert_eq "$dir/secrets/livingroom.password" "$out"
}

test_invalid_device_values() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" bad 'ENABLED=yes' 'DOMAINS=Living.Example.com *.example.com' \
		'ADDRESS=http://192.168.1.50' 'REBOOT=sometimes' 'SHELLY_PASSWORD_FILE=secrets/missing.password'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	local f="$dir/config/devices.d/bad.conf"
	# ENABLED isn't a valid key; a device file that still has it gets a clear error.
	assert_contains "$out" "$f:1: unknown key ENABLED"
	assert_contains "$out" "$f: DOMAINS: 'Living.Example.com' is not a valid lowercase host name"
	assert_contains "$out" "$f: DOMAINS: '*.example.com' is not a valid lowercase host name"
	assert_contains "$out" "$f: ADDRESS must be an IP address or host name without scheme or port"
	assert_contains "$out" "$f: REBOOT must be auto or manual"
	assert_contains "$out" "$f: SHELLY_PASSWORD_FILE: file $dir/secrets/missing.password does not exist"
}

test_missing_required_device_keys() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" empty '# nothing here'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_not_contains "$out" "ENABLED"
	assert_contains "$out" "devices.d/empty.conf: missing required key DOMAINS"
	assert_contains "$out" "devices.d/empty.conf: missing required key ADDRESS"
}

test_duplicate_first_domain_is_an_error() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" one 'DOMAINS=same.example.com' 'ADDRESS=192.168.1.50'
	write_device "$dir" two 'DOMAINS=same.example.com' 'ADDRESS=192.168.1.51'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$dir/config/devices.d/two.conf: DOMAINS: first domain same.example.com is already used by device one"
}

test_only_conf_files_are_devices_and_list_is_sorted() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" kitchen 'DOMAINS=kitchen.example.com' 'ADDRESS=192.168.1.51'
	write_device "$dir" bath 'DOMAINS=bath.example.com' 'ADDRESS=192.168.1.52'
	printf 'garbage\n' >"$dir/config/devices.d/device.conf.example"
	printf 'garbage\n' >"$dir/config/devices.d/old.conf.bak"
	out=$("$dir/bin/shelly-certs" list 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_eq $'bath\nkitchen' "$out"
}

test_device_name_must_be_simple() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" 'bad name' 'DOMAINS=x.example.com' 'ADDRESS=192.168.1.51'
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "bad name.conf: device name may only contain letters, digits, '.', '_' and '-'"
}

test_validate_ok_through_symlink() {
	local dir out link
	dir=$(make_instance)
	write_global_config "$dir"
	write_device "$dir" kitchen 'DOMAINS=kitchen.example.com' 'ADDRESS=192.168.1.51'
	link="$dir/link-to-cli"
	ln -s "$dir/bin/shelly-certs" "$link"
	out=$("$link" validate 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "config OK: 1 device(s)"
}

test_validate_warns_about_open_secret_permissions() {
	local dir out
	dir=$(make_instance)
	write_global_config "$dir"
	chmod 644 "$dir/secrets/dns.env"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "WARNING: $dir/secrets/dns.env can be read by other users (mode 644), use chmod 600"
}

test_unknown_command_shows_usage() {
	local dir out
	dir=$(make_instance)
	out=$("$dir/bin/shelly-certs" frobnicate 2>&1)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "unknown command: frobnicate"
	assert_contains "$out" "Usage:"
}

test_example_files_are_valid() {
	local dir out
	dir=$(make_instance)
	cp "$REPO_ROOT/config/shelly-certs.conf.example" "$dir/config/shelly-certs.conf"
	cp "$REPO_ROOT/config/devices.d/device.conf.example" "$dir/config/devices.d/livingroom.conf"
	cp "$REPO_ROOT/config/dns.env.example" "$dir/secrets/dns.env"
	printf 'token\n' >"$dir/secrets/hetzner.token"
	chmod 600 "$dir/secrets/dns.env" "$dir/secrets/hetzner.token"
	out=$("$dir/bin/shelly-certs" validate 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_eq "config OK: 1 device(s)" "$out"
}

run_tests
