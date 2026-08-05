#!/bin/bash

set -euo pipefail

# =============================================================================
# Usage: Prints help text describing all supported flags and example invocations.
# =============================================================================
usage() {
    echo "Usage: $0 -b <s3-bucket> [-p <s3-prefix>] [-r <aws-region>] [--tar] [--extended]"
    echo ""
    echo "  -b          S3 bucket name (required)"
    echo "  -p          S3 prefix (default: gpu-diag/<hostname>/<timestamp>)"
    echo "  -r          AWS region (default: us-east-1)"
    echo "  --tar       Compress output to a single tar.gz before upload"
    echo "  --extended  Include optional collections (EFA, NVSwitch, PCIe AER,"
    echo "              NUMA/DIMM, IPMI SEL, kernel taint, etc.). Default: OFF."
    echo ""
    echo "Examples:"
    echo "  $0 -b my-diag-bucket -p triage/P123456789"
    echo "  $0 -b my-diag-bucket -p triage/P123456789 --extended"
    echo "  $0 -b my-diag-bucket -p triage/P123456789 --tar"
    exit 1
}

# =============================================================================
# Argument parsing: reads flags from the command line and sets runtime variables.
# =============================================================================
S3_BUCKET=""
S3_PREFIX=""
AWS_REGION="us-east-1"
UPLOAD_TAR=0
EXTENDED=0

while [ $# -gt 0 ]; do
  case "$1" in
    -b) S3_BUCKET="$2"; shift 2 ;;
    -p) S3_PREFIX="$2"; shift 2 ;;
    -r) AWS_REGION="$2"; shift 2 ;;
    --tar) UPLOAD_TAR=1; shift ;;
    --extended) EXTENDED=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [ -z "$S3_BUCKET" ]; then
    echo "ERROR: S3 bucket is required."
    usage
fi

# =============================================================================
# Setup: derives hostname, timestamp, output directory, and S3 target prefix.
# =============================================================================
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")

if [ -z "$S3_PREFIX" ]; then
    S3_PREFIX="gpu-diag/${HOSTNAME}/${TIMESTAMP}"
fi

OUTDIR=$(mktemp -d /tmp/gpu_diag_XXXXXX)
SUMMARY="${OUTDIR}/summary.txt"

echo "=== GPU Diagnostics Collection ===" | tee "$SUMMARY"
echo "Host: ${HOSTNAME}" | tee -a "$SUMMARY"
echo "Time: ${TIMESTAMP}" | tee -a "$SUMMARY"
echo "Output: ${OUTDIR}" | tee -a "$SUMMARY"
echo "S3 Target: s3://${S3_BUCKET}/${S3_PREFIX}/" | tee -a "$SUMMARY"
echo "Upload mode: $([ $UPLOAD_TAR -eq 1 ] && echo tar.gz || echo directory)" | tee -a "$SUMMARY"
echo "Extended mode: $([ $EXTENDED -eq 1 ] && echo ON || echo OFF)" | tee -a "$SUMMARY"
echo "===================================" | tee -a "$SUMMARY"

# =============================================================================
# run_test: helper function that executes a command, captures its output to a
# file, and logs SUCCESS or FAILED (with exit code) to the summary.
# =============================================================================
run_test() {
    local test_name="$1"
    local output_file="$2"
    shift 2
    local cmd="$*"

    echo "" | tee -a "$SUMMARY"
    echo "[${test_name}] Running: ${cmd}" | tee -a "$SUMMARY"

    set +e
    eval "$cmd" > "$output_file" 2>&1
    local rc=$?
    set -e

    if [ $rc -eq 0 ]; then
        echo "[${test_name}] SUCCESS" | tee -a "$SUMMARY"
    else
        echo "[${test_name}] FAILED (exit code: ${rc})" | tee -a "$SUMMARY"
    fi
}

# =============================================================================
# nvidia-bug-report: runs NVIDIA's official bug report tool to collect a full
# driver and GPU state snapshot. Wrapped in a 300s timeout to prevent hangs
# on wedged nodes. Checks for compressed and uncompressed output variants.
# =============================================================================
echo "" | tee -a "$SUMMARY"
echo "[nvidia-bug-report] Running: nvidia-bug-report.sh (timeout=300s)" | tee -a "$SUMMARY"
if [[ -x /usr/bin/nvidia-bug-report.sh ]]; then
    cd "$OUTDIR" || exit 1
    if timeout --kill-after=30 300 /usr/bin/nvidia-bug-report.sh 2>&1 | tee -a "$SUMMARY"; then
        rc_nbr=0
    else
        rc_nbr=$?
    fi
    if ls "$OUTDIR"/nvidia-bug-report-*.log.gz &>/dev/null; then
        echo "[nvidia-bug-report] SUCCESS — compressed log generated" | tee -a "$SUMMARY"
    elif ls "$OUTDIR"/nvidia-bug-report-*.log &>/dev/null; then
        echo "[nvidia-bug-report] SUCCESS — log generated (uncompressed)" | tee -a "$SUMMARY"
    elif [ "$rc_nbr" -eq 124 ] || [ "$rc_nbr" -eq 137 ]; then
        echo "[nvidia-bug-report] TIMED OUT after 300s (rc=$rc_nbr) — node likely wedged" | tee -a "$SUMMARY"
    else
        echo "[nvidia-bug-report] WARNING — no output file found (rc=$rc_nbr)" | tee -a "$SUMMARY"
    fi
else
    echo "[nvidia-bug-report] SKIPPED — nvidia-bug-report.sh not found" | tee -a "$SUMMARY"
fi

# =============================================================================
# nvidia-smi: collects basic GPU status and full query output including driver
# version, memory usage, power draw, temperature, and per-GPU details.
# =============================================================================
run_test "nvidia-smi" "${OUTDIR}/nvidia-smi.txt" "nvidia-smi"
run_test "nvidia-smi-query" "${OUTDIR}/nvidia-smi-query.txt" "nvidia-smi -q"

# =============================================================================
# NVLink: collects NVLink status and error counters across all GPU links.
# Used to detect fabric faults, link failures, and error accumulation.
# =============================================================================
run_test "nvlink-status" "${OUTDIR}/nvlink-status.txt" "nvidia-smi nvlink -s"
run_test "nvlink-errors" "${OUTDIR}/nvlink-errors.txt" "nvidia-smi nvlink -e"

# =============================================================================
# Kernel / driver logs: extracts NVIDIA and NVLink related kernel messages
# and Xid errors from journalctl (preferred) with dmesg as fallback.
# Xid errors indicate GPU hardware or driver faults.
# Also collects loaded NVIDIA kernel modules and driver module metadata.
# =============================================================================
run_test "kernel-nvlink" "${OUTDIR}/kernel-nvlink.txt" \
  "journalctl -k -b 2>/dev/null | grep -i nvlink || dmesg --ctime | grep -i nvlink"
run_test "kernel-nvidia" "${OUTDIR}/kernel-nvidia.txt" \
  "journalctl -k -b 2>/dev/null | grep -i nvidia || dmesg --ctime | grep -i nvidia"
run_test "kernel-xid" "${OUTDIR}/kernel-xid.txt" \
  "journalctl -k -b 2>/dev/null | grep -iE 'Xid|GPU has fallen' || dmesg --ctime | grep -iE 'Xid|GPU has fallen'"
run_test "lsmod-nvidia" "${OUTDIR}/lsmod-nvidia.txt" "lsmod | grep -i nv"
run_test "nvidia-modinfo" "${OUTDIR}/nvidia-modinfo.txt" "modinfo nvidia"

# =============================================================================
# Fabric Manager: collects the service status, version, and last 50MB of the
# Fabric Manager log. Fabric Manager manages NVSwitch and NVLink fabric
# topology on multi-GPU instances (e.g. p4d, p5).
# =============================================================================
run_test "fabricmanager-status" "${OUTDIR}/fabricmanager-status.txt" \
  "systemctl status nvidia-fabricmanager 2>/dev/null || service nvidia-fabricmanager status 2>/dev/null || echo 'fabricmanager service not found'"
run_test "fabricmanager-version" "${OUTDIR}/fabricmanager-version.txt" \
  "nv-fabricmanager --version 2>/dev/null || /usr/bin/nv-fabricmanager --version 2>/dev/null || echo 'nv-fabricmanager binary not found'"
run_test "fabricmanager-log-tail" "${OUTDIR}/fabricmanager-log-tail.txt" \
  "tail -c 50M /var/log/fabricmanager.log 2>/dev/null || echo 'no /var/log/fabricmanager.log'"

# =============================================================================
# Firmware inventory: collects per-GPU firmware versions including VBIOS,
# driver, inforom, and GSP firmware. Falls back to a query without
# gsp.firmware.version for GPU types that do not expose that field.
# =============================================================================
run_test "firmware-inventory" "${OUTDIR}/firmware-inventory.txt" \
  "nvidia-smi --format=csv --query-gpu=index,name,serial,uuid,vbios_version,driver_version,inforom.img,inforom.oem,gsp.firmware.version 2>/dev/null || nvidia-smi --format=csv --query-gpu=index,name,serial,uuid,vbios_version,driver_version,inforom.img,inforom.oem"

# =============================================================================
# Additional GPU context: collects GPU topology (NVLink/PCIe interconnect map),
# ECC error counts, row remapper state (used to detect remapped/retired rows),
# and OS/kernel/uptime information.
# =============================================================================
run_test "gpu-topology" "${OUTDIR}/nvidia-topo.txt" "nvidia-smi topo -m"
run_test "ecc-errors" "${OUTDIR}/nvidia-ecc.txt" "nvidia-smi -q -d ECC"
run_test "row-remap-state" "${OUTDIR}/row-remap-state.txt" \
  "nvidia-smi -q -d ROW_REMAPPER 2>/dev/null || nvidia-smi --query-gpu=index,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv"
run_test "os-info" "${OUTDIR}/os-info.txt" \
  "uname -a; echo '---'; cat /etc/os-release 2>/dev/null || cat /etc/system-release 2>/dev/null; echo '---'; uptime"

# =============================================================================
# Compatibility aliases: copies kernel-nvidia.txt and kernel-nvlink.txt to
# dmesg-nvidia.txt and dmesg-nvlink.txt so that any tooling or dashboards
# referencing the older filenames continue to work alongside the new names.
# =============================================================================
if [ -f "$OUTDIR/kernel-nvidia.txt" ]; then
    cp "$OUTDIR/kernel-nvidia.txt" "$OUTDIR/dmesg-nvidia.txt" 2>/dev/null || true
fi
if [ -f "$OUTDIR/kernel-nvlink.txt" ]; then
    cp "$OUTDIR/kernel-nvlink.txt" "$OUTDIR/dmesg-nvlink.txt" 2>/dev/null || true
fi

# =============================================================================
# Extended collections (--extended flag required): optional deeper diagnostics
# including EFA networking counters, NVSwitch PCIe topology, PCIe AER error
# registers, NUMA/memory DIMM info, IPMI system event log, and EC2 instance
# metadata. Disabled by default to keep standard runs fast and lightweight.
# =============================================================================
if [ "$EXTENDED" -eq 1 ]; then
  echo "" | tee -a "$SUMMARY"
  echo "=== Extended collections (--extended) ===" | tee -a "$SUMMARY"

  # NVLink capability flags per link
  run_test "nvlink-capabilities" "${OUTDIR}/nvlink-capabilities.txt" "nvidia-smi nvlink -c"

  # Kernel taint flags — indicates whether an unsupported or out-of-tree module
  # has been loaded, which can affect driver stability
  run_test "kernel-taint" "${OUTDIR}/kernel-taint.txt" \
    "cat /proc/sys/kernel/tainted; echo '---'; dmesg 2>/dev/null | grep -i taint || journalctl -k -b 2>/dev/null | grep -i taint"

  # Last 1000 lines of Fabric Manager journal for detailed fabric event history
  run_test "fabricmanager-journal" "${OUTDIR}/fabricmanager-journal.txt" \
    "journalctl -u nvidia-fabricmanager -b 2>/dev/null | tail -1000 || echo 'no journal entries'"

  # EFA (Elastic Fabric Adapter) device info, port state, and performance counters.
  # Used to diagnose EFA-related connectivity issues on HPC/GPU instances.
  run_test "efa-devices" "${OUTDIR}/efa-devices.txt" "ibv_devinfo 2>/dev/null || echo 'ibv_devinfo not installed'"
  run_test "efa-status" "${OUTDIR}/efa-status.txt" "ibstat 2>/dev/null || echo 'ibstat not installed'"
  run_test "efa-perfcounters" "${OUTDIR}/efa-perfcounters.txt" \
    "for d in /sys/class/infiniband/*/ports/*/counters/*; do echo \"\$d: \$(cat \$d 2>/dev/null)\"; done"
  run_test "efa-sysclass" "${OUTDIR}/efa-sysclass.txt" \
    "ls -la /sys/class/infiniband/ 2>/dev/null"

  # GPU peer-to-peer topology and NVSwitch PCIe device listing with fabric
  # manager topology files for multi-GPU interconnect analysis
  run_test "gpu-topology-p2p" "${OUTDIR}/nvidia-topo-p2p.txt" \
    "nvidia-smi topo -p2p rn 2>/dev/null || echo 'p2p topo not supported'"
  run_test "nvswitch-lspci" "${OUTDIR}/nvswitch-lspci.txt" \
    "lspci -d 10de: -vvv | grep -B2 -A25 'NVSwitch\|Bridge' 2>/dev/null || lspci -d 10de:"
  run_test "nvswitch-fm-topology" "${OUTDIR}/nvswitch-fm-topology.txt" \
    "ls -la /var/log/nvidia-fabricmanager/ 2>/dev/null; head -2000 /var/log/nvidia-fabricmanager/topology* 2>/dev/null || echo 'no fm topology files'"

  # PCIe AER (Advanced Error Reporting) registers — captures correctable and
  # uncorrectable PCIe bus errors per device, useful for diagnosing hardware faults
  run_test "pcie-aer" "${OUTDIR}/pcie-aer.txt" \
    "for d in /sys/bus/pci/devices/*/aer_dev_*; do [ -r \"\$d\" ] && echo \"=== \$d ===\" && cat \"\$d\" 2>/dev/null; done"

  # PCIe link width and generation per GPU — detects link degradation
  # (e.g. running at x8 instead of expected x16)
  run_test "pcie-link" "${OUTDIR}/pcie-link.txt" \
    "nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv"

  # NUMA topology and memory DIMM inventory for identifying memory configuration
  # and NUMA affinity between CPUs, GPUs, and network interfaces
  run_test "numa-topology" "${OUTDIR}/numa-topology.txt" "numactl --hardware 2>/dev/null || echo 'numactl not installed'"
  run_test "memory-dimms" "${OUTDIR}/memory-dimms.txt" "dmidecode -t memory 2>/dev/null | head -500 || echo 'dmidecode needs root/access denied'"

  # IPMI System Event Log — last 100 hardware-level events from the BMC,
  # useful for identifying power, thermal, or hardware fault events
  run_test "ipmi-sel" "${OUTDIR}/ipmi-sel.txt" \
    "ipmitool sel elist 2>/dev/null | tail -100 || echo 'ipmitool not installed or no access'"

  # EC2 instance metadata — collects instance ID, type, AZ, region, and AZ ID
  # using IMDSv2 (token-based) for secure metadata retrieval
  run_test "ec2-metadata" "${OUTDIR}/ec2-metadata.txt" \
    "TOKEN=\$(curl -sSf -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null); \
     for k in instance-id instance-type placement/availability-zone placement/region placement/availability-zone-id; do \
       echo \"\$k: \$(curl -sSf -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/\$k 2>/dev/null)\"; \
     done"
fi

echo "" | tee -a "$SUMMARY"
echo "=== Collection Complete ===" | tee -a "$SUMMARY"
echo "Files collected:" | tee -a "$SUMMARY"
ls -la "$OUTDIR" | tee -a "$SUMMARY"

# =============================================================================
# S3 upload: uploads all collected files to the specified S3 bucket and prefix.
# Supports directory upload (default) or single tar.gz upload (--tar flag).
# Parses aws CLI output for per-file "upload failed:" strings since the AWS CLI
# returns exit code 0 even when individual file uploads fail.
# =============================================================================
echo "" | tee -a "$SUMMARY"
echo "=== Uploading to S3 ===" | tee -a "$SUMMARY"

if ! command -v aws &>/dev/null; then
    echo "ERROR: aws CLI not found. Files remain in ${OUTDIR}" | tee -a "$SUMMARY"
    exit 1
fi

UPLOAD_LOG="/tmp/gpu-diag-upload-$$.log"

if [ "$UPLOAD_TAR" -eq 1 ]; then
    TAR_FILE="/tmp/gpu-diag-${HOSTNAME}-${TIMESTAMP}.tar.gz"
    tar -czf "$TAR_FILE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>&1 | tee -a "$SUMMARY"
    TAR_RC="${PIPESTATUS[0]}"
    if [ "$TAR_RC" -ne 0 ]; then
        echo "tar FAILED (rc=$TAR_RC)" | tee -a "$SUMMARY"
        exit 1
    fi
    aws s3 cp "$TAR_FILE" "s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$TAR_FILE")" \
        --region "$AWS_REGION" 2>&1 | tee "$UPLOAD_LOG" | tee -a "$SUMMARY"
    UPLOAD_RC="${PIPESTATUS[0]}"
    rm -f "$TAR_FILE"
else
    aws s3 cp "$OUTDIR" "s3://${S3_BUCKET}/${S3_PREFIX}/" \
        --recursive \
        --region "$AWS_REGION" \
        2>&1 | tee "$UPLOAD_LOG" | tee -a "$SUMMARY"
    UPLOAD_RC="${PIPESTATUS[0]}"
fi

# Detect per-file upload failures by scanning aws output for "upload failed:"
# strings. Carriage returns in the aws progress output are converted to
# newlines before grepping to ensure failure lines are matched correctly.
FAILED_COUNT=0
if [ -f "$UPLOAD_LOG" ]; then
    FAILED_COUNT=$(tr '\r' '\n' < "$UPLOAD_LOG" | grep -c "^upload failed:" 2>/dev/null || echo 0)
    FAILED_COUNT=$(echo "$FAILED_COUNT" | tr -d '[:space:]')
    [ -z "$FAILED_COUNT" ] && FAILED_COUNT=0
fi

if [ "$UPLOAD_RC" -eq 0 ] && [ "$FAILED_COUNT" -eq 0 ]; then
    echo "Upload SUCCESS: s3://${S3_BUCKET}/${S3_PREFIX}/" | tee -a "$SUMMARY"
    rm -f "$UPLOAD_LOG"
else
    echo "Upload FAILED: aws_rc=$UPLOAD_RC, files_with_upload_failed=$FAILED_COUNT" | tee -a "$SUMMARY"
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo "First 5 failed uploads:" | tee -a "$SUMMARY"
        tr '\r' '\n' < "$UPLOAD_LOG" | grep "^upload failed:" | head -5 | tee -a "$SUMMARY"
    fi
    rm -f "$UPLOAD_LOG"
    exit 1
fi

echo ""
echo "Done. Results at: s3://${S3_BUCKET}/${S3_PREFIX}/"
echo "Local copy: ${OUTDIR}"