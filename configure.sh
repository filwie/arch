#!/usr/bin/env zsh
# vim: set ft=zsh sw=2 ts=2 sts=2:

# TODO:
# 1. groups should not get overwritten
# 2. when running without args do not start SSH


  declare -a USERS GROUPS PACKAGES

  LOG="/tmp/${0:t}-$(date +'%Y-%m-%dT%H:%M:%S').log"

  GROUPS=("users" "wheel")
  PACKAGES=("base" "base-devel" "sudo" "tmux" "openssh" "python" "python-pip")

  USER_ID=666
  NOPASSWD_SUDO=0
  CHANGE_PASSWD=0
  REFLECTOR=0
  INSTALL_PACKAGES=0
  HTTPS_MIRRORS=0
  DRY_RUN=0

  function usage () {
    local example
    example="USAGE: ${1} [-h/--help]"
    example+=" [{-u/--user USER}]"
    example+=" [{-g/--group GROUP}]"
    example+=" [-p/--passwd]"
    example+=" [-n/--nopasswd-sudo]"
    example+=" [-r/--reflector]"
    example+=" [-s/--https-mirrors]"
    example+=" [-i/--install-packages]"
    echo -e "${example}" >> /dev/stderr
    exit 1
  }

[[ ${#} -lt 1 ]] && usage

local help users groups nopasswd_sudo passwd reflector install_packages https_mirrors
zparseopts -D -E \
  h=help -help=help \
  d=dry_run -dry-run=dry_run \
  u+:=users g+:=groups \
  n=nopasswd_sudo -nopasswd-sudo=nopasswd_sudo \
  p=passwd -passwd=passwd \
  r=reflector -reflector=reflector \
  i=install_packages -install-packages=install_packages \
  s=https_mirrors -https-mirrors=https_mirrors

[[ -n "${help}" ]]             && usage "${0}"
[[ -n "${dry_run}" ]]          && DRY_RUN=1
[[ -n "${users}" ]]            && USERS=("${users[@]:#-u}")
[[ -n "${groups}" ]]           && GROUPS=("${groups[@]:#-g}")
[[ -n "${nopasswd_sudo}" ]]    && NOPASSWD_SUDO=1
[[ -n "${passwd}" ]]           && CHANGE_PASSWD=1
[[ -n "${reflector}" ]]        && REFLECTOR=1
[[ -n "${install_packages}" ]] && INSTALL_PACKAGES=1
[[ -n "${https_mirrors}" ]]    && HTTPS_MIRRORS=1

function info_msg () { echo -e "$(tput setaf 2)${1}$(tput sgr0)" }

function warn_msg () { echo -e "$(tput setaf 3)${1}$(tput sgr0)" }

function error_msg () {
  echo -e "$(tput setaf 1)${1}$(tput sgr0)" > /dev/stderr
  return "${2:-1}"
}

function ok () { info_msg "OK" | tee -a "${LOG}" }
function skip () { warn_msg "SKIP" | tee -a "${LOG}" }
function fail() { error_msg "FAIL" 1 | tee -a "${LOG}" }

function run_log_cmd () {
  [[ -n ${1} ]] || return
  echo -en "$(tput setaf 12)[$(date +'%H:%M:%S')] CMD: ${1}$(tput sgr0) " | tee -a "${LOG}"

  if [[ "${2}" != "alwaysrun" ]]; then
    if [[ "${2}" == "skip" ]] || [[ "${DRY_RUN}" == 1 ]]; then
      skip
      return
    fi
  fi
  eval "${1} &>> ${LOG} " && ok || fail
}

function _group_exists () { grep -qP "^${1}:" /etc/group }

function _create_group () {
  local -a cmd cmd
  [[ -n "${2}" ]] && cmd+=("-g ${2}")
  cmd=("groupadd ${(j. .)cmd[@]} ${1}")
  _group_exists "${1}" && cmd+=("skip")
  run_log_cmd "${cmd[@]}"
}

function create_groups () {
  [[ -n "${GROUPS}" ]] || return
  for group in "${GROUPS[@]}"; do
    _create_group "${group}"
  done
}

function _user_exists () { grep -qP "^${1}:" /etc/passwd }

function _create_user () {
  # TODO: get rid of code duplication! (super annoying, but it is late...)
  local cmd
  [[ -n "${2}" ]] && cmd+=("-u ${2}")
  cmd=("useradd -m -s $(which zsh) -G ${(j.,.)GROUPS[@]} -g ${GROUPS[1]} ${1} ${(j. .)cmd[@]}")
  _user_exists "${1}" && cmd+=("skip")
  run_log_cmd "${cmd[@]}"
}

function create_users () {
  [[ -n "${USERS}" ]] || return
  _create_user "${USERS[1]}" 666
  for user in "${USERS[@]}"; do
    [[ "${user}" != "${USERS[1]}" ]] && _create_user "${user}"
  done
}

function change_passwords () {
  [[ CHANGE_PASSWD -gt 0 ]] || return
  local users passwd
  users=("${USERS[@]}" "root")
  for user in "${users[@]}"; do
    read -s "passwd?Password for user ${user}: " passwd
    chpasswd "${user}:${passwd}"
  done
}

function update_sort_mirrors () {
  local cmd
  [[ ${REFLECTOR} -gt 0 ]] || return
  run_log_cmd "pacman -Sy --noconfirm --needed reflector"
  cmd="reflector --sort rate --save /etc/pacman.d/mirrorlist"
  [[ ${HTTPS_MIRRORS} -gt 0 ]] && cmd+=" --protocol https"
  run_log_cmd "${cmd}"
}

function install_packages () {
  [[ ${INSTALL_PACKAGES} -gt 0 ]] || return
  local packages
  packages="${(j. .)PACKAGES}"
  run_log_cmd "pacman -S --noconfirm --needed ${packages}"
}

function start_sshd () {
  run_log_cmd "systemctl start sshd"
}

function _lineinfile () {
  [[ -n "${1}" ]] || return 1
  [[ -n "${2}" ]] || return 1
  [[ -f "${2}" ]] || error_msg "File ${2} does not exist!" 1
  grep -Pq "${1}" "${2}" 2> /dev/null
}

function _is_passwd_sudo { _lineinfile "^\%wheel\s+ALL\=\(ALL\)\s+ALL" /etc/sudoers }
function _is_nopasswd_sudo { _lineinfile "^\%wheel\s+ALL\=\(ALL\)\s+NOPASSWD:\s+ALL" /etc/sudoers }

function _ask_for_confirmation () {
  read -q "?${1}"
  echo
}

function enable_sudo () {
  if ! command -v sudo &> /dev/null; then
    error_msg "Cannot enable sudo - it is not installed" 0
    _ask_for_confirmation "Correct problem by installing it now? [y/n] " && run_log_cmd "pacman -S sudo"
  fi
  local wheel_line
  wheel_line="%wheel ALL=(ALL) ALL"
  [[ ${NOPASSWD_SUDO} -gt 0 ]] && wheel_line="%wheel ALL=(ALL) NOPASSWD: ALL"
  run_log_cmd "sed -i \"s/.*%wheel.*/${wheel_line}/g\" /etc/sudoers"
  _is_passwd_sudo && info_msg "Privilege escalation enabled. Password required."
  _is_nopasswd_sudo && info_msg "Passwordless privilege escalation enabled."
}

function remove_color_escape_sequences () { sed -i 's/\x1B\[[0-9;]*[JKmsu]//g' ${1} }

function prompt_display_log () { _ask_for_confirmation 'Display log? [y/n]' && cat "${LOG}" }

function main () {
  info_msg "users: ${(j., .)USERS[@]}"
  info_msg "groups: ${(j., .)GROUPS[@]}"
  info_msg "packages: ${(j., .)PACKAGES[@]}"
  info_msg "passwordless sudo: ${NOPASSWD_SUDO}"
  create_groups
  create_users
  change_passwords
  update_sort_mirrors
  install_packages
  enable_sudo
  remove_color_escape_sequences "${LOG}"
  prompt_display_log
}

main "${@}"
# vim: set sw=2 ts=2:
