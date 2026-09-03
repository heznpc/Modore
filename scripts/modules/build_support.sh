#!/bin/bash -p
# Trusted build-only helpers for the native macOS application packager.
# This file is sourced by build_macos_swift_app.sh; it is not part of the
# application's sealed runtime.

build_support_identity() {
    local root_directory="$1"
    local build_directory="$2"

    /usr/bin/printf '%s\0%s\0' "$root_directory" "$build_directory" \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
}

build_support_prepare_lock_file() {
    local lock_file="$1"
    local expected_uid="$2"
    local owner permissions links

    if [[ -L "$lock_file" ]]; then
        return 1
    fi
    if [[ ! -e "$lock_file" ]]; then
        # noclobber makes concurrent first creation fail rather than opening a
        # path that appeared between the existence check and redirection.
        ( umask 077; set -o noclobber; : > "$lock_file" ) 2>/dev/null || true
    fi
    [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
    owner="$(/usr/bin/stat -f '%u' "$lock_file")" || return 1
    permissions="$(/usr/bin/stat -f '%Lp' "$lock_file")" || return 1
    links="$(/usr/bin/stat -f '%l' "$lock_file")" || return 1
    [[ "$owner" == "$expected_uid" && "$links" == "1" \
        && $((8#$permissions & 0022)) -eq 0 ]] || return 1
}

build_support_acquire_lock() {
    local lock_file="$1"
    local expected_uid="$2"
    local path_identity descriptor_identity lock_status

    build_support_prepare_lock_file "$lock_file" "$expected_uid" || return 73
    path_identity="$(/usr/bin/stat -f '%i:%u:%p:%l' "$lock_file")" || return 73

    # Lock the already validated inode through a descriptor. The descriptor
    # remains open in this shell for the entire build, while the kernel drops
    # the lock automatically after the last active build process exits, even
    # after SIGKILL. A persistent path is therefore not a persistent lock.
    exec 9<> "$lock_file" || return 73
    descriptor_identity="$(/usr/bin/stat -f '%i:%u:%p:%l' /dev/fd/9)" || {
        exec 9>&-
        return 73
    }
    if [[ "$descriptor_identity" != "$path_identity" \
        || -L "$lock_file" \
        || "$(/usr/bin/stat -f '%i:%u:%p:%l' "$lock_file" 2>/dev/null)" != "$path_identity" ]]; then
        exec 9>&-
        return 73
    fi

    lock_status=0
    /usr/bin/lockf -s -t 0 9 || lock_status=$?
    if [[ "$lock_status" -ne 0 ]]; then
        exec 9>&-
        return "$lock_status"
    fi
}

build_support_staging_marker_is_valid() {
    local directory="$1"
    local expected_identity="$2"
    local expected_uid="$3"
    local marker="$directory/.pch-build-identity"
    local directory_owner directory_permissions marker_owner marker_permissions
    local marker_links marker_size marker_value extra_line

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    directory_owner="$(/usr/bin/stat -f '%u' "$directory")" || return 1
    directory_permissions="$(/usr/bin/stat -f '%Lp' "$directory")" || return 1
    [[ "$directory_owner" == "$expected_uid" \
        && "$directory_permissions" == "700" ]] || return 1

    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    marker_owner="$(/usr/bin/stat -f '%u' "$marker")" || return 1
    marker_permissions="$(/usr/bin/stat -f '%Lp' "$marker")" || return 1
    marker_links="$(/usr/bin/stat -f '%l' "$marker")" || return 1
    marker_size="$(/usr/bin/stat -f '%z' "$marker")" || return 1
    [[ "$marker_owner" == "$expected_uid" && "$marker_links" == "1" \
        && "$marker_size" -eq 65 \
        && "$marker_permissions" == "600" ]] || return 1
    IFS= read -r marker_value < "$marker" || return 1
    IFS= read -r extra_line < <(/usr/bin/sed -n '2p' "$marker") || true
    [[ "$marker_value" == "$expected_identity" && -z "$extra_line" ]]
}

build_support_create_staging_directory() {
    local parent="$1"
    local prefix="$2"
    local build_identity="$3"
    local expected_uid="$4"
    local staging marker

    [[ "$build_identity" =~ ^[0-9a-f]{64}$ ]] || return 64
    [[ "$prefix" =~ ^\.?[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 64
    [[ -d "$parent" && ! -L "$parent" \
        && "$(/usr/bin/stat -f '%u' "$parent")" == "$expected_uid" ]] || return 73
    staging="$(/usr/bin/mktemp -d "$parent/$prefix.$build_identity.XXXXXX")" || return 1
    marker="$staging/.pch-build-identity"
    if ! ( umask 077; set -o noclobber; /usr/bin/printf '%s\n' "$build_identity" > "$marker" ); then
        /bin/rmdir "$staging" 2>/dev/null || true
        return 1
    fi
    if ! build_support_staging_marker_is_valid "$staging" "$build_identity" "$expected_uid"; then
        return 1
    fi
    /usr/bin/printf '%s\n' "$staging"
}

build_support_remove_staging_directory() {
    local directory="$1"
    local parent="$2"
    local prefix="$3"
    local build_identity="$4"
    local expected_uid="$5"
    local before_identity current_identity

    case "$directory" in
        "$parent/$prefix.$build_identity."*) ;;
        *) return 1 ;;
    esac
    build_support_staging_marker_is_valid \
        "$directory" "$build_identity" "$expected_uid" || return 1
    before_identity="$(/usr/bin/stat -f '%d:%i' "$directory")" || return 1
    current_identity="$(/usr/bin/stat -f '%d:%i' "$directory" 2>/dev/null)" || return 1
    [[ "$before_identity" == "$current_identity" ]] || return 1
    /bin/rm -rf "$directory"
}

build_support_recover_staging_directories() {
    local parent="$1"
    local prefix="$2"
    local build_identity="$3"
    local expected_uid="$4"
    local candidate

    for candidate in "$parent/$prefix.$build_identity."*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        if build_support_staging_marker_is_valid \
            "$candidate" "$build_identity" "$expected_uid"; then
            build_support_remove_staging_directory \
                "$candidate" "$parent" "$prefix" "$build_identity" "$expected_uid" \
                || return 1
        fi
    done
}

build_support_backup_container_has_exact_payload() {
    local directory="$1"
    local app_name="$2"
    local unexpected

    [[ "$app_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ -d "$directory/$app_name" && ! -L "$directory/$app_name" ]] || return 1
    unexpected="$(/usr/bin/find "$directory" -xdev -mindepth 1 -maxdepth 1 \
        ! -name '.pch-build-identity' ! -name "$app_name" -print -quit)" || return 1
    [[ -z "$unexpected" ]]
}

build_support_backup_container_has_only_marker() {
    local directory="$1"
    local unexpected

    unexpected="$(/usr/bin/find "$directory" -xdev -mindepth 1 -maxdepth 1 \
        ! -name '.pch-build-identity' -print -quit)" || return 1
    [[ -z "$unexpected" ]]
}

# Reconcile exactly one interrupted app backup. The validator is a function
# supplied by the builder and must accept the app path plus a signature flag.
# Foreign, unmarked, multiply-owned, or changed containers are preserved and
# rejected. Globals report whether one backup remains intentionally preserved.
build_support_reconcile_app_backup() {
    local parent="$1"
    local final_app="$2"
    local app_name="$3"
    local build_identity="$4"
    local expected_uid="$5"
    local keep_previous="$6"
    local validator="$7"
    local candidate backup_container="" backup_app count=0

    # shellcheck disable=SC2034 # outputs consumed by the sourcing builder
    BUILD_SUPPORT_PRESERVED_BACKUP=""
    # shellcheck disable=SC2034 # outputs consumed by the sourcing builder
    BUILD_SUPPORT_BACKUP_RECOVERED="0"
    [[ "$keep_previous" == "0" || "$keep_previous" == "1" ]] || return 64
    [[ "$build_identity" =~ ^[0-9a-f]{64}$ ]] || return 64
    [[ "$app_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 64
    for candidate in "$parent"/.pch-app-backup.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        case "$candidate" in
            "$parent/.pch-app-backup.$build_identity."*) ;;
            *) return 73 ;;
        esac
        build_support_staging_marker_is_valid \
            "$candidate" "$build_identity" "$expected_uid" || return 73
        count=$((count + 1))
        [[ "$count" -le 1 ]] || return 73
        backup_container="$candidate"
    done
    [[ "$count" -ne 0 ]] || return 0

    backup_app="$backup_container/$app_name"
    if [[ ! -e "$backup_app" && ! -L "$backup_app" ]]; then
        # SIGKILL may land after the owned container is created but before the
        # previous app is moved. It is safe to discard only when the final app
        # still validates and the container contains its exact marker alone.
        [[ -e "$final_app" || -L "$final_app" ]] || return 73
        "$validator" "$final_app" 1 || return 73
        build_support_backup_container_has_only_marker "$backup_container" || return 73
        build_support_remove_staging_directory \
            "$backup_container" "$parent" ".pch-app-backup" \
            "$build_identity" "$expected_uid" || return 73
        return 0
    fi

    build_support_backup_container_has_exact_payload \
        "$backup_container" "$app_name" || return 73
    "$validator" "$backup_app" 1 || return 73
    if [[ -e "$final_app" || -L "$final_app" ]]; then
        "$validator" "$final_app" 1 || return 73
        if [[ "$keep_previous" == "1" ]]; then
            # shellcheck disable=SC2034 # output consumed by the sourcing builder
            BUILD_SUPPORT_PRESERVED_BACKUP="$backup_container"
        else
            build_support_remove_staging_directory \
                "$backup_container" "$parent" ".pch-app-backup" \
                "$build_identity" "$expected_uid" || return 73
        fi
        return 0
    fi

    /bin/mv "$backup_app" "$final_app" || return 74
    if ! "$validator" "$final_app" 1; then
        /bin/mv "$final_app" "$backup_app" 2>/dev/null || true
        return 74
    fi
    build_support_backup_container_has_only_marker "$backup_container" || return 73
    build_support_remove_staging_directory \
        "$backup_container" "$parent" ".pch-app-backup" \
        "$build_identity" "$expected_uid" || return 73
    # shellcheck disable=SC2034 # output consumed by the sourcing builder
    BUILD_SUPPORT_BACKUP_RECOVERED="1"
}

build_support_retire_preserved_backup() {
    local backup_container="$1"
    local parent="$2"
    local app_name="$3"
    local build_identity="$4"
    local expected_uid="$5"
    local validator="$6"

    [[ -n "$backup_container" ]] || return 0
    build_support_staging_marker_is_valid \
        "$backup_container" "$build_identity" "$expected_uid" || return 73
    build_support_backup_container_has_exact_payload \
        "$backup_container" "$app_name" || return 73
    "$validator" "$backup_container/$app_name" 1 || return 73
    build_support_remove_staging_directory \
        "$backup_container" "$parent" ".pch-app-backup" \
        "$build_identity" "$expected_uid"
}

build_support_runtime_archive_name_is_managed() {
    local name="$1"
    [[ "$name" =~ ^cpython-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]{8}-(aarch64|x86_64)-apple-darwin-install_only_stripped\.tar\.gz$ ]]
}

build_support_prune_runtime_cache() {
    local cache_directory="$1"
    local expected_uid="$2"
    shift 2
    local candidate name allowed allowed_name owner permissions links

    [[ -d "$cache_directory" && ! -L "$cache_directory" ]] || return 1
    for candidate in "$cache_directory"/cpython-*-apple-darwin-install_only_stripped.tar.gz; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        name="${candidate##*/}"
        build_support_runtime_archive_name_is_managed "$name" || continue
        allowed=0
        for allowed_name in "$@"; do
            if [[ "$name" == "$allowed_name" ]]; then
                allowed=1
                break
            fi
        done
        [[ "$allowed" == "0" ]] || continue

        # Only unlink a cache artifact with the exact shape this builder
        # created. Symlinks, directories, hardlinks, foreign owners, altered
        # permissions, and unrelated user files are preserved for review.
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        owner="$(/usr/bin/stat -f '%u' "$candidate")" || continue
        permissions="$(/usr/bin/stat -f '%Lp' "$candidate")" || continue
        links="$(/usr/bin/stat -f '%l' "$candidate")" || continue
        [[ "$owner" == "$expected_uid" && "$links" == "1" \
            && $((8#$permissions & 0022)) -eq 0 ]] || continue
        # A failed unlink means pruning was incomplete. Stop immediately so a
        # later successful removal cannot replace that failure with status 0.
        /bin/rm -f "$candidate" || return 1
    done
}

build_support_download() {
    local account_home="$1"
    local user_temp="$2"
    local destination="$3"
    local url="$4"
    local connect_timeout="$5"
    local transfer_timeout="$6"
    local retry_timeout="$7"
    local low_speed_time="$8"
    local low_speed_limit="$9"
    shift 9
    local hard_timeout="$1"
    local maximum_bytes="$2"
    local ca_bundle="${3:-}"
    local timeout_value maximum_file_blocks
    local -a curl_arguments=(
        --connect-timeout "$connect_timeout"
        --fail
        --location
        --max-filesize "$maximum_bytes"
        --max-time "$transfer_timeout"
        --proto '=https'
        --proto-redir '=https'
        --retry 3
        --retry-connrefused
        --retry-max-time "$retry_timeout"
        --show-error
        --silent
        --speed-limit "$low_speed_limit"
        --speed-time "$low_speed_time"
        --tlsv1.2
    )

    [[ "$url" == https://* ]] || return 64
    for timeout_value in "$connect_timeout" "$transfer_timeout" "$retry_timeout" \
        "$low_speed_time" "$low_speed_limit" "$hard_timeout" "$maximum_bytes"; do
        [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]] || return 64
    done
    # bash reports and accepts RLIMIT_FSIZE in 1024-byte blocks. Requiring an
    # exact block multiple keeps the documented byte ceiling exact instead of
    # silently rounding it upward. The monitor and curl limit below remain as
    # defense in depth and provide a stable error when the peer exceeds it.
    [[ "${#maximum_bytes}" -le 15 ]] || return 64
    [[ $((maximum_bytes % 1024)) -eq 0 ]] || return 64
    maximum_file_blocks=$((maximum_bytes / 1024))
    [[ "$maximum_file_blocks" -gt 0 ]] || return 64
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 73
    if [[ -n "$ca_bundle" ]]; then
        [[ -f "$ca_bundle" && ! -L "$ca_bundle" ]] || return 73
        curl_arguments+=(--cacert "$ca_bundle")
    fi
    curl_arguments+=(--output "$destination" "$url")

    # A single-process supervisor avoids a shell-watchdog PID reuse race. It
    # owns the unreaped child while checking both monotonic time and the actual
    # destination size, so missing or false Content-Length metadata cannot fill
    # the disk beyond the explicit archive budget. Failed partials are removed.
    /usr/bin/perl -e '
        use strict;
        use warnings;
        use Fcntl qw(S_ISREG);
        use POSIX qw(WNOHANG);
        use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
        my $seconds = shift @ARGV;
        my $maximum_bytes = shift @ARGV;
        my $destination = shift @ARGV;
        my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
        my $child = fork();
        exit 70 unless defined $child;
        if ($child == 0) {
            exec @ARGV;
            exit 127;
        }
        my $failure = "";
        my $status = 0;
        my ($owned_device, $owned_inode);
        while (1) {
            my $waited = waitpid($child, WNOHANG);
            if ($waited == $child) {
                $status = $?;
                last;
            }
            if ($waited == -1) {
                $failure = "supervisor";
                last;
            }
            my @entry = lstat($destination);
            if (@entry) {
                if (!S_ISREG($entry[2]) || $entry[3] != 1 || $entry[4] != $<) {
                    $failure = "unsafe";
                } elsif (defined($owned_device)
                    && ($entry[0] != $owned_device || $entry[1] != $owned_inode)) {
                    $failure = "unsafe";
                } else {
                    ($owned_device, $owned_inode) = @entry[0, 1]
                        unless defined($owned_device);
                    $failure = "size" if $entry[7] > $maximum_bytes;
                }
            }
            if (!$failure && clock_gettime(CLOCK_MONOTONIC) >= $deadline) {
                $failure = "time";
            }
            if ($failure) {
                kill "KILL", $child;
                waitpid($child, 0);
                $status = $?;
                last;
            }
            sleep 0.02;
        }
        my @entry = lstat($destination);
        if (!$failure && @entry) {
            if (!S_ISREG($entry[2]) || $entry[3] != 1 || $entry[4] != $<) {
                $failure = "unsafe";
            } elsif (defined($owned_device)
                && ($entry[0] != $owned_device || $entry[1] != $owned_inode)) {
                $failure = "unsafe";
            } else {
                ($owned_device, $owned_inode) = @entry[0, 1]
                    unless defined($owned_device);
                $failure = "size" if $entry[7] > $maximum_bytes;
            }
        }
        my $exit_status = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
        if ($failure || $exit_status != 0) {
            @entry = lstat($destination);
            unlink($destination)
                if @entry && defined($owned_device)
                    && S_ISREG($entry[2]) && $entry[3] == 1 && $entry[4] == $<
                    && $entry[0] == $owned_device && $entry[1] == $owned_inode;
        }
        exit 124 if $failure eq "time";
        exit 63 if $failure eq "size";
        exit 73 if $failure eq "unsafe";
        exit 70 if $failure eq "supervisor";
        exit $exit_status;
    ' "$hard_timeout" "$maximum_bytes" "$destination" \
        /bin/bash -p -c \
            'ulimit -S -f "$1" || exit 70; shift; exec "$@"' \
            bash "$maximum_file_blocks" \
        /usr/bin/env -i \
            "HOME=$account_home" \
            'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
            "TMPDIR=$user_temp" \
            'LANG=en_US.UTF-8' \
            'LC_ALL=en_US.UTF-8' \
            /usr/bin/curl \
            "${curl_arguments[@]}"
}
