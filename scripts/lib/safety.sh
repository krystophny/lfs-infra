#!/bin/bash
# LFS Safety Library
# Prevents accidental damage to host systems
# Source this at the top of all LFS scripts

# Exit immediately on any validation failure
set -euo pipefail

# ANSI colors for error messages
_SAFETY_RED='\033[0;31m'
_SAFETY_YELLOW='\033[1;33m'
_SAFETY_NC='\033[0m'

_safety_die() {
    echo -e "${_SAFETY_RED}[SAFETY ERROR]${_SAFETY_NC} $*" >&2
    exit 1
}

_safety_warn() {
    echo -e "${_SAFETY_YELLOW}[SAFETY WARN]${_SAFETY_NC} $*" >&2
}

# Check if running on Linux - these scripts are Linux-only
require_linux() {
    local os
    os="$(uname -s)"
    if [[ "${os}" != "Linux" ]]; then
        _safety_die "These scripts are Linux-only. Detected OS: ${os}
This prevents accidental damage to non-Linux host systems (macOS, BSD, etc.)
If you are developing/testing, use a Linux VM or container."
    fi
}

# Validate LFS variable is set and safe
# Call this before any operation that uses LFS
validate_lfs_variable() {
    # Must be set
    if [[ -z "${LFS:-}" ]]; then
        _safety_die "LFS variable is not set.
Set it with: export LFS=/mnt/lfs"
    fi

    # Must be absolute path
    if [[ "${LFS}" != /* ]]; then
        _safety_die "LFS must be an absolute path. Got: ${LFS}"
    fi

    # Forbidden values that could damage host system
    local forbidden_paths=(
        "/"
        "/bin"
        "/boot"
        "/dev"
        "/etc"
        "/home"
        "/lib"
        "/lib64"
        "/opt"
        "/proc"
        "/root"
        "/run"
        "/sbin"
        "/srv"
        "/sys"
        "/tmp"
        "/usr"
        "/var"
    )

    local lfs_normalized
    # Remove trailing slashes for comparison
    lfs_normalized="${LFS%/}"
    [[ -z "${lfs_normalized}" ]] && lfs_normalized="/"

    for forbidden in "${forbidden_paths[@]}"; do
        if [[ "${lfs_normalized}" == "${forbidden}" ]]; then
            _safety_die "DANGEROUS: LFS='${LFS}' would affect host system!
LFS must point to an isolated build directory (e.g., /mnt/lfs)"
        fi
    done

    # Warn if LFS is in a suspicious location
    case "${lfs_normalized}" in
        /mnt/*|/media/*|/build/*|/opt/lfs*|/var/tmp/*)
            # These are acceptable locations
            ;;
        *)
            _safety_warn "LFS='${LFS}' is in an unusual location. Proceed with caution."
            ;;
    esac
}

# Validate that a path is safely within LFS
# Usage: validate_path_in_lfs "/some/path"
validate_path_in_lfs() {
    local path="$1"
    local resolved_path

    validate_lfs_variable

    # Path must be absolute
    if [[ "${path}" != /* ]]; then
        _safety_die "Path must be absolute: ${path}"
    fi

    # Resolve symlinks to get canonical path
    # Use readlink -f if available, otherwise use realpath
    if command -v realpath >/dev/null 2>&1; then
        # Get parent directory if path doesn't exist yet
        if [[ -e "${path}" ]]; then
            resolved_path="$(realpath "${path}")"
        else
            local parent_dir
            parent_dir="$(dirname "${path}")"
            if [[ -d "${parent_dir}" ]]; then
                resolved_path="$(realpath "${parent_dir}")/$(basename "${path}")"
            else
                resolved_path="${path}"
            fi
        fi
    else
        resolved_path="${path}"
    fi

    # Normalize LFS path
    local lfs_normalized="${LFS%/}"

    # Check if path starts with LFS
    if [[ "${resolved_path}" != "${lfs_normalized}"/* ]] && \
       [[ "${resolved_path}" != "${lfs_normalized}" ]]; then
        _safety_die "Path '${path}' is outside LFS ('${LFS}')
This operation would affect the host system!"
    fi
}

# Safe rm -rf that validates path is within LFS
# Usage: safe_rm_rf "/path/to/delete"
safe_rm_rf() {
    local path="$1"

    validate_path_in_lfs "${path}"

    # Additional safety: never delete LFS root itself
    local lfs_normalized="${LFS%/}"
    local path_normalized="${path%/}"

    if [[ "${path_normalized}" == "${lfs_normalized}" ]]; then
        _safety_die "Cannot delete LFS root directory itself"
    fi

    # Path must exist (avoids glob expansion issues)
    if [[ -e "${path}" ]]; then
        rm -rf "${path}"
    fi
}

# Safe chown that validates path is within LFS
# Usage: safe_chown "user:group" "/path"
safe_chown() {
    local ownership="$1"
    local path="$2"

    validate_path_in_lfs "${path}"
    chown -R "${ownership}" "${path}"
}

# Validate device path for safety
# Blocks obvious host devices
# Set LFS_I_KNOW_WHAT_I_AM_DOING=1 to skip interactive confirmation
validate_device() {
    local device="$1"

    # Must be a block device
    if [[ ! -b "${device}" ]]; then
        _safety_die "Not a block device: ${device}"
    fi

    # Get the base device (strip partition numbers)
    local base_device
    base_device="$(echo "${device}" | sed 's/[0-9]*$//' | sed 's/p$//')"

    # Check if this is the root device
    local root_device
    root_device="$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's/p$//' || true)"

    if [[ -n "${root_device}" ]] && [[ "${base_device}" == "${root_device}" ]]; then
        _safety_die "DANGEROUS: '${device}' appears to be on the root device!
This would destroy your host system."
    fi

    # Warn for common host disk patterns (can be bypassed for real hardware installs)
    case "${device}" in
        /dev/sda|/dev/nvme0n1|/dev/vda)
            if [[ "${LFS_I_KNOW_WHAT_I_AM_DOING:-}" == "1" ]]; then
                _safety_warn "Using '${device}' (confirmation bypassed via LFS_I_KNOW_WHAT_I_AM_DOING=1)"
            else
                _safety_warn "'${device}' is often the primary disk. Double-check this is correct!"
                _safety_warn "For real hardware installs, set LFS_I_KNOW_WHAT_I_AM_DOING=1 to skip this prompt"
                read -p "Are you SURE this is the correct device? Type 'YES' to continue: " confirm
                if [[ "${confirm}" != "YES" ]]; then
                    _safety_die "Aborted by user"
                fi
            fi
            ;;
    esac
}

# Validate disk file path (for VM images)
validate_disk_file() {
    local disk_file="$1"

    # Must be absolute path
    if [[ "${disk_file}" != /* ]]; then
        _safety_die "Disk file path must be absolute: ${disk_file}"
    fi

    # Must not be a block device
    if [[ -b "${disk_file}" ]]; then
        _safety_die "Disk file path points to a block device: ${disk_file}
Use validate_device() for block devices, or specify a regular file path."
    fi

    # Must not be in system directories
    local forbidden_prefixes=(
        "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64"
        "/proc" "/root" "/run" "/sbin" "/sys" "/usr" "/var"
    )

    for prefix in "${forbidden_prefixes[@]}"; do
        if [[ "${disk_file}" == "${prefix}"/* ]]; then
            _safety_die "Disk file cannot be in system directory: ${disk_file}"
        fi
    done
}

# Guard against modifying host fstab
# This function exists as a reminder that we should NOT modify host fstab
guard_host_fstab() {
    _safety_die "Modifying host /etc/fstab is disabled for safety.
If you need to mount the LFS partition, do it manually or use setup-disk.sh"
}

# Check if we're inside a Docker container
is_in_docker() {
    # Check for Docker-specific marker file
    [[ -f /.dockerenv ]] && return 0

    # Check cgroups for docker/container indicators
    if [[ -r /proc/1/cgroup ]]; then
        grep -qE 'docker|containerd|kubepods|lxc' /proc/1/cgroup 2>/dev/null && return 0
    fi

    # Check for container environment variable
    [[ -n "${container:-}" ]] && return 0

    return 1
}

# Check if we're in a chroot environment
is_in_chroot() {
    # Docker containers are NOT chroots for our purposes - they're full build environments
    is_in_docker && return 1

    # Check if root inode is 2 (typical for non-chroot)
    # In a chroot, the root inode is different
    if [[ "$(stat -c %i / 2>/dev/null)" != "2" ]]; then
        return 0
    fi

    # Alternative check: compare /proc/1/root to /
    if [[ -r /proc/1/root ]] && [[ "$(readlink -f /proc/1/root)" != "/" ]]; then
        return 0
    fi

    return 1
}

# Require that we're in a chroot (for scripts that should only run in LFS chroot)
require_chroot() {
    if ! is_in_chroot; then
        _safety_die "This script must be run inside the LFS chroot environment"
    fi
}

# Require that we're NOT in a chroot (for host-side scripts)
require_not_chroot() {
    if is_in_chroot; then
        _safety_die "This script must NOT be run inside a chroot environment"
    fi
}

# Validate that a critical path variable is INSIDE LFS
# Dies immediately if path would affect host system
# Usage: validate_critical_path "LFS_SOURCES" "${LFS_SOURCES}"
validate_critical_path() {
    local varname="$1"
    local path="$2"

    validate_lfs_variable

    # Path must be set
    if [[ -z "${path}" ]]; then
        _safety_die "${varname} is empty!"
    fi

    # Path must be absolute
    if [[ "${path}" != /* ]]; then
        _safety_die "${varname}='${path}' is not absolute!"
    fi

    # Normalize LFS path
    local lfs_normalized="${LFS%/}"

    # Path MUST start with LFS
    if [[ "${path}" != "${lfs_normalized}"/* ]] && [[ "${path}" != "${lfs_normalized}" ]]; then
        _safety_die "CRITICAL: ${varname}='${path}' is OUTSIDE LFS='${LFS}'!
This would write to your HOST system! Aborting immediately."
    fi
}

# Validate ALL critical build paths are inside LFS
# Call this BEFORE any file operations
# ONLY validates when running on HOST (not in chroot)
validate_all_build_paths() {
    # In chroot, paths like /usr/src ARE correct (they're inside the target)
    if is_in_chroot; then
        return 0
    fi

    validate_lfs_variable

    # Check all the paths that could cause damage to HOST
    [[ -n "${LFS_SOURCES:-}" ]] && validate_critical_path "LFS_SOURCES" "${LFS_SOURCES}"
    [[ -n "${LFS_BOOTSTRAP:-}" ]] && validate_critical_path "LFS_BOOTSTRAP" "${LFS_BOOTSTRAP}"
    [[ -n "${LFS_PKGCACHE:-}" ]] && validate_critical_path "LFS_PKGCACHE" "${LFS_PKGCACHE}"
    [[ -n "${LFS_LOGS:-}" ]] && validate_critical_path "LFS_LOGS" "${LFS_LOGS}"
    [[ -n "${PK_DB:-}" ]] && validate_critical_path "PK_DB" "${PK_DB}"
    [[ -n "${SOURCES_DIR:-}" ]] && validate_critical_path "SOURCES_DIR" "${SOURCES_DIR}"
    [[ -n "${BUILD_DIR:-}" ]] && validate_critical_path "BUILD_DIR" "${BUILD_DIR}"
    [[ -n "${PKG_CACHE:-}" ]] && validate_critical_path "PKG_CACHE" "${PKG_CACHE}"
}

# Comprehensive safety check for build scripts
# Call this at the start of all build scripts
safety_check() {
    require_linux
    require_not_chroot
    validate_lfs_variable
    validate_all_build_paths
}

# Safety check for chroot scripts
safety_check_chroot() {
    require_linux
    require_chroot
}

# Print safety status (for debugging)
safety_status() {
    echo "=== LFS Safety Status ==="
    echo "OS: $(uname -s)"
    echo "LFS: ${LFS:-<not set>}"
    echo "In Docker: $(is_in_docker && echo 'yes' || echo 'no')"
    echo "In chroot: $(is_in_chroot && echo 'yes' || echo 'no')"

    if [[ -n "${LFS:-}" ]]; then
        if validate_lfs_variable 2>/dev/null; then
            echo "LFS validation: PASS"
        else
            echo "LFS validation: FAIL"
        fi
    fi
    echo "========================="
}
