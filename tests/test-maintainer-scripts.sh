#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
package=qualcomm-iqfiles-qcs9075

fail() {
	echo "error: $*" >&2
	exit 1
}

assert_file_content() {
	file=$1
	expected=$2
	actual=$(cat "$file")
	[ "$actual" = "$expected" ] || fail "$file contains '$actual', expected '$expected'"
}

assert_link() {
	file=$1
	expected=$2
	[ -L "$file" ] || fail "$file is not a symbolic link"
	actual=$(readlink "$file")
	[ "$actual" = "$expected" ] || fail "$file points to '$actual', expected '$expected'"
}

setup_root() {
	root=$1
	mkdir -p "$root/usr/share/$package" \
		"$root/usr/lib/qcs9100/camera" \
		"$root/var/lib/dpkg"
	touch "$root/var/lib/dpkg/status"
	printf '%s\n' /usr/lib/qcs9100/camera >"$root/usr/share/$package/runtime-dir"
	printf '%s\n' tuned-existing >"$root/usr/share/$package/existing.bin"
	printf '%s\n' tuned-new >"$root/usr/share/$package/new.bin"
	printf '%s\n' vendor-existing >"$root/usr/lib/qcs9100/camera/existing.bin"
}

verify_active() {
	root=$1
	runtime=$root/usr/lib/qcs9100/camera
	payload=/usr/share/$package

	assert_link "$runtime/existing.bin" "$payload/existing.bin"
	assert_link "$runtime/new.bin" "$payload/new.bin"
	assert_file_content "$runtime/existing.bin.$package.distrib" vendor-existing
	[ ! -e "$runtime/new.bin.$package.distrib" ] || fail "new.bin unexpectedly has a diverted file"
	[ "$(dpkg-divert --root "$root" --listpackage /usr/lib/qcs9100/camera/existing.bin)" = "$package" ] ||
		fail "existing.bin diversion is not owned by $package"
	[ -z "$(dpkg-divert --root "$root" --listpackage /usr/lib/qcs9100/camera/new.bin)" ] ||
		fail "new.bin unexpectedly has a diversion"
}

verify_removed() {
	root=$1
	runtime=$root/usr/lib/qcs9100/camera

	assert_file_content "$runtime/existing.bin" vendor-existing
	[ ! -e "$runtime/new.bin" ] || fail "new.bin was not removed"
	[ ! -e "$root/var/lib/qualcomm-iqfiles/$package.paths" ] || fail "state file was not removed"
	[ -z "$(dpkg-divert --root "$root" --listpackage /usr/lib/qcs9100/camera/existing.bin)" ] ||
		fail "existing.bin diversion was not removed"
}

run_lifecycle() {
	cleanup_script=$1
	cleanup_action=$2
	root=$(mktemp -d)
	trap 'rm -rf "$root"' EXIT HUP INT TERM
	setup_root "$root"

	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure
	verify_active "$root"

	# A repeated configure must preserve the original diversion and links.
	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure
	verify_active "$root"

	# Removing a payload during an upgrade must remove its runtime link and state.
	rm "$root/usr/share/$package/new.bin"
	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure
	[ ! -e "$root/usr/lib/qcs9100/camera/new.bin" ] || fail "stale new.bin link was not removed"
	if grep -Fq 'new.bin|' "$root/var/lib/qualcomm-iqfiles/$package.paths"; then
		fail "stale new.bin state was not removed"
	fi
	printf '%s\n' tuned-new >"$root/usr/share/$package/new.bin"
	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure
	verify_active "$root"

	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/$cleanup_script" "$cleanup_action"
	verify_removed "$root"

	rm -rf "$root"
	trap - EXIT HUP INT TERM
}

run_symlink_lifecycle() {
	root=$(mktemp -d)
	trap 'rm -rf "$root"' EXIT HUP INT TERM
	setup_root "$root"
	runtime=$root/usr/lib/qcs9100/camera/existing.bin
	rm "$runtime"
	ln -s /vendor/existing.bin "$runtime"

	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure
	assert_link "$runtime.$package.distrib" /vendor/existing.bin

	DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.prerm" remove
	assert_link "$runtime" /vendor/existing.bin

	rm -rf "$root"
	trap - EXIT HUP INT TERM
}

run_diversion_conflict() {
	root=$(mktemp -d)
	trap 'rm -rf "$root"' EXIT HUP INT TERM
	setup_root "$root"
	runtime=/usr/lib/qcs9100/camera/existing.bin
	dpkg-divert --root "$root" --package other-package \
		--add --rename --divert "$runtime.other-package.distrib" "$runtime"

	if DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure; then
		fail "configure accepted a diversion owned by another package"
	fi
	[ ! -L "$root$runtime" ] || fail "configure replaced another package's diversion"

	dpkg-divert --root "$root" --package other-package \
		--remove --rename --divert "$runtime.other-package.distrib" "$runtime"
	rm -rf "$root"
	trap - EXIT HUP INT TERM
}

run_runtime_metadata_errors() {
	root=$(mktemp -d)
	trap 'rm -rf "$root"' EXIT HUP INT TERM
	setup_root "$root"
	metadata=$root/usr/share/$package/runtime-dir

	rm "$metadata"
	if DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure; then
		fail "configure accepted missing runtime directory metadata"
	fi

	printf '%s\n' /tmp/camera >"$metadata"
	if DPKG_ROOT=$root DPKG_MAINTSCRIPT_PACKAGE=$package \
		sh "$repo_dir/debian/qualcomm-iqfiles.postinst" configure; then
		fail "configure accepted invalid runtime directory metadata"
	fi

	rm -rf "$root"
	trap - EXIT HUP INT TERM
}

run_lifecycle qualcomm-iqfiles.prerm remove
run_lifecycle qualcomm-iqfiles.postrm abort-install
run_lifecycle qualcomm-iqfiles.postrm purge
run_symlink_lifecycle
run_diversion_conflict
run_runtime_metadata_errors
