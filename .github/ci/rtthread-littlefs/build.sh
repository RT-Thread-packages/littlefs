#!/usr/bin/env sh
set -eu

usage() {
    cat <<'EOF_USAGE'
Usage: build.sh

Environment variables:
  RTTHREAD_REF  RT-Thread branch or tag to build against. Default: master
  RTTHREAD_BSP  BSP path inside rt-thread. Default: bsp/qemu-vexpress-a9
  RTTHREAD_DFS_VERSION
                RT-Thread DFS profile to build. Supported values: v1, v2.
                Default: v1
  RTT_CC        RT-Thread compiler selector. Default: gcc. This CI script
                currently supports GNU toolchains only.
  RTTHREAD_TOOLCHAIN_PREFIX
                GNU toolchain command prefix. Default for RTT_CC=gcc:
                arm-none-eabi-. Set to an empty string to use unprefixed
                gcc/nm/size commands.
  RTTHREAD_CLONE_ATTEMPTS
                RT-Thread clone attempts before failing. Default: 3
  RTTHREAD_CLONE_RETRY_DELAY
                Seconds to wait between RT-Thread clone attempts. Default: 5
  RTTHREAD_WORKDIR
                Temporary RT-Thread work directory. Must be a dedicated
                rt-thread-work directory. Default: RUNNER_TEMP or _ci
  RTTHREAD_REUSE_WORKDIR
                Reuse an existing matching RT-Thread checkout between repeated
                invocations. Supported values: 0, 1. Default: 0
  RTTHREAD_ELF  ELF file name expected in the BSP directory. Default:
                rtthread.elf
EOF_USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

abs_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$(pwd)" "$1" ;;
    esac
}

normalize_path() {
    path=$1

    case "$path" in
        /*) ;;
        *) path=$(abs_path "$path") ;;
    esac

    if [ -d "$path" ]; then
        (cd "$path" && pwd -P)
        return
    fi

    dir=$path
    suffix=
    while [ ! -d "$dir" ]; do
        base=${dir##*/}
        suffix=${base}${suffix:+/$suffix}
        next=${dir%/*}
        [ "$next" != "$dir" ] || break
        [ -n "$next" ] || next=/
        dir=$next
    done

    if [ -d "$dir" ]; then
        dir=$(cd "$dir" && pwd -P)
        printf '%s%s%s\n' "$dir" "${suffix:+/}" "$suffix"
    else
        printf '%s\n' "$path"
    fi
}

relative_child_path() {
    parent=$1
    child=$2
    parent_abs=$(cd "$parent" && pwd -P) || return 1
    child_abs=$(cd "$child" && pwd -P) || return 1

    case "$child_abs" in
        "$parent_abs") printf '.\n' ;;
        "$parent_abs"/*) printf '%s\n' "${child_abs#"$parent_abs"/}" ;;
    esac
}

ensure_safe_workdir() {
    work_dir=$1
    root_dir=$2

    case "$work_dir" in
        ''|/)
            fail "unsafe RTTHREAD_WORKDIR: $work_dir"
            ;;
    esac

    work_base=${work_dir##*/}
    [ "$work_base" = "rt-thread-work" ] || \
        fail "RTTHREAD_WORKDIR must name a dedicated rt-thread-work directory"

    [ "$work_dir" != "$root_dir" ] || \
        fail "RTTHREAD_WORKDIR must not be the package repository root"
    case "$root_dir" in
        "$work_dir"/*)
            fail "RTTHREAD_WORKDIR must not contain the package repository root"
            ;;
    esac
}

ensure_safe_bsp_path() {
    bsp_path=$1

    case "$bsp_path" in
        ''|/*)
            fail "unsafe RTTHREAD_BSP: $bsp_path"
            ;;
        .|./*|*/.|*/./*|..|../*|*/..|*/../*|*//*)
            fail "RTTHREAD_BSP must be a relative path without . or .. segments"
            ;;
    esac
}

ensure_safe_elf_name() {
    elf_name=$1

    case "$elf_name" in
        ''|/*|*/*|.|..)
            fail "RTTHREAD_ELF must be a file name inside the BSP directory"
            ;;
    esac
}

ensure_supported_dfs_version() {
    dfs_version=$1

    case "$dfs_version" in
        v1|v2) ;;
        *) fail "RTTHREAD_DFS_VERSION must be v1 or v2: $dfs_version" ;;
    esac
}

ensure_removable_workdir() {
    work_dir=$1
    marker_file="$work_dir/.rtthread-littlefs-ci-workdir"

    [ ! -e "$work_dir" ] && return
    [ -d "$work_dir" ] || \
        fail "RTTHREAD_WORKDIR exists but is not a directory: $work_dir"
    [ -f "$marker_file" ] && return
    first_entry=$(find "$work_dir" -mindepth 1 -maxdepth 1 \
        -print -quit) || \
        fail "failed to inspect RTTHREAD_WORKDIR: $work_dir"
    [ -z "$first_entry" ] && return

    fail "refusing to remove non-empty unmarked RTTHREAD_WORKDIR: $work_dir"
}

reset_workdir() {
    work_dir=$1
    marker_file="$work_dir/.rtthread-littlefs-ci-workdir"

    ensure_removable_workdir "$work_dir"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    : > "$marker_file"
}

kconfig_name() {
    case "$1" in
        CONFIG_*) printf '%s\n' "$1" ;;
        *) printf 'CONFIG_%s\n' "$1" ;;
    esac
}

set_kconfig_symbol() {
    config_file=$1
    symbol=$(kconfig_name "$2")
    value=$3
    tmp_file="${config_file}.tmp"

    if [ -f "$config_file" ]; then
        awk -v symbol="$symbol" -v value="$value" '
            $0 == symbol "=y" || \
            $0 ~ "^" symbol "=" || \
            $0 == "# " symbol " is not set" {
                if (!done) {
                    print symbol "=" value
                    done = 1
                }
                next
            }
            { print }
            END {
                if (!done) {
                    print symbol "=" value
                }
            }
        ' "$config_file" > "$tmp_file"
        mv "$tmp_file" "$config_file"
    else
        printf '%s=%s\n' "$symbol" "$value" > "$config_file"
    fi
}

unset_kconfig_symbol() {
    config_file=$1
    symbol=$(kconfig_name "$2")
    tmp_file="${config_file}.tmp"

    if [ -f "$config_file" ]; then
        awk -v symbol="$symbol" '
            $0 == symbol "=y" || \
            $0 ~ "^" symbol "=" || \
            $0 == "# " symbol " is not set" {
                if (!done) {
                    print "# " symbol " is not set"
                    done = 1
                }
                next
            }
            { print }
            END {
                if (!done) {
                    print "# " symbol " is not set"
                }
            }
        ' "$config_file" > "$tmp_file"
        mv "$tmp_file" "$config_file"
    else
        printf '# %s is not set\n' "$symbol" > "$config_file"
    fi
}

run_scons_pyconfig() {
    scons --pyconfig-silent
}

copy_package() {
    source_dir=$1
    package_dir=$2
    exclude_dir=${3:-}
    exclude_rel=
    archive_file="${package_dir}.tar"

    rm -rf "$package_dir"
    mkdir -p "$package_dir"
    rm -f "$archive_file"
    if [ -n "$exclude_dir" ] && [ -d "$exclude_dir" ]; then
        exclude_rel=$(relative_child_path "$source_dir" "$exclude_dir")
    fi

    if [ -n "$exclude_rel" ]; then
        if ! (cd "$source_dir" && tar \
            --exclude='./.git' \
            --exclude='./_ci' \
            --exclude="./$exclude_rel" \
            --exclude="./$exclude_rel/*" \
            -cf "$archive_file" .); then
            rm -f "$archive_file"
            fail "failed to archive package sources"
        fi
    else
        if ! (cd "$source_dir" && tar \
            --exclude='./.git' \
            --exclude='./_ci' \
            -cf "$archive_file" .); then
            rm -f "$archive_file"
            fail "failed to archive package sources"
        fi
    fi

    if ! tar -xf "$archive_file" -C "$package_dir"; then
        rm -f "$archive_file"
        fail "failed to extract package sources"
    fi
    rm -f "$archive_file"
}

kconfig_tree_has_symbol() {
    search_dir=$1
    symbol=$2
    result_file="$search_dir/.rtthread-littlefs-kconfig-symbols.$$"

    [ -d "$search_dir" ] || return 1
    rm -f "$result_file"
    if ! find "$search_dir" -name Kconfig -type f -exec awk \
        -v symbol="$symbol" '
            ($1 == "config" || $1 == "menuconfig") && $2 == symbol {
                print FILENAME
                exit
            }
        ' {} \; > "$result_file"; then
        rm -f "$result_file"
        fail "failed to scan Kconfig files under $search_dir"
    fi

    if [ -s "$result_file" ]; then
        rm -f "$result_file"
        return 0
    fi

    rm -f "$result_file"
    return 1
}

write_packages_kconfig() {
    packages_dir=$1
    kconfig_file="$packages_dir/Kconfig"

    kconfig_tree_has_symbol "$packages_dir" PKG_USING_LITTLEFS && return

    cat >> "$kconfig_file" <<'EOF_KCONFIG'

menu "CI packages"

config PKG_USING_LITTLEFS
    bool "littlefs package"
    default n

endmenu
EOF_KCONFIG
}

write_packages_sconscript() {
    packages_dir=$1
    scons_file="$packages_dir/SConscript"
    original_file="$packages_dir/SConscript.ci.orig"

    if [ -f "$original_file" ]; then
        rm -f "$scons_file"
    elif [ -f "$scons_file" ]; then
        mv "$scons_file" "$original_file"
    fi

    cat > "$scons_file" <<'EOF_SCONS'
import os

from building import *

cwd = GetCurrentDir()
objs = []

# CI builds only the package under test. Loading the BSP's original
# packages/SConscript can rescan packages/littlefs and duplicate objects.
script = os.path.join('littlefs', 'SConscript')
if os.path.isfile(os.path.join(cwd, script)):
    objs = objs + SConscript(script)

Return('objs')
EOF_SCONS
}

write_compile_check_source() {
    bsp_dir=$1
    app_dir="$bsp_dir/applications"

    [ -d "$app_dir" ] || fail "BSP applications directory not found: $app_dir"

    cat > "$app_dir/littlefs_compile_check.c" <<'EOF_C'
/* CI-only RT-Thread package integration check. */
#include <rtthread.h>

/* Match the package SConscript compile flag while including the real API. */
/**
 * @brief Select the package-local RT-Thread littlefs configuration header.
 */
#define LFS_CONFIG lfs_config.h
#include "../packages/littlefs/lfs.h"

/**
 * @brief Initialize the RT-Thread DFS littlefs package.
 *
 * @return 0 on success, otherwise a negative error code.
 */
extern int dfs_lfs_init(void);

/**
 * @brief Verify that package build graph linked littlefs symbols.
 *
 * @return 0 when required symbols are linked, otherwise -1.
 */
static int littlefs_compile_check(void)
{
    int (* volatile dfs_init)(void) = dfs_lfs_init;
    int (* volatile mount)(lfs_t *, const struct lfs_config *) = lfs_mount;

    return (dfs_init != 0 && mount != 0) ? 0 : -1;
}
INIT_APP_EXPORT(littlefs_compile_check);
EOF_C
}

apply_littlefs_kconfig_profile() {
    config_file=$1
    dfs_version=$2
    kconfig_root=$3

    set_kconfig_symbol "$config_file" RT_USING_COMPONENTS_INIT y
    set_kconfig_symbol "$config_file" RT_USING_DEVICE y
    set_kconfig_symbol "$config_file" RT_USING_DEVICE_OPS y
    set_kconfig_symbol "$config_file" RT_USING_HEAP y
    set_kconfig_symbol "$config_file" RT_USING_DFS y
    set_kconfig_symbol "$config_file" DFS_USING_POSIX y
    set_kconfig_symbol "$config_file" DFS_USING_WORKDIR y
    set_kconfig_symbol "$config_file" DFS_FD_MAX 16
    case "$dfs_version" in
        v1)
            if kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V1; then
                set_kconfig_symbol "$config_file" RT_USING_DFS_V1 y
            fi
            if kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V2; then
                unset_kconfig_symbol "$config_file" RT_USING_DFS_V2
            fi
            ;;
        v2)
            kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V2 || \
                fail "RTTHREAD_DFS_VERSION=v2 requires RT_USING_DFS_V2 support"
            if kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V1; then
                unset_kconfig_symbol "$config_file" RT_USING_DFS_V1
            fi
            set_kconfig_symbol "$config_file" RT_USING_DFS_V2 y
            unset_kconfig_symbol "$config_file" RT_USING_DFS_ELMFAT
            unset_kconfig_symbol "$config_file" RT_USING_DFS_TMPFS
            unset_kconfig_symbol "$config_file" RT_USING_DFS_MQUEUE
            ;;
    esac
    set_kconfig_symbol "$config_file" DFS_FILESYSTEMS_MAX 4
    set_kconfig_symbol "$config_file" DFS_FILESYSTEM_TYPES_MAX 4
    set_kconfig_symbol "$config_file" RT_USING_DFS_DEVFS y
    set_kconfig_symbol "$config_file" RT_USING_DFS_ROMFS y
    set_kconfig_symbol "$config_file" RT_USING_DEVICE_IPC y
    set_kconfig_symbol "$config_file" RT_USING_MUTEX y
    set_kconfig_symbol "$config_file" RT_USING_MTD_NOR y
    set_kconfig_symbol "$config_file" PKG_USING_LITTLEFS y
}

verify_rtconfig_symbols() {
    rtconfig_file=$1
    dfs_version=$2
    kconfig_root=$3

    grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS$' "$rtconfig_file" || \
        fail "RT_USING_DFS was not enabled in $rtconfig_file"
    case "$dfs_version" in
        v1)
            if kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V1; then
                grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_V1$' "$rtconfig_file" || \
                    fail "RT_USING_DFS_V1 was not enabled in $rtconfig_file"
            else
                printf 'RT_USING_DFS_V1 is not available; using legacy DFS v1 profile\n'
            fi
            if grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_V2$' "$rtconfig_file"; then
                fail "RT_USING_DFS_V2 is enabled in $rtconfig_file"
            fi
            ;;
        v2)
            kconfig_tree_has_symbol "$kconfig_root" RT_USING_DFS_V2 || \
                fail "RTTHREAD_DFS_VERSION=v2 requires RT_USING_DFS_V2 support"
            grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_V2$' "$rtconfig_file" || \
                fail "RT_USING_DFS_V2 was not enabled in $rtconfig_file"
            if grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_V1$' "$rtconfig_file"; then
                fail "RT_USING_DFS_V1 is enabled in $rtconfig_file"
            fi
            if grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_ELMFAT$' "$rtconfig_file"; then
                fail "RT_USING_DFS_ELMFAT is enabled in $rtconfig_file"
            fi
            if grep -q '^#define[[:space:]][[:space:]]*RT_USING_DFS_TMPFS$' "$rtconfig_file"; then
                fail "RT_USING_DFS_TMPFS is enabled in $rtconfig_file"
            fi
            ;;
    esac
    grep -q '^#define[[:space:]][[:space:]]*RT_USING_MTD_NOR$' "$rtconfig_file" || \
        fail "RT_USING_MTD_NOR was not enabled in $rtconfig_file"
    grep -q '^#define[[:space:]][[:space:]]*RT_USING_HEAP$' "$rtconfig_file" || \
        fail "RT_USING_HEAP was not enabled in $rtconfig_file"
    grep -q '^#define[[:space:]][[:space:]]*RT_USING_MUTEX$' "$rtconfig_file" || \
        fail "RT_USING_MUTEX was not enabled in $rtconfig_file"
    grep -q '^#define[[:space:]][[:space:]]*PKG_USING_LITTLEFS$' "$rtconfig_file" || \
        fail "PKG_USING_LITTLEFS was not enabled in $rtconfig_file"
}

check_nm_symbol() {
    nm_cmd=$1
    elf_file=$2
    symbol=$3

    "$nm_cmd" "$elf_file" | awk -v symbol="$symbol" '
        $NF == symbol {
            found = 1
        }
        END {
            exit !found
        }
    '
}

gnu_toolchain_prefix() {
    case "$1" in
        gcc)
            if [ "${RTTHREAD_TOOLCHAIN_PREFIX+x}" = x ]; then
                printf '%s\n' "$RTTHREAD_TOOLCHAIN_PREFIX"
            else
                printf '%s\n' 'arm-none-eabi-'
            fi
            ;;
        *)
            fail "unsupported RTT_CC for this CI script: $1"
            ;;
    esac
}

clone_rtthread() {
    rtthread_ref=$1
    rtthread_dir=$2
    attempts=${RTTHREAD_CLONE_ATTEMPTS:-3}
    retry_delay=${RTTHREAD_CLONE_RETRY_DELAY:-5}
    attempt=1

    case "$attempts" in
        ''|*[!0-9]*)
            fail "RTTHREAD_CLONE_ATTEMPTS must be a positive integer"
            ;;
    esac
    case "$retry_delay" in
        ''|*[!0-9]*)
            fail "RTTHREAD_CLONE_RETRY_DELAY must be a non-negative integer"
            ;;
    esac
    [ "$attempts" -gt 0 ] || \
        fail "RTTHREAD_CLONE_ATTEMPTS must be a positive integer"

    while [ "$attempt" -le "$attempts" ]; do
        printf 'cloning RT-Thread branch/tag %s (attempt %s/%s)\n' \
            "$rtthread_ref" "$attempt" "$attempts"
        if git clone --depth 1 --branch "$rtthread_ref" \
            https://github.com/RT-Thread/rt-thread.git "$rtthread_dir"; then
            return
        fi

        rm -rf "$rtthread_dir"
        [ "$attempt" -lt "$attempts" ] || break
        printf 'warning: RT-Thread clone failed; retrying in %s seconds\n' \
            "$retry_delay" >&2
        sleep "$retry_delay"
        attempt=$((attempt + 1))
    done

    fail "failed to clone RT-Thread branch/tag $rtthread_ref after $attempts attempts"
}


rtthread_checkout_matches() {
    rtthread_ref=$1
    rtthread_dir=$2

    [ -d "$rtthread_dir/.git" ] || return 1
    git -C "$rtthread_dir" rev-parse --verify HEAD >/dev/null 2>&1 || return 1

    if git -C "$rtthread_dir" rev-parse --verify "refs/tags/$rtthread_ref^{commit}" >/dev/null 2>&1; then
        expected=$(git -C "$rtthread_dir" rev-parse "refs/tags/$rtthread_ref^{commit}") || return 1
    elif git -C "$rtthread_dir" rev-parse --verify "refs/remotes/origin/$rtthread_ref^{commit}" >/dev/null 2>&1; then
        expected=$(git -C "$rtthread_dir" rev-parse "refs/remotes/origin/$rtthread_ref^{commit}") || return 1
    else
        return 1
    fi

    actual=$(git -C "$rtthread_dir" rev-parse HEAD) || return 1
    [ "$actual" = "$expected" ]
}

reset_rtthread_checkout() {
    rtthread_dir=$1

    git -C "$rtthread_dir" reset --hard
    git -C "$rtthread_dir" clean -fdx
}

prepare_rtthread_checkout() {
    rtthread_ref=$1
    rtthread_work=$2
    rtthread_dir=$3

    case "${RTTHREAD_REUSE_WORKDIR:-0}" in
        1|yes|true|TRUE|on|ON)
            ensure_removable_workdir "$rtthread_work"
            mkdir -p "$rtthread_work"
            : > "$rtthread_work/.rtthread-littlefs-ci-workdir"
            if rtthread_checkout_matches "$rtthread_ref" "$rtthread_dir"; then
                printf 'reusing RT-Thread checkout for branch/tag %s\n' "$rtthread_ref"
                reset_rtthread_checkout "$rtthread_dir"
                return
            fi
            reset_workdir "$rtthread_work"
            clone_rtthread "$rtthread_ref" "$rtthread_dir"
            ;;
        0|no|false|FALSE|off|OFF)
            reset_workdir "$rtthread_work"
            clone_rtthread "$rtthread_ref" "$rtthread_dir"
            ;;
        *)
            fail "RTTHREAD_REUSE_WORKDIR must be 0 or 1: ${RTTHREAD_REUSE_WORKDIR:-}"
            ;;
    esac
}

verify_symbols() {
    bsp_dir=$1
    nm_cmd=$2
    size_cmd=$3
    elf_name=$4
    elf_file="$bsp_dir/$elf_name"

    [ -f "$elf_file" ] || fail "expected ELF output not found: $elf_file"
    need_cmd "$nm_cmd"

    check_nm_symbol "$nm_cmd" "$elf_file" dfs_lfs_init || \
        fail "dfs_lfs_init symbol not found in $elf_file"
    check_nm_symbol "$nm_cmd" "$elf_file" lfs_mount || \
        fail "lfs_mount symbol not found in $elf_file"

    "$size_cmd" "$elf_file" || true
    printf 'verified littlefs symbols in %s\n' "$elf_file"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

need_cmd git
need_cmd tar
need_cmd awk
need_cmd dirname
need_cmd find
need_cmd getconf
need_cmd grep
need_cmd scons
need_cmd sleep

repo_root=$(pwd -P)
rtthread_ref=${RTTHREAD_REF:-master}
rtthread_bsp=${RTTHREAD_BSP:-bsp/qemu-vexpress-a9}
rtthread_dfs_version=${RTTHREAD_DFS_VERSION:-v1}
export RTT_CC=${RTT_CC:-gcc}
toolchain_prefix=$(gnu_toolchain_prefix "$RTT_CC")
cc_cmd=${toolchain_prefix}gcc
nm_cmd=${NM:-${toolchain_prefix}nm}
size_cmd=${SIZE:-${toolchain_prefix}size}
rtthread_elf=${RTTHREAD_ELF:-rtthread.elf}
need_cmd "$cc_cmd"
need_cmd "$nm_cmd"
need_cmd "$size_cmd"
ensure_safe_bsp_path "$rtthread_bsp"
ensure_safe_elf_name "$rtthread_elf"
ensure_supported_dfs_version "$rtthread_dfs_version"
rtthread_work=$(normalize_path "${RTTHREAD_WORKDIR:-${RUNNER_TEMP:-$repo_root/_ci}/rt-thread-work}")
ensure_safe_workdir "$rtthread_work" "$repo_root"
rtthread_dir="$rtthread_work/rt-thread"
bsp_dir="$rtthread_dir/$rtthread_bsp"
package_dir="$bsp_dir/packages/littlefs"

prepare_rtthread_checkout "$rtthread_ref" "$rtthread_work" "$rtthread_dir"

[ -d "$bsp_dir" ] || fail "RT-Thread BSP not found: $rtthread_bsp"

copy_package "$repo_root" "$package_dir" "$rtthread_work"
write_packages_kconfig "$bsp_dir/packages"
write_packages_sconscript "$bsp_dir/packages"
write_compile_check_source "$bsp_dir"

export RTT_ROOT="$rtthread_dir"
RTT_EXEC_PATH=${RTT_EXEC_PATH:-$(dirname "$(command -v "$cc_cmd")")}
export RTT_EXEC_PATH
export PYTHONPATH="$rtthread_dir/tools${PYTHONPATH:+:$PYTHONPATH}"

cd "$bsp_dir"
run_scons_pyconfig

apply_littlefs_kconfig_profile .config "$rtthread_dfs_version" "$rtthread_dir"
run_scons_pyconfig

grep -E '^(CONFIG_)?(PKG_USING_LITTLEFS|RT_USING_DFS|DFS_|RT_USING_MTD_NOR|RT_USING_DEVICE|RT_USING_HEAP|RT_USING_MUTEX)' \
    .config rtconfig.h rtconfig.py || true
verify_rtconfig_symbols rtconfig.h "$rtthread_dfs_version" "$rtthread_dir"

scons -j"$(getconf _NPROCESSORS_ONLN)"
verify_symbols "$bsp_dir" "$nm_cmd" "$size_cmd" "$rtthread_elf"
