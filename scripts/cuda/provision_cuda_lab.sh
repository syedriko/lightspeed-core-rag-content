#!/usr/bin/env bash
# Create the CUDA lab CloudFormation stack (x86_64 G6 + aarch64 G5g), copy
# install_cuda_rhel9_ec2.sh to both instances, run unattended CUDA install, and
# wait until both report state "done".
#
# Prerequisites:
#   - AWS CLI configured (credentials + default region, or pass --region)
#   - EC2 key pair named "${username}-keys" already exists in the target region
#   - Private key file at ~/.ssh/${username}-keys.pem (or --key-file)
#   - OpenSSH client (ssh, scp)
#
# Usage:
#   ./provision_cuda_lab.sh <username> [--region REGION] [--key-file PATH] [--stack-name NAME]
#   ./provision_cuda_lab.sh <username> --reuse-stack   # stack exists; only copy + install + wait
#   ./provision_cuda_lab.sh <username> --stack-only    # create/wait for stack; skip CUDA install
#
# Environment:
#   POLL_TIMEOUT_SEC      max wall-clock seconds to wait for both hosts (default: 7200)
#   CUDA_LAB_KEY_FILE     default SSH private key path if --key-file is omitted
#   KICKOFF_STAGGER_SEC   delay before starting the second host's install (default: 90)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CFN_TEMPLATE="${SCRIPT_DIR}/cuda_cloud_formation.yaml"
readonly INSTALL_SCRIPT="${SCRIPT_DIR}/install_cuda_rhel9_ec2.sh"
readonly DEFAULT_SSH_USER="ec2-user"

POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-7200}"
KICKOFF_STAGGER_SEC="${KICKOFF_STAGGER_SEC:-90}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=accept-new
)

usage() {
  sed -n '1,20p' "$0" | tail -n +2 | head -n 14
  echo "Usage: $0 <username> [--region REGION] [--key-file PATH] [--stack-name NAME] [--reuse-stack] [--stack-only]" >&2
  exit 1
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

stack_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey==\`${key}\`].OutputValue | [0]" \
    --output text
}

wait_ssh() {
  local label="$1" ip="$2" key="$3" user="$4"
  local deadline=$((SECONDS + 900))
  echo "Waiting for SSH on ${label} (${ip}) ..."
  while (( SECONDS < deadline )); do
    if ssh "${SSH_OPTS[@]}" -i "$key" "${user}@${ip}" "echo ok" >/dev/null 2>&1; then
      echo "SSH ready: ${label}"
      return 0
    fi
    sleep 10
  done
  die "SSH not available on ${label} (${ip}) within 15 minutes"
}

kickoff_install() {
  local label="$1" ip="$2" key="$3" user="$4"
  echo "Starting unattended CUDA install on ${label} (${ip}) ..."
  # Connection usually drops on first reboot; install continues via systemd.
  set +e
  ssh "${SSH_OPTS[@]}" -i "$key" "${user}@${ip}" \
    "chmod +x install_cuda_rhel9_ec2.sh && sudo ./install_cuda_rhel9_ec2.sh run"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "note: SSH session to ${label} ended with exit ${rc} (expected if the host rebooted)."
  fi
}

# Poll install state over SSH. During reboots the host is often unreachable — that is normal.
poll_cuda_state() {
  local ip="$1" key="$2" user="$3"
  ssh "${SSH_OPTS[@]}" -i "$key" "${user}@${ip}" \
    "tr -d '[:space:]' </var/lib/nvidia-ec2-install/state 2>/dev/null || echo missing" \
    2>/dev/null || echo unreachable
}

normalize_state_note() {
  case "$1" in
    unreachable|missing) echo "no_ssh (reboot/network)" ;;
    *) echo "$1" ;;
  esac
}

wait_both_cuda_done() {
  local ip_x86="$1" ip_arm="$2" key="$3" user="$4"
  local deadline=$((SECONDS + POLL_TIMEOUT_SEC))
  echo "Waiting for CUDA install on both hosts (wall-clock timeout ${POLL_TIMEOUT_SEC}s)."
  echo "Status lines: time | x86_64 | aarch64  (unreachable during reboot is expected)"
  local s_x86 s_arm
  while (( SECONDS < deadline )); do
    s_x86="$(poll_cuda_state "$ip_x86" "$key" "$user")"
    s_arm="$(poll_cuda_state "$ip_arm" "$key" "$user")"
    printf '%s  x86_64=%s  aarch64=%s\n' "$(date +%H:%M:%S)" \
      "$(normalize_state_note "$s_x86")" "$(normalize_state_note "$s_arm")"
    if [[ "$s_x86" == "done" && "$s_arm" == "done" ]]; then
      echo "CUDA install complete on both hosts."
      return 0
    fi
    if [[ "$s_x86" == "failed" || "$s_arm" == "failed" ]]; then
      die "install failed (state=failed). On the affected host: sudo cat /var/lib/nvidia-ec2-install/install.log; sudo journalctl -u nvidia-ec2-install-continue.service -b --no-pager; then sudo ~/install_cuda_rhel9_ec2.sh reset (or fix) and re-run this script with --reuse-stack."
    fi
    sleep 45
  done
  die "Timeout — last x86_64=${s_x86} aarch64=${s_arm}"
}

run_check() {
  local label="$1" ip="$2" key="$3" user="$4"
  local remote_script="/home/${user}/install_cuda_rhel9_ec2.sh"
  echo "Running check on ${label} ..."
  ssh "${SSH_OPTS[@]}" -i "$key" "${user}@${ip}" \
    "sudo bash ${remote_script} check" \
    || die "check failed on ${label}"
}

main() {
  local username=""
  local region=""
  local key_file=""
  local stack_name=""
  local reuse_stack=0
  local stack_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region) region="${2:-}"; shift 2 ;;
      --key-file) key_file="${2:-}"; shift 2 ;;
      --stack-name) stack_name="${2:-}"; shift 2 ;;
      --reuse-stack) reuse_stack=1; shift ;;
      --stack-only) stack_only=1; shift ;;
      -h|--help) usage ;;
      *)
        [[ -z "$username" ]] || usage
        username="$1"
        shift
        ;;
    esac
  done

  [[ -n "$username" ]] || usage
  [[ -f "$CFN_TEMPLATE" ]] || die "template not found: $CFN_TEMPLATE"
  [[ -f "$INSTALL_SCRIPT" ]] || die "install script not found: $INSTALL_SCRIPT"

  need_cmd aws
  need_cmd ssh
  need_cmd scp

  [[ -n "$region" ]] || region="$(aws configure get region 2>/dev/null || true)"
  [[ -n "$region" ]] || die "set AWS region (aws configure or --region)"

  [[ -n "$stack_name" ]] || stack_name="${username}-cuda-stack"
  if [[ -z "$key_file" ]]; then
    for cand in "${CUDA_LAB_KEY_FILE:-}" "${HOME}/.ssh/${username}-keys.pem" "${HOME}/rhelai/${username}-keys.pem"; do
      [[ -n "$cand" && -f "$cand" ]] && key_file="$cand" && break
    done
  fi
  [[ -n "$key_file" && -f "$key_file" ]] || die "SSH private key not found (set --key-file or CUDA_LAB_KEY_FILE, or place key at ~/.ssh/${username}-keys.pem or ~/rhelai/${username}-keys.pem)"

  export AWS_DEFAULT_REGION="$region"

  if [[ "$reuse_stack" -eq 0 ]]; then
    if aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
      die "stack ${stack_name} already exists — use --reuse-stack to only run install, or pick --stack-name"
    fi
    echo "Creating stack ${stack_name} in ${region} ..."
    aws cloudformation create-stack \
      --stack-name "$stack_name" \
      --template-body "file://${CFN_TEMPLATE}" \
      --parameters "ParameterKey=username,ParameterValue=${username}"

    echo "Waiting for stack create (this can take several minutes) ..."
    aws cloudformation wait stack-create-complete --stack-name "$stack_name"
    echo "Stack create complete."
  else
    aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1 \
      || die "stack not found: $stack_name"
    echo "Reusing existing stack ${stack_name}."
  fi

  local ip_x86 ip_arm
  ip_x86="$(stack_output "$stack_name" X8664PublicIp)"
  ip_arm="$(stack_output "$stack_name" Aarch64PublicIp)"
  [[ -n "$ip_x86" && "$ip_x86" != "None" ]] || die "could not read X8664PublicIp from stack outputs"
  [[ -n "$ip_arm" && "$ip_arm" != "None" ]] || die "could not read Aarch64PublicIp from stack outputs"

  echo "Public IPs: x86_64=${ip_x86}  aarch64=${ip_arm}"

  if [[ "$stack_only" -eq 1 ]]; then
    echo "Stack-only mode: skipping CUDA install."
    echo "SSH:"
    echo "  ssh -i ${key_file} ${DEFAULT_SSH_USER}@${ip_x86}"
    echo "  ssh -i ${key_file} ${DEFAULT_SSH_USER}@${ip_arm}"
    exit 0
  fi

  wait_ssh "x86_64" "$ip_x86" "$key_file" "$DEFAULT_SSH_USER"
  wait_ssh "aarch64" "$ip_arm" "$key_file" "$DEFAULT_SSH_USER"

  scp "${SSH_OPTS[@]}" -i "$key_file" "$INSTALL_SCRIPT" "${DEFAULT_SSH_USER}@${ip_x86}:~/"
  scp "${SSH_OPTS[@]}" -i "$key_file" "$INSTALL_SCRIPT" "${DEFAULT_SSH_USER}@${ip_arm}:~/"

  kickoff_install "x86_64" "$ip_x86" "$key_file" "$DEFAULT_SSH_USER" &
  local pid_x86=$!
  echo "Staggering second kickoff by ${KICKOFF_STAGGER_SEC}s to reduce simultaneous reboots ..."
  sleep "$KICKOFF_STAGGER_SEC"
  kickoff_install "aarch64" "$ip_arm" "$key_file" "$DEFAULT_SSH_USER" &
  local pid_arm=$!
  wait "$pid_x86" || true
  wait "$pid_arm" || true

  wait_both_cuda_done "$ip_x86" "$ip_arm" "$key_file" "$DEFAULT_SSH_USER"

  run_check "x86_64" "$ip_x86" "$key_file" "$DEFAULT_SSH_USER"
  run_check "aarch64" "$ip_arm" "$key_file" "$DEFAULT_SSH_USER"

  echo ""
  echo "All done. Both instances have CUDA (driver + container toolkit) installed."
  echo "  x86_64 (G6/L4):  ssh -i ${key_file} ${DEFAULT_SSH_USER}@${ip_x86}"
  echo "  aarch64 (G5g):   ssh -i ${key_file} ${DEFAULT_SSH_USER}@${ip_arm}"
}

main "$@"
