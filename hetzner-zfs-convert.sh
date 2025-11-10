#!/bin/bash

# Help function
show_help() {
cat << 'EOF'
Debian ZFS Setup Script - Automated ZFS root installation for Debian from Rescue console or Live ISO

USAGE:
    debian-zfs-setup.sh [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --debug             Enable debug mode (set -x with line numbers)
    -j, --jump-to TARGET    Jump to specific function or line number
                           Examples: -j find_suitable_disks, -j 600, -j 300-400
    -n, --no-skips LIST     Disable skipping for specific functions/lines
                           Examples: -n func1,func2 -n 300-400,func1
    --hostname NAME         Set target hostname
    --swap-size GB          Set swap size in GB (0 for no swap)
    --arc-max MB            Set ZFS ARC max size in MB
    --encrypt               Enable root pool encryption
    --experimental          Use experimental ZFS packages
    --ipv4-only             Disable IPv6 configuration even if available
    --no-reboot             Disable automatic reboot at the end of the installation
    --keyboard-layout KEYBOARD_LAYOUT
                          Set keyboard layout (default: us)
                          Supported layouts: de, us, en, en-us

DEBUG OPTIONS:
    DEBUG=1                 Enable debug mode (same as -d)
    DEBUG_JUMP_TO=TARGET    Jump to specific target (same as -j)
    DEBUG_NO_SKIPS=LIST     Disable skipping (same as -n)

EXAMPLES:
    # Basic installation
    ./debian-zfs-setup.sh

    # Debug mode with jump to disk selection
    ./debian-zfs-setup.sh -d -j select_disks

    # Jump to line 600 but execute find_suitable_disks
    ./debian-zfs-setup.sh -j 600 -n find_suitable_disks

    # Pre-configure some settings
    ./debian-zfs-setup.sh --hostname myserver --swap-size 4 --arc-max 512

    # Complex debugging scenario
    ./debian-zfs-setup.sh -d -j 700 -n find_suitable_disks,select_disks,500-600

ENVIRONMENT VARIABLES:
    DEBIAN_VERSION          Target Debian version (default: trixie)
    DEB_PACKAGES_REPO       Debian packages repository URL
    DEB_SECURITY_REPO       Debian security repository URL

NOTES:
    - All data on selected disks will be destroyed
    - Run in screen session for network resilience: screen -S zfs
    - Use Ctrl+C to abort, Esc twice to cancel dialogs
    - Script automatically handles IPv6/IPv4 network configuration
    - ZFS swap volumes use optimized 8K block size to avoid warnings
    - Disable autoreboot to enable user to check the installation
    - Keyboard layout can be set with --keyboard-layout option
EOF
}

# Parse command line arguments using getopt
parse_arguments() {
  # Define options
  local short_opts="hdj:n:"
  local long_opts="help,debug,jump-to:,no-skips:,hostname:,swap-size:,arc-max:,encrypt,experimental,ipv4-only,no-reboot,keyboard-layout:"
  
  # Parse arguments
  local parsed
  if ! parsed=$(getopt -o "$short_opts" -l "$long_opts" -n "$(basename "$0")" -- "$@"); then
    echo "Use -h or --help for usage information"
    exit 1
  fi
  
  # Set parsed arguments
  eval set -- "$parsed"
  
  # Process arguments
  while true; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      -d|--debug)
        export DEBUG=1
        shift
        ;;
      -j|--jump-to)
        export DEBUG_JUMP_TO="$2"
        shift 2
        ;;
      -n|--no-skips)
        export DEBUG_NO_SKIPS="$2"
        shift 2
        ;;
      --hostname)
        export PRESET_HOSTNAME="$2"
        shift 2
        ;;
      --swap-size)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
          export PRESET_SWAP_SIZE="$2"
        else
          echo "Error: --swap-size requires a number (GB)"
          exit 1
        fi
        shift 2
        ;;
      --arc-max)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
          export PRESET_ARC_MAX="$2"
        else
          echo "Error: --arc-max requires a number (MB)"
          exit 1
        fi
        shift 2
        ;;
      --encrypt)
        export PRESET_ENCRYPT=1
        shift
        ;;
      --experimental)
        export PRESET_EXPERIMENTAL=1
        shift
        ;;
      --ipv4-only)
        export PRESET_IPV4_ONLY=1
        shift
        ;;
      --no-reboot)
        export PRESET_NO_REBOOT=1
        shift
        ;;
      --keyboard-layout)
        export PRESET_KEYBOARD_LAYOUT="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Error: Unexpected argument $1"
        exit 1
        ;;
    esac
  done
  
  # Handle remaining positional arguments
  if [[ $# -gt 0 ]]; then
    echo "Error: Unexpected positional arguments: $*"
    echo "Use -h or --help for usage information"
    exit 1
  fi
}

# Parse arguments first
parse_arguments "$@"

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Debian 12 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set it OS to linux64, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname, ZFS ARC cache size et cetera
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

if [[ $DEBUG == 1 ]]; then
  # Set debug prompt to show script:line:function
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}(): '
  set -x 
fi

# Debug jump functionality
# Usage: DEBUG_JUMP_TO=function_name or DEBUG_JUMP_TO=line_number_range
# Usage: DEBUG_NO_SKIPS=1 to disable skipping (only mark target, but execute all)
# Usage: DEBUG_NO_SKIPS=func1,func2,300-400 to disable skipping for specific functions/lines
function debug_check_jump {
  if [[ -n "${DEBUG_JUMP_TO:-}" ]]; then
    local current_line=${BASH_LINENO[1]:-$LINENO}
    local current_func=${FUNCNAME[1]:-main}
    
    # Support function name jumping
    if [[ "$DEBUG_JUMP_TO" == "$current_func" ]]; then
      echo "=== DEBUG: *** TARGET REACHED *** function $current_func (line: $current_line) ==="
      unset DEBUG_JUMP_TO  # Avoid repeated jumps
      return 0
    fi
    
    # Support line number range jumping (format: start-end or exact)
    if [[ "$DEBUG_JUMP_TO" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
      if [[ "$DEBUG_JUMP_TO" =~ - ]]; then
        local start_line=${DEBUG_JUMP_TO%-*}
        local end_line=${DEBUG_JUMP_TO#*-}
        if [[ $current_line -ge $start_line && $current_line -le $end_line ]]; then
          echo "=== DEBUG: *** TARGET REACHED *** line range $DEBUG_JUMP_TO (current: $current_line, function: $current_func) ==="
          unset DEBUG_JUMP_TO
          return 0
        fi
      else
        if [[ $current_line -eq $DEBUG_JUMP_TO ]]; then
          echo "=== DEBUG: *** TARGET REACHED *** line $DEBUG_JUMP_TO (function: $current_func) ==="
          unset DEBUG_JUMP_TO
          return 0
        fi
      fi
      
      # Check if we should skip or just mark
      local no_skip=0
      
      # Parse DEBUG_NO_SKIPS settings
      if [[ "${DEBUG_NO_SKIPS:-}" == "1" ]]; then
        no_skip=1
      elif [[ -n "${DEBUG_NO_SKIPS:-}" ]]; then
        # Parse comma-separated list of functions and line ranges
        IFS=',' read -ra no_skip_items <<< "$DEBUG_NO_SKIPS"
        for item in "${no_skip_items[@]}"; do
          item=$(echo "$item" | tr -d ' ')  # Remove spaces
          if [[ "$item" =~ ^[0-9]+-[0-9]+$ ]]; then
            # Line range format: start-end
            local item_start=${item%-*}
            local item_end=${item#*-}
            if [[ $current_line -ge $item_start && $current_line -le $item_end ]]; then
              no_skip=1
              echo "=== DEBUG: NO_SKIP matched line range $item (current: $current_line) ==="
              break
            fi
          elif [[ "$item" =~ ^[0-9]+$ ]]; then
            # Single line number
            if [[ $current_line -eq $item ]]; then
              no_skip=1
              echo "=== DEBUG: NO_SKIP matched line $item ==="
              break
            fi
          else
            # Function name
            if [[ "$current_func" == "$item" ]]; then
              no_skip=1
              echo "=== DEBUG: NO_SKIP matched function $item ==="
              break
            fi
          fi
        done
      fi
      
      if [[ $no_skip -eq 1 ]]; then
        echo "=== DEBUG: Executing function $current_func (line: $current_line, target: $DEBUG_JUMP_TO) [NO_SKIPS enabled] ==="
        return 0
      else
        # If not at target line yet, skip current function
        echo "=== DEBUG: Skipping function $current_func (line: $current_line, target: $DEBUG_JUMP_TO) ==="
        return 1
      fi
    fi
  fi
  return 0
}

set -o errexit
set -o pipefail
set -o nounset

export TMPDIR=/tmp
export DEBIAN_FRONTEND=noninteractive

# Variables
v_bpool_name=
v_bpool_tweaks=
v_rpool_name=
v_rpool_tweaks=
declare -a v_selected_disks
v_swap_size=                 # integer
v_free_tail_space=           # integer
v_hostname=
v_kernel_variant=
v_zfs_arc_max_mb=
v_root_password=
v_encrypt_rpool=             # 0=false, 1=true
v_passphrase=
v_zfs_experimental=
v_suitable_disks=()
v_keyboard_layout=${PRESET_KEYBOARD_LAYOUT:-us}

# Constants
c_default_zfs_arc_max_mb=$(
  total_mem_mb=$(free -m | awk 'NR==2{print $2}' 2>/dev/null || echo 1024)
  if [[ $total_mem_mb -le 1024 ]]; then
    echo 256
  elif [[ $total_mem_mb -le 2048 ]]; then
    echo 512
  else
    echo $((total_mem_mb / 4))
  fi
)
c_default_swap_size_gb=$(
  total_mem_mb=$(free -m | awk 'NR==2{print $2}' 2>/dev/null || echo 1024)
  # Calculate 2x memory in GB (rounded up)
  echo $(((total_mem_mb * 2 + 1023) / 1024))
)
# Optimized for modern NVMe SSDs (8K sectors)
c_default_bpool_tweaks="-o ashift=13 -O compression=lz4"
c_default_rpool_tweaks="-o ashift=13 -O acltype=posixacl -O compression=zstd-9 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
#c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_zfs_mount_dir=/mnt
c_log_dir=$(dirname "$(mktemp)")/zfs-on-debian
c_install_log=$c_log_dir/install.log
c_lsb_release_log=$c_log_dir/lsb_release.log
c_disks_log=$c_log_dir/disks.log
c_efimode_enabled="$(if [[ -d /sys/firmware/efi/efivars ]]; then echo 1; else echo 0; fi)"

# --begin-- debian distribution related functions
# Constants (can be overridden by environment variables)
# Debian version - change this to upgrade to a different version (e.g., trixie for Debian 13)
# Mirror repositories - can use 163 mirror: http://mirrors.163.com/debian
c_deb_packages_repo=${DEB_PACKAGES_REPO:-https://deb.debian.org/debian}
c_deb_security_repo=${DEB_SECURITY_REPO:-https://deb.debian.org/debian-security}

## --begin-- 1. host part
function setup_host_apt_sources {
  # Ensure rescue system has non-free sources for ZFS installation
  echo "======= setting up host system apt sources =========="
  
  if host_codename=$(lsb_release -cs 2>/dev/null); then
    cat > "/etc/apt/sources.list" <<CONF
deb $c_deb_packages_repo $host_codename main contrib non-free non-free-firmware
deb $c_deb_packages_repo $host_codename-backports main contrib non-free non-free-firmware
deb $c_deb_packages_repo $host_codename-updates main contrib non-free non-free-firmware
deb $c_deb_security_repo $host_codename-security main contrib non-free non-free-firmware
CONF
    apt update
  else
    echo "Error: lsb_release failed"
    return 1
  fi
}

function install_host_zfs {
  debug_check_jump || return 0
  # Install compatible ZFS on host system
  # This function ensures ZFS version compatibility between host and target
  # Minimum supported host version: Debian 12 (bookworm)
  echo "======= installing zfs on host system =========="
  setup_host_apt_sources || return 1

  echo "Installing kernel headers for current kernel($(uname -r)) if needed"
  apt install --yes "linux-headers-$(uname -r)" "linux-image-$(uname -r)" 2>/dev/null;

  # Set up ZFS installation based on host system
  rm -f /usr/local/sbin/fsck.zfs /usr/local/sbin/zdb /usr/local/sbin/zed /usr/local/sbin/zfs /usr/local/sbin/zfs_ids_to_path /usr/local/sbin/zgenhostid /usr/local/sbin/zhack /usr/local/sbin/zinject /usr/local/sbin/zpool /usr/local/sbin/zstream /usr/local/sbin/zstreamdump /usr/local/sbin/ztest >/dev/null 2>&1
  echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
  apt install --yes -t $host_codename-backports zfs-dkms zfsutils-linux gdisk dosfstools zfs-zed --no-install-recommends --no-upgrade
  zfs --version
  echo "ZFS installation completed"
}

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

# shellcheck disable=SC2120
function print_step_info_header {
  echo -n "
###############################################################################
# ${FUNCNAME[1]}"

  if [[ "${1:-}" != "" ]]; then
    echo -n " $1" 
  fi


  echo "
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

function display_intro_banner {
  debug_check_jump || return 0
  # shellcheck disable=SC2119
  print_step_info_header

  local dialog_message='Hello!
This script will prepare the ZFS pools, then install and configure minimal Debian 12 with ZFS root on Hetzner hosting VPS instance
The script with minimal changes may be used on any other hosting provider  supporting KVM virtualization and offering Debian-based rescue system.
In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'
  dialog --msgbox "$dialog_message" 30 100
}

function store_os_distro_information {
  # shellcheck disable=SC2119
  print_step_info_header

  lsb_release --all > "$c_lsb_release_log"
}

function check_prerequisites {
  # shellcheck disable=SC2119
  print_step_info_header
  if [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  fi
  if [[ ! -r /root/.ssh/authorized_keys ]]; then
    echo "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
    exit 1
  fi
  if ! dpkg-query --showformat="\${Status}" -W dialog 2> /dev/null | grep -q "install ok installed"; then
    apt install --yes dialog
  fi
}

function initial_load_debian_zed_cache {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/$v_rpool_name"
  chroot_execute "ln -sf /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  chroot_execute "zed -F &"

  local success=0

  if [[ ! -e "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" ]] || [[ -e "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" && (( $(find "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" -type f -printf '%s' 2> /dev/null) == 0 )) ]]; then  
    chroot_execute "zfs set canmount=noauto $v_rpool_name"

    SECONDS=0

    while (( SECONDS++ <= 120 )); do
      if [[ -e "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" ]] && (( $(find "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" -type f -printf '%s' 2> /dev/null) > 0 )); then
        success=1
        break
      else
        sleep 1
      fi
    done
  else
    success=1
  fi

  if (( success != 1 )); then
    echo "Fatal zed daemon error: the ZFS cache hasn't been updated by ZED!"
    exit 1
  fi

  chroot_execute "pkill zed"

  sed -Ei "s|/$c_zfs_mount_dir/?|/|g" "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name"
}

function find_suitable_disks {
  debug_check_jump || return 0
  # shellcheck disable=SC2119
  print_step_info_header

  udevadm trigger

  # shellcheck disable=SC2012
  ls -l /dev/disk/by-path | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"
  # Use by-path to support all disk types including virtio, ata, nvme, scsi

  local candidate_disk_ids
  local mounted_devices

  # Get unique real device paths (automatic deduplication)
  candidate_real_devices=$(find /dev/disk/by-path -type l -maxdepth 1 -not -regex '.+-part[0-9]+$' | sort | uniq)
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"
  canonical_mounted_devices=$(echo "$mounted_devices" | xargs -I {} readlink -f {} | sort | uniq)

  while read -r real_device || [[ -n "$real_device" ]]; do
    local device_info
    local block_device_basename

    device_info="$(udevadm info --query=property "$real_device")"
    block_device_basename="$(basename "$real_device")"

    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^`readlink -f $real_device`\$" <<< "$canonical_mounted_devices"; then
        v_suitable_disks+=("$real_device")
      fi
    fi

    cat >> "$c_disks_log" << LOG

## DEVICE: $real_device ################################

$(udevadm info --query=property "$real_device")

LOG

  done < <(echo -n "$candidate_real_devices")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you think this is a bug, please open an issue on https://github.com/terem42/zfs-hetzner-vm/issues, and attach the file `'"$c_disks_log"'`.
'
    dialog --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

function select_disks {
  debug_check_jump || return 0
  # shellcheck disable=SC2119
  print_step_info_header

  while true; do
    local menu_entries_option=()

    if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
      local disk_selection_status=ON
    else
      local disk_selection_status=OFF
    fi

    for disk_id in "${v_suitable_disks[@]}"; do
      local block_device_basename
      block_device_basename="$(basename "$disk_id")"
      menu_entries_option+=("$disk_id" "($block_device_basename)" "$disk_selection_status")
    done

    local dialog_message="Select the ZFS devices (multiple selections can be in mirror or strip).

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
    mapfile -t v_selected_disks < <(dialog --separate-output --checklist "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

    if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
      break
    fi
  done

  print_variables v_selected_disks
}

function ask_swap_size {
  # shellcheck disable=SC2119
  print_step_info_header

  # Check for preset value
  if [[ -n "${PRESET_SWAP_SIZE:-}" ]]; then
    v_swap_size="$PRESET_SWAP_SIZE"
    echo "Using preset swap size: ${v_swap_size}GB"
  else
    local swap_size_invalid_message=

    while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
      v_swap_size=$(dialog --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap, default: ${c_default_swap_size_gb}GB = 2x memory):" 30 100 "$c_default_swap_size_gb" 3>&1 1>&2 2>&3)

      swap_size_invalid_message="Invalid swap size! "
    done
  fi

  print_variables v_swap_size
}

function ask_free_tail_space {
  # shellcheck disable=SC2119
  print_step_info_header

  local tail_space_invalid_message=

  while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
    v_free_tail_space=$(dialog --inputbox "${tail_space_invalid_message}Enter the space to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

    tail_space_invalid_message="Invalid size! "
  done

  print_variables v_free_tail_space
}

function ask_zfs_arc_max_size {
  # shellcheck disable=SC2119
  print_step_info_header

  # Check for preset value
  if [[ -n "${PRESET_ARC_MAX:-}" ]]; then
    v_zfs_arc_max_mb="$PRESET_ARC_MAX"
    echo "Using preset ZFS ARC max size: ${v_zfs_arc_max_mb}MB"
  else
    local zfs_arc_max_invalid_message=

    while [[ ! $v_zfs_arc_max_mb =~ ^[0-9]+$ ]]; do
      v_zfs_arc_max_mb=$(dialog --inputbox "${zfs_arc_max_invalid_message}Enter ZFS ARC cache max size in Mb (minimum 64Mb, enter 0 for ZFS default value, the default will take up to 50% of memory):" 30 100 "$c_default_zfs_arc_max_mb" 3>&1 1>&2 2>&3)

      zfs_arc_max_invalid_message="Invalid size! "
    done
  fi

  print_variables v_zfs_arc_max_mb
}


function ask_pool_names {
  # shellcheck disable=SC2119
  print_step_info_header

  local bpool_name_invalid_message=

  while [[ ! $v_bpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_bpool_name=$(dialog --inputbox "${bpool_name_invalid_message}Insert the name for the boot pool" 30 100 bpool 3>&1 1>&2 2>&3)

    bpool_name_invalid_message="Invalid pool name! "
  done
  local rpool_name_invalid_message=

  while [[ ! $v_rpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_rpool_name=$(dialog --inputbox "${rpool_name_invalid_message}Insert the name for the root pool" 30 100 rpool 3>&1 1>&2 2>&3)

    rpool_name_invalid_message="Invalid pool name! "
  done

  print_variables v_bpool_name v_rpool_name
}

function ask_pool_tweaks {
  # shellcheck disable=SC2119
  print_step_info_header

  v_bpool_tweaks=$(dialog --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)
  v_rpool_tweaks=$(dialog --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)

  print_variables v_bpool_tweaks v_rpool_tweaks
}


function ask_root_password {
  # shellcheck disable=SC2119
  print_step_info_header

  set +x
  local password_invalid_message=
  local password_repeat=-

  while [[ "$v_root_password" != "$password_repeat" || "$v_root_password" == "" ]]; do
    v_root_password=$(dialog --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
    password_repeat=$(dialog --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

    password_invalid_message="Passphrase empty, or not matching! "
  done
  set -x
}

function determine_kernel_variant {
  if dmidecode | grep -q vServer; then
    v_kernel_variant="-cloud"
  fi
}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "DEBIAN_FRONTEND=noninteractive $1"
}


function unmount_and_export_fs {
  # shellcheck disable=SC2119
  print_step_info_header

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  SECONDS=0
  zpools_exported=99
  echo "===========exporting zfs pools============="
  set +e
  while (( zpools_exported == 99 )) && (( SECONDS++ <= 60 )); do    
    if zpool export -a 2> /dev/null; then
      zpools_exported=1
      echo "all zfs pools were succesfully exported"
      break;
    else
      sleep 1
     fi
  done
  set -e
  if (( zpools_exported != 1 )); then
    echo "failed to export zfs pools"
    exit 1
  fi
}

function mount_and_pack_old_system {
  echo "======= Packing old system =========="
  mount /dev/sda1 /mnt
  tar -c -z -f rootfs.tar.gz -C /mnt .
  umount /mnt
}

#################### MAIN ################################
export LC_ALL=en_US.UTF-8
export NCURSES_NO_UTF8_ACS=1

check_prerequisites

activate_debug

display_intro_banner

find_suitable_disks

select_disks

ask_swap_size

ask_free_tail_space

ask_pool_names

ask_pool_tweaks

ask_zfs_arc_max_size

determine_kernel_variant

clear

mount_and_pack_old_system

install_host_zfs || {
  echo "Error: Failed to install ZFS on host system"
  exit 1
}

echo "======= partitioning the disk =========="

  if [[ $v_free_tail_space -eq 0 ]]; then
    tail_space_parameter=0
  else
    tail_space_parameter="-${v_free_tail_space}G"
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    echo "Partitioning disk: $selected_disk"
    # Clear existing partition table
    wipefs --all --force "$selected_disk" || {
      echo "Failed to wipe $selected_disk"
      exit 1
    }
    
    # Create all partitions in one go for atomicity
    sgdisk -a16 \
            -n1:24K:+1000K -t1:EF02 \
            -n2:1M:+1G -t1:EF00 \
            -n3:0:+2G -t2:BF01 \
            -n4:0:"$tail_space_parameter" -t3:BF01 \
            "$selected_disk" || {
            echo "Failed to create partitions on $selected_disk"
            exit 1
          }
    
    # Force kernel to re-read partition table
    if command -v partprobe >/dev/null 2>&1; then
      partprobe "$selected_disk" 2>/dev/null || true
    elif command -v blockdev >/dev/null 2>&1; then
      # Alternative: force re-read using blockdev
      blockdev --rereadpt "$selected_disk" 2>/dev/null || true
    else
      echo "No partprobe or blockdev found, skipping partition table re-read"
    fi
    
    # Wait for devices to settle
    udevadm settle
    #TODO better way to wait for devices to settle?
    sleep 2
    
    # Verify partitions were created
    if [[ ! -b "${selected_disk}-part1" ]] || [[ ! -b "${selected_disk}-part2" ]] || [[ ! -b "${selected_disk}-part3" ]] || [[ ! -b "${selected_disk}-part4" ]]; then
      echo "ERROR: Not all partitions were created on $selected_disk"
      echo "Expected: ${selected_disk}-part1, ${selected_disk}-part2, ${selected_disk}-part3, ${selected_disk}-part4"
      echo "Actual:"
      ls -la "${selected_disk}"* || true
      exit 1
    fi
    
    echo "Successfully created partitions on $selected_disk"
  done

  udevadm settle

echo "======= create zfs pools and datasets =========="

echo "======= cleaning up existing pools =========="
# Clean up any existing pools that might conflict
zpool export bpool 2>/dev/null || true
zpool export rpool 2>/dev/null || true
echo "Existing pools cleaned up"

echo "======= preparing mount directory =========="
# Unmount anything in /mnt if mounted
if mountpoint -q "$c_zfs_mount_dir"; then
  umount -R "$c_zfs_mount_dir" || true
fi

# Clean up the mount directory
# TODO: safe way to clean up the mount directory?
rm -rf $c_zfs_mount_dir
[[ -d $c_zfs_mount_dir ]] && {
  echo "rm failed, still in use of $c_zfs_mount_dir"
  exit 1
}
mkdir -p $c_zfs_mount_dir

echo "Mount directory prepared"

  encryption_options=()
  rpool_disks_partitions=()
  bpool_disks_partitions=()
  efi_disks_partitions=()
  # Get partition UUIDs after device settlement (more reliable than hardcoded -partN)
  for selected_disk in "${v_selected_disks[@]}"; do    
    # Get PARTUUIDs for each partition type
    rpool_partuuid=$(lsblk -no PARTUUID "${selected_disk}-part4" 2>/dev/null | tr -d '\n ')
    bpool_partuuid=$(lsblk -no PARTUUID "${selected_disk}-part3" 2>/dev/null | tr -d '\n ')
    efi_partuuid=$(lsblk -no PARTUUID "${selected_disk}-part2" 2>/dev/null | tr -d '\n ')
    
    # Store UUID-based paths
    if [[ -n "$rpool_partuuid" ]]; then
      rpool_disks_partitions+=("/dev/disk/by-partuuid/$rpool_partuuid")
    fi
    if [[ -n "$bpool_partuuid" ]]; then
      bpool_disks_partitions+=("/dev/disk/by-partuuid/$bpool_partuuid")
    fi
    if [[ -n "$efi_partuuid" ]]; then
      efi_disks_partitions+=("$efi_partuuid")
    fi
  done
  pools_mirror_option=
  if [[ ${#v_selected_disks[@]} -gt 1 ]]; then
    if dialog --defaultno --yesno "Do you want to use mirror mode for ${v_selected_disks[*]}?" 30 100; then 
      pools_mirror_option=mirror
    fi
  fi

# Create boot pool without automatic mounting to avoid directory conflicts
[[ -d $c_zfs_mount_dir ]] || mkdir -p $c_zfs_mount_dir

echo "Creating boot pool: $v_bpool_name"
# shellcheck disable=SC2086
zpool create \
  $v_bpool_tweaks \
  -m none \
  -o cachefile=/etc/zpool.cache \
  -o compatibility=grub2 \
  -O mountpoint=none -R $c_zfs_mount_dir -f \
  $v_bpool_name $pools_mirror_option "${bpool_disks_partitions[@]}"

# Clean up any auto-created directories from pool creation
# if [[ -d $c_zfs_mount_dir/boot ]]; then
#   echo "Cleaning up auto-created boot directory from pool creation"
#   umount -R $c_zfs_mount_dir/boot 2>/dev/null || true
#   rm -rf $c_zfs_mount_dir/boot
# fi

# Create root pool
echo "Creating root pool: $v_rpool_name"

# shellcheck disable=SC2086
echo -n "$v_passphrase" | zpool create \
  $v_rpool_tweaks \
  -m none \
  -o cachefile=/etc/zpool.cache \
  "${encryption_options[@]}" \
  -O mountpoint=none -R $c_zfs_mount_dir -f \
  $v_rpool_name $pools_mirror_option "${rpool_disks_partitions[@]}"

echo "Creating ZFS datasets..."
zfs create -o canmount=off -o mountpoint=none "$v_rpool_name/ROOT"
zfs create -o canmount=off -o mountpoint=none "$v_bpool_name/BOOT"

echo "Creating and mounting root filesystem..."
zfs create -o canmount=noauto -o mountpoint=/ "$v_rpool_name/ROOT/debian"
zfs mount "$v_rpool_name/ROOT/debian"

echo "Creating and mounting boot filesystem..."
zfs create -o canmount=noauto -o mountpoint=/boot "$v_bpool_name/BOOT/debian"
zfs mount "$v_bpool_name/BOOT/debian"

if [[ $v_swap_size -gt 0 ]]; then
  # Use 8K volblocksize for swap to avoid ZFS warnings (minimum recommended)
  swap_blocksize=8192
  system_pagesize=$(getconf PAGESIZE)
  if [[ $system_pagesize -gt $swap_blocksize ]]; then
    swap_blocksize=$system_pagesize
  fi
  echo "Creating swap volume with ${swap_blocksize}-byte blocks"
  
  zfs create \
    -V "${v_swap_size}G" -b "$swap_blocksize" \
    -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
    "$v_rpool_name/swap"
  udevadm settle
  #TODO: why need sleep 2?
  sleep 2
  mkswap -f "/dev/zvol/$v_rpool_name/swap"
fi

echo "======= extracting old system =========="
tar -x -z -f rootfs.tar.gz -C "$c_zfs_mount_dir"


echo "======= create filesystem on EFI partition(s) =========="
  for efi_partuuid in "${efi_disks_partitions[@]}"; do
    mkfs.fat -F32 "/dev/disk/by-partuuid/$efi_partuuid"
  done
  mkdir -p "$c_zfs_mount_dir/boot/efi"
  mount "/dev/disk/by-partuuid/${efi_disks_partitions[0]}" "$c_zfs_mount_dir/boot/efi"
echo "======= setting up initial system packages =========="


zfs set devices=off "$v_rpool_name"

echo "======= preparing the jail for chroot =========="
echo "======= preparing the jail for chroot =========="
for virtual_fs_dir in proc sys dev; do
  mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
done
if [ -h $c_zfs_mount_dir/etc/resolv.conf ]; then
  link="$(readlink -m $c_zfs_mount_dir/etc/resolv.conf)"
  if [ ! -d ${link%/*} ]; then
    mkdir -p -v ${link%/*}
  fi
  cmp --silent /etc/resolv.conf ${link} || cp /etc/resolv.conf ${link}
fi


chroot_execute "apt update"

echo "======= installing latest kernel============="
# linux-headers-generic linux-image-generic
chroot_execute "apt install --yes linux-image${v_kernel_variant}-amd64 linux-headers${v_kernel_variant}-amd64 dpkg-dev"

# cryptsetup is not compatible with zfs
chroot_execute "apt purge cryptsetup* --yes"

echo "======= installing zfs packages =========="
chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
chroot_execute "apt install --yes zfs-initramfs zfs-dkms zfsutils-linux zfs-zed"
chroot_execute 'cat << DKMS > /etc/dkms/zfs.conf
# override for /usr/src/zfs-*/dkms.conf:
# always rebuild initrd when zfs module has been changed
# (either by a ZFS update or a new kernel version)
REMAKE_INITRD="yes"
DKMS'

echo "======= setting up zfs cache =========="

cp /etc/zpool.cache "$c_zfs_mount_dir/etc/zfs/zpool.cache"

echo "========setting up zfs module parameters========"
chroot_execute "echo options zfs zfs_arc_max=$((v_zfs_arc_max_mb * 1024 * 1024)) >> /etc/modprobe.d/zfs.conf"

echo "========setting up zfs import bpool=========="
cat > "$c_zfs_mount_dir/etc/initramfs-tools/scripts/local-top/zfs-import-${v_bpool_name}" << EOF
#!/bin/sh
PREREQ="zfs"

prereqs() {
    echo "\$PREREQ"
}

case \$1 in
prereqs)
    prereqs
    exit 0
    ;;
esac

if ! zpool list ${v_bpool_name} >/dev/null 2>&1; then
    zpool import -N ${v_bpool_name} 2>/dev/null || \
    zpool import -d /dev/disk/by-path -N ${v_bpool_name} 2>/dev/null || \
    zpool import -c /etc/zfs/zpool.cache -N ${v_bpool_name} 2>/dev/null || true
fi
EOF

chmod +x "$c_zfs_mount_dir/etc/initramfs-tools/scripts/local-top/zfs-import-${v_bpool_name}"

echo "======= setting up grub =========="
if (( c_efimode_enabled == 1 )); then
  chroot_execute "apt install --yes grub-efi-amd64"
else
  chroot_execute "echo 'grub-pc grub-pc/install_devices_empty   boolean true' | debconf-set-selections"
  chroot_execute "apt install --yes grub-legacy"
  chroot_execute "apt install --yes grub-pc"
fi

if (( c_efimode_enabled == 1 )); then
  #chroot_execute grub-probe /boot
  chroot_execute grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
else
  for disk in ${v_selected_disks[@]}; do
    chroot_execute "grub-install --recheck $disk"
  done
fi

chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"net.ifnames=0\"|' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=$v_rpool_name/ROOT/debian\"|g' /etc/default/grub"

chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
chroot_execute "sed -i 's/splash//g' /etc/default/grub"
chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"

#TODO: how to make this happen after the install is finished, when grub-install happens later again?
for ((i = 1; i < ${#efi_disks_partitions[@]}; i++)); do
  dd if="/dev/disk/by-partuuid/${efi_disks_partitions[0]}" of="/dev/disk/by-partuuid/${efi_disks_partitions[i]}"
done

echo "========running packages upgrade and autoremove==========="
chroot_execute "apt upgrade --yes"

echo "======= update initramfs =========="
chroot_execute "update-initramfs -u -k all"

echo "======= update grub =========="
chroot_execute "update-grub"

echo "======= setting up zed =========="
initial_load_debian_zed_cache


echo "======= setting mountpoints =========="
if (( c_efimode_enabled == 1 )); then
  umount "$c_zfs_mount_dir/boot/efi"
fi

chroot_execute "zfs set mountpoint=legacy $v_bpool_name/BOOT/debian"
chroot_execute "echo $v_bpool_name/BOOT/debian /boot zfs nodev,relatime,x-systemd.requires=zfs-mount.service,x-systemd.device-timeout=10 0 0 > /etc/fstab"

echo "========= add swap, if defined"
if [[ $v_swap_size -gt 0 ]]; then
  chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab"
fi

if (( c_efimode_enabled == 1 )); then
  chroot_execute "echo /dev/disk/by-partuuid/${efi_disks_partitions[0]} /boot/efi vfat defaults 0 2 >> /etc/fstab"
fi

chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"

echo "======= unmounting filesystems and zfs pools =========="
unmount_and_export_fs

if [[ "${PRESET_NO_REBOOT:-}"  == "1" ]]; then
  echo "======== setup complete, please reboot manually ==============="
else
  echo "======== setup complete, rebooting ==============="
  reboot
fi
