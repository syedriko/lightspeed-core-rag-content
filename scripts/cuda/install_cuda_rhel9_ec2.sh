#!/usr/bin/env bash
# Install NVIDIA driver (DKMS) + nvidia-container-toolkit on RHEL 9 EC2 (x86_64 or aarch64).
#
# Unattended (survives reboots):
#   sudo ./install_cuda_rhel9_ec2.sh run
#   # SSH will drop twice while the instance reboots; no need to reconnect to continue.
#   # When finished: state file is "done" and the resume service is disabled.
#   ./install_cuda_rhel9_ec2.sh check
#
# Manual phases (optional):
#   ./install_cuda_rhel9_ec2.sh phase-a|phase-b|phase-c
#
# Tear down automation (e.g. to re-run from scratch):
#   sudo ./install_cuda_rhel9_ec2.sh reset
#
# Requires: root for run/daemon/reset; curl; working RHEL subscriptions.
#
# To provision the matching two-node CloudFormation lab and run this on both hosts: provision_cuda_lab.sh (same directory as this file).

set -euo pipefail

readonly THIS_SCRIPT="${BASH_SOURCE[0]:-$0}"
readonly INSTALL_BIN="/usr/local/sbin/install_cuda_rhel9_ec2.sh"
readonly STATE_DIR="/var/lib/nvidia-ec2-install"
readonly STATE_FILE="${STATE_DIR}/state"
readonly INSTALL_LOG="${STATE_DIR}/install.log"
readonly UNIT_PATH="/etc/systemd/system/nvidia-ec2-install-continue.service"

readonly NVIDIA_TESLA_VERSION="575.57.08"
readonly NVIDIA_CONTAINER_TOOLKIT_VERSION="1.19.0-1"

SUDO=""
[[ $EUID -eq 0 ]] || SUDO="sudo"

usage() {
  echo "Usage: $0 {run|daemon-continue|reset|phase-a|phase-b|phase-c|check}" >&2
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$THIS_SCRIPT" "$@"
  fi
}

install_self_and_unit() {
  mkdir -p "$(dirname "$INSTALL_BIN")"
  cp -f "$THIS_SCRIPT" "$INSTALL_BIN"
  chmod 755 "$INSTALL_BIN"

  cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Resume NVIDIA driver + container toolkit install after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} daemon-continue
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nvidia-ec2-install-continue.service
}

read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    tr -d '[:space:]' <"$STATE_FILE"
  else
    echo "new"
  fi
}

write_state() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >"$STATE_FILE"
}

log_install() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -Is)" "$*" >>"$INSTALL_LOG" 2>/dev/null || true
}

# On any failed command during advance_install, record failure so polling clients
# do not spin forever on e.g. post_phase_a after dnf/rpm errors.
on_install_err() {
  local ec=$?
  trap - ERR
  local prev
  prev="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
  log_install "ERR exit=${ec} previous_state=${prev} line=${BASH_LINENO[0]}"
  write_state "failed" 2>/dev/null || true
  systemctl disable nvidia-ec2-install-continue.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  exit "$ec"
}

phase_a() {
  $SUDO dnf update -y
}

phase_b() {
  $SUDO dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  $SUDO dnf install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" dkms

  local arch rpm url
  arch="$(uname -m)"
  rpm="nvidia-driver-local-repo-rhel9-${NVIDIA_TESLA_VERSION}-1.0-1.${arch}.rpm"
  url="https://us.download.nvidia.com/tesla/${NVIDIA_TESLA_VERSION}/${rpm}"

  curl -fL -o "${rpm}" "${url}"
  $SUDO rpm -i "${rpm}"
  $SUDO dnf clean all
  $SUDO dnf -y module install nvidia-driver:latest-dkms
}

phase_c() {
  if ! command -v dnf >/dev/null 2>&1; then
    echo "dnf not found" >&2
    exit 1
  fi
  $SUDO dnf install -y dnf-plugins-core podman

  $SUDO curl -sSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo
  $SUDO dnf config-manager --enable nvidia-container-toolkit-experimental

  local v="${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
  $SUDO dnf install -y \
    "nvidia-container-toolkit-${v}" \
    "nvidia-container-toolkit-base-${v}" \
    "libnvidia-container-tools-${v}" \
    "libnvidia-container1-${v}"

  $SUDO mkdir -p /etc/cdi
  $SUDO nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
}

check() {
  nvidia-ctk cdi list
  podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable \
    nvcr.io/nvidia/cuda:12.9.1-devel-ubi9 nvidia-smi
}

advance_install() {
  trap on_install_err ERR
  local state
  state="$(read_state)"
  log_install "advance_install state=${state}"

  case "$state" in
    done)
      trap - ERR
      exit 0
      ;;
    failed)
      trap - ERR
      systemctl disable nvidia-ec2-install-continue.service 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || true
      log_install "refusing to continue (state=failed); fix host or run: $0 reset"
      echo "Install failed earlier — see ${INSTALL_LOG} and journalctl -u nvidia-ec2-install-continue.service -b" >&2
      exit 1
      ;;
    new)
      phase_a
      write_state post_phase_a
      trap - ERR
      reboot
      ;;
    post_phase_a)
      phase_b
      write_state post_phase_b
      trap - ERR
      reboot
      ;;
    post_phase_b)
      phase_c
      write_state done
      systemctl disable nvidia-ec2-install-continue.service || true
      systemctl daemon-reload
      trap - ERR
      log_install "install finished OK"
      echo "Install finished. Run: $INSTALL_BIN check   (as a user with podman access if needed)"
      ;;
    *)
      trap - ERR
      echo "Unknown state '$state' in $STATE_FILE — fix or run: $0 reset" >&2
      exit 1
      ;;
  esac
}

run_unattended() {
  require_root run

  local state
  state="$(read_state)"
  if [[ "$state" == "done" ]]; then
    echo "Already complete (state=done). Use '$0 check' or '$0 reset' then '$0 run'."
    exit 0
  fi

  install_self_and_unit
  # Ensure subsequent boots (and this process after re-exec) use the installed copy.
  exec bash "$INSTALL_BIN" _run-inner
}

_run_inner() {
  require_root _run-inner
  advance_install
}

daemon_continue() {
  require_root daemon-continue
  advance_install
}

reset_all() {
  require_root reset
  systemctl disable nvidia-ec2-install-continue.service 2>/dev/null || true
  rm -f "$UNIT_PATH"
  rm -rf "$STATE_DIR"
  systemctl daemon-reload
  echo "Reset complete. Run: sudo $THIS_SCRIPT run"
}

cmd="${1:-}"
case "${cmd}" in
  run) run_unattended ;;
  _run-inner) _run_inner ;;
  daemon-continue) daemon_continue ;;
  reset) reset_all ;;
  phase-a) phase_a ;;
  phase-b) phase_b ;;
  phase-c) phase_c ;;
  check) check ;;
  *) usage ;;
esac
