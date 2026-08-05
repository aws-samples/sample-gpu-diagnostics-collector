# GPU Diagnostics Collector for Amazon EC2

A lightweight, single-script diagnostic collection tool for NVIDIA GPU instances on Amazon EC2. It gathers GPU health data, driver state, fabric topology, kernel logs, and firmware inventory — then uploads everything to Amazon S3 for centralized triage.

## Overview

When GPU instances (p4d, p5, g5, etc.) exhibit failures such as Xid errors, NVLink faults, ECC issues, or training job hangs, rapid diagnostics collection is critical. This script automates the full collection in one pass, handles edge cases (wedged GPUs, missing tools), and produces a structured S3 artifact that support teams can immediately analyze.

## Features

- **Comprehensive GPU state capture** — nvidia-smi, nvidia-bug-report, NVLink status/errors, ECC counts, row remapper state, GPU topology
- **Kernel & driver logs** — Xid errors, NVLink messages, NVIDIA driver messages from journalctl/dmesg
- **Fabric Manager diagnostics** — service status, version, log tail (critical for NVSwitch-based instances)
- **Firmware inventory** — VBIOS, driver version, InfoROM, GSP firmware per GPU
- **Extended mode** (`--extended`) — EFA counters, NVSwitch PCIe topology, PCIe AER registers, NUMA/DIMM info, IPMI SEL, EC2 instance metadata, kernel taint flags
- **Resilient execution** — Timeouts on hung commands (300s for nvidia-bug-report), graceful fallbacks when tools are missing, individual test pass/fail tracking
- **Flexible upload** — Directory upload (default) or single `tar.gz` archive to S3
- **Summary report** — Human-readable `summary.txt` with pass/fail status for every collection step

## Prerequisites

- NVIDIA GPU instance (Amazon EC2 p4d, p5, g5, g6, etc.)
- NVIDIA driver and `nvidia-smi` installed
- AWS CLI configured with permissions to write to the target S3 bucket
- Bash 4+ (default on Amazon Linux 2/2023)
- Root or sudo access (recommended for full diagnostics)

For extended mode (`--extended`):
- `ibv_devinfo` / `ibstat` (for EFA diagnostics)
- `numactl`, `dmidecode`, `ipmitool` (for hardware inventory)

## Usage

```bash
# Basic collection with upload to S3
./gpu-diag-collect.sh -b my-diag-bucket -p triage/P123456789

# Extended diagnostics (EFA, NVSwitch, PCIe AER, NUMA, IPMI)
./gpu-diag-collect.sh -b my-diag-bucket -p triage/P123456789 --extended

# Compress to a single tar.gz before upload
./gpu-diag-collect.sh -b my-diag-bucket -p triage/P123456789 --tar

# Custom AWS region
./gpu-diag-collect.sh -b my-diag-bucket -p triage/P123456789 -r us-west-2
```

### Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `-b` | Yes | S3 bucket name |
| `-p` | No | S3 prefix (default: `gpu-diag/<hostname>/<timestamp>`) |
| `-r` | No | AWS region (default: `us-east-1`) |
| `--tar` | No | Compress output into a single `.tar.gz` before upload |
| `--extended` | No | Include optional extended collections |
| `-h`, `--help` | No | Show usage information |

## Output Structure

```
s3://<bucket>/<prefix>/
├── summary.txt                  # Pass/fail status for each collection
├── nvidia-bug-report-*.log.gz   # Full NVIDIA bug report
├── nvidia-smi.txt               # GPU status overview
├── nvidia-smi-query.txt         # Detailed GPU query output
├── nvlink-status.txt            # NVLink link status
├── nvlink-errors.txt            # NVLink error counters
├── kernel-nvidia.txt            # NVIDIA kernel messages
├── kernel-nvlink.txt            # NVLink kernel messages
├── kernel-xid.txt               # Xid error messages
├── lsmod-nvidia.txt             # Loaded NVIDIA modules
├── nvidia-modinfo.txt           # Driver module metadata
├── fabricmanager-status.txt     # Fabric Manager service state
├── fabricmanager-version.txt    # Fabric Manager version
├── fabricmanager-log-tail.txt   # Last 50MB of FM log
├── firmware-inventory.txt       # Per-GPU firmware versions
├── nvidia-topo.txt              # GPU interconnect topology
├── nvidia-ecc.txt               # ECC error details
├── row-remap-state.txt          # Row remapper state
├── os-info.txt                  # OS, kernel, uptime
└── [extended collections...]    # With --extended flag
```

## Interpreting Results

| File | What to look for |
|------|-----------------|
| `kernel-xid.txt` | Xid errors (e.g., Xid 79 = GPU fallen off bus, Xid 48 = DBE) |
| `nvlink-errors.txt` | Non-zero CRC or replay errors across links |
| `nvidia-ecc.txt` | Uncorrectable ECC errors (volatile or aggregate) |
| `row-remap-state.txt` | Pending row remaps or remapping failures |
| `fabricmanager-status.txt` | Fabric Manager not running = NVLink fabric down |
| `pcie-link.txt` | Link running below max gen/width (degraded) |

## Security

- The script does **not** collect or transmit any credentials, private keys, or application data.
- EC2 metadata collection (in `--extended` mode) retrieves only instance identity information (instance-id, instance-type, AZ) using IMDSv2.
- Ensure the target S3 bucket has appropriate access policies and encryption configured.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) for guidelines on how to contribute to this project.
