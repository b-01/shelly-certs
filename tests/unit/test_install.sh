#!/usr/bin/env bash
# Offline tests for lib/install.sh and the parts of install.sh, disable.sh and uninstall.sh that
# don't need root. The root-only steps (user, ownership, systemctl) are checked by a real install.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

SC_ROOT=$(make_instance)
cp -r "$REPO_ROOT/systemd" "$REPO_ROOT"/*.sh "$SC_ROOT/"
# shellcheck source=../../lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=../../lib/install.sh
source "$SC_ROOT/lib/install.sh"

test_install_path_checks() {
	local out
	check_install_path /opt/shelly-certs || fail "/opt/shelly-certs was refused"
	out=$(check_install_path "/opt/shelly certs" 2>&1)
	assert_eq 1 "$?" "exit code for a path with a space"
	assert_contains "$out" "the folder '/opt/shelly certs' contains a space"
	out=$(check_install_path /home/user/shelly-certs 2>&1)
	assert_eq 1 "$?" "exit code for a path under /home"
	assert_contains "$out" "the service can't read /home/user/shelly-certs (its unit has ProtectHome=yes)"
	check_install_path /root/x 2>/dev/null && fail "/root/x was accepted"
	check_install_path /homeless/x || fail "/homeless/x was refused"
}

test_lego_version_check() {
	check_lego_version "lego version v5.5.2 linux/amd64" || fail "v5.5.2 was refused"
	check_lego_version "lego version v5.0.0 linux/arm64" || fail "v5.0.0 was refused"
	check_lego_version "lego version 4.20.4 linux/amd64" && fail "v4 was accepted"
	check_lego_version "lego version v15.0.0 linux/amd64" && fail "v15 was accepted"
	check_lego_version "" && fail "empty output was accepted"
}

test_render_units() {
	local out="$TEST_TMP/units"
	mkdir -p "$out"
	render_unit "$SC_ROOT/systemd/shelly-certs.service" "$out/shelly-certs.service" /opt/shelly-certs
	render_unit "$SC_ROOT/systemd/shelly-certs.timer" "$out/shelly-certs.timer" /opt/shelly-certs
	assert_contains "$(cat "$out/shelly-certs.service")" "ExecStart=/opt/shelly-certs/bin/shelly-certs run"
	assert_contains "$(cat "$out/shelly-certs.service")" "ReadWritePaths=/opt/shelly-certs/data"
	assert_contains "$(cat "$out/shelly-certs.service")" "WorkingDirectory=/opt/shelly-certs"
	assert_contains "$(cat "$out/shelly-certs.service")" "User=shelly-certs"
	assert_contains "$(cat "$out/shelly-certs.timer")" "OnCalendar=*-*-* 03:30:00"
	assert_not_contains "$(cat "$out/shelly-certs.service" "$out/shelly-certs.timer")" "@SC_ROOT@"
}

# 1.1 is what's left after the hardening: mostly network access, which the service needs, plus
# no RootDirectory= and the read-only clock device that ProtectClock=yes allows.
test_service_exposure() {
	local out="$TEST_TMP/exposure"
	mkdir -p "$out"
	render_unit "$SC_ROOT/systemd/shelly-certs.service" "$out/shelly-certs.service" /opt/shelly-certs
	systemd-analyze security --offline=yes --threshold=11 "$out/shelly-certs.service" >/dev/null 2>&1 ||
		fail "systemd-analyze security rates the service above 1.1: $(systemd-analyze security --offline=yes "$out/shelly-certs.service" 2>&1 | tail -1)"
}

test_link_state() {
	local d="$TEST_TMP/links"
	mkdir -p "$d"
	assert_eq absent "$(link_state "$d/none" /target)"
	ln -s /target "$d/ours"
	assert_eq ours "$(link_state "$d/ours" /target)"
	ln -s /elsewhere "$d/other"
	assert_eq foreign "$(link_state "$d/other" /target)"
	touch "$d/file"
	assert_eq foreign "$(link_state "$d/file" /target)"
	ln -s /missing "$d/dangling"
	assert_eq foreign "$(link_state "$d/dangling" /target)"
}

test_remove_own_link_leaves_foreign_files() {
	local d="$TEST_TMP/remove" out
	mkdir -p "$d"
	ln -s /target "$d/ours"
	ln -s /elsewhere "$d/other"
	remove_own_link "$d/ours" /target >/dev/null
	[[ ! -L $d/ours ]] || fail "own link was not removed"
	out=$(remove_own_link "$d/other" /target 2>&1)
	assert_contains "$out" "left $d/other alone: it is not a link to /target"
	[[ -L $d/other ]] || fail "foreign link was removed"
	remove_own_link "$d/none" /target || fail "a missing link is an error"
}

# Every path .gitignore lists, apart from the notes for working on this repo (CLAUDE.md, .claude/),
# is something the user or install.sh created, and uninstall removes exactly those. Checked against .gitignore so the two can't drift apart.
test_remove_user_files_matches_gitignore() {
	local dir entry path
	dir=$(make_instance)
	cp -r "$REPO_ROOT/config" "$REPO_ROOT/systemd" "$dir/"
	mkdir -p "$dir/tests"
	while IFS= read -r entry; do
		[[ -n $entry && $entry != \#* ]] || continue
		[[ $entry != /CLAUDE.md && $entry != /.claude/ ]] || continue
		path="$dir${entry%/}"
		path=${path//\*/sample}
		mkdir -p "$(dirname "$path")"
		if [[ $entry == */ ]]; then
			mkdir -p "$path"
			touch "$path/file"
		else
			touch "$path"
		fi
	done <"$REPO_ROOT/.gitignore"
	SC_ROOT=$dir remove_user_files
	while IFS= read -r entry; do
		[[ -n $entry && $entry != \#* ]] || continue
		[[ $entry != /CLAUDE.md && $entry != /.claude/ ]] || continue
		path="$dir${entry%/}"
		path=${path//\*/sample}
		[[ ! -e $path ]] || fail "$entry was not removed"
	done <"$REPO_ROOT/.gitignore"
	[[ -f $dir/config/shelly-certs.conf.example ]] || fail "the global example was removed"
	[[ -f $dir/config/devices.d/device.conf.example ]] || fail "the device example was removed"
	[[ -f $dir/bin/shelly-certs ]] || fail "bin/ was touched"
}

test_scripts_need_root() {
	local script out
	if [[ $EUID -eq 0 ]]; then
		echo "    skipped: the tests run as root"
		return
	fi
	for script in install.sh disable.sh uninstall.sh; do
		out=$("$SC_ROOT/$script" 2>&1)
		assert_eq 1 "$?" "$script exit code"
		assert_contains "$out" "run this as root" "$script output"
	done
}

# make_install_instance prints the path of a tool copy that install.sh can run in.
make_install_instance() {
	local dir
	dir=$(make_instance)
	cp -r "$REPO_ROOT/systemd" "$REPO_ROOT"/*.sh "$dir/"
	printf '%s\n' "$dir"
}

# run_install_as_fake_root DIR runs DIR/install.sh as root inside a user namespace, so no real
# root is needed. Stubs stand in for the commands that would change the system: they log their
# arguments to DIR/commands.log instead. runuser runs the command as the current user.
run_install_as_fake_root() {
	local dir=$1 stubs="$1/stubs" cmd
	mkdir -p "$stubs"
	for cmd in systemctl useradd chown; do
		printf '#!/bin/sh\necho "%s $*" >>"%s/commands.log"\n' "$cmd" "$dir" >"$stubs/$cmd"
	done
	# getent finds no user, so install.sh creates one with the useradd stub.
	printf '#!/bin/sh\nexit 2\n' >"$stubs/getent"
	printf '#!/bin/sh\nshift 3\nexec "$@"\n' >"$stubs/runuser"
	printf '#!/bin/sh\necho "lego version v5.5.2 linux/amd64"\n' >"$stubs/lego"
	chmod +x "$stubs"/*
	PATH="$stubs:$PATH" unshare -r "$dir/install.sh" 2>&1
}

# Fake root needs user namespaces. Prints a skip line and fails when they aren't available.
can_fake_root() {
	if ! unshare -r true 2>/dev/null; then
		echo "    skipped: unshare -r is not available"
		return 1
	fi
}

test_install_without_config_stops_before_systemd() {
	local dir out rc
	can_fake_root || return 0
	dir=$(make_install_instance)
	out=$(run_install_as_fake_root "$dir")
	rc=$?
	assert_eq 1 "$rc" "exit code"
	assert_contains "$out" "config/shelly-certs.conf: cannot read file"
	assert_contains "$out" "the config is missing or has errors, so the systemd units are not installed yet"
	assert_contains "$out" "then run: sudo $dir/install.sh"
	assert_contains "$(cat "$dir/commands.log")" "useradd --system"
	assert_contains "$(cat "$dir/commands.log")" "chown -R shelly-certs:shelly-certs $dir/data $dir/secrets"
	assert_not_contains "$(cat "$dir/commands.log")" "systemctl"
	[[ ! -e $dir/systemd/generated ]] || fail "systemd/generated was created"
}

test_install_with_valid_config_enables_timer() {
	local dir out rc
	can_fake_root || return 0
	dir=$(make_install_instance)
	write_global_config "$dir"
	out=$(run_install_as_fake_root "$dir")
	rc=$?
	assert_eq 0 "$rc" "exit code"
	assert_contains "$out" "config OK: 0 device(s)"
	assert_contains "$out" "installed in $dir"
	assert_contains "$(cat "$dir/commands.log")" "systemctl link $dir/systemd/generated/shelly-certs.timer"
	assert_contains "$(cat "$dir/commands.log")" "systemctl enable --now shelly-certs.timer"
	assert_contains "$(cat "$dir/systemd/generated/shelly-certs.service")" "ExecStart=$dir/bin/shelly-certs run"
}

test_install_takes_no_arguments() {
	local out
	out=$("$SC_ROOT/install.sh" /opt/shelly-certs 2>&1)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "install.sh takes no arguments, it sets up the folder it is in ($SC_ROOT)"
}

test_uninstall_unknown_option() {
	local out
	out=$("$SC_ROOT/uninstall.sh" --force 2>&1)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "usage: uninstall.sh [--yes]"
}

run_tests
