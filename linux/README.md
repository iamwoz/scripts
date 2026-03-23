# Linux Distro Inventory

`linux-distro-inventory.py` scans local disks and partitions, identifies likely Linux installations, and reports what it finds in a clean grouped-by-drive summary.

## What it does

- Groups results by physical drive
- Shows basic drive metadata such as model, transport, media type, and size
- Classifies partitions such as EFI system partitions, boot partitions, swap, containers, and Linux root candidates
- Identifies Linux distributions primarily from each installed system's `os-release` data
- Handles Btrfs layouts by probing common subvolumes and the top-level subvolume
- Checks for ostree-style deployments under `ostree/deploy/...`
- Reports a single confidence score for each row
- Supports extended detail, debug output, and JSON output

## Requirements

### Python

- Python 3
- Standard library only; no Python packages are required

### External commands

Required:

- `lsblk`
- `mount`
- `umount`

Optional but helpful:

- `blkid`
- `findmnt`
- `btrfs`
- `bootctl`
- `osinfo-query`

The script will tell you if required helpers are missing and which package usually provides them.

## Usage

Run as root:

```bash
sudo python3 linux/linux-distro-inventory.py
```

Extended details:

```bash
sudo python3 linux/linux-distro-inventory.py --extended
```

Debug mode:

```bash
sudo python3 linux/linux-distro-inventory.py --debug
```

JSON output:

```bash
sudo python3 linux/linux-distro-inventory.py --json
```

## Output overview

The default output is grouped by drive and includes:

- drive path
- drive type and transport
- drive size and model
- partition path
- filesystem
- size
- classification
- Linux type
- confidence

Confidence reflects how trustworthy the displayed result is for that row:

- for EFI, swap, boot, and container partitions, it reflects partition-type certainty
- for Linux root candidates, it reflects distro-identification certainty

## Notes and limitations

- The script does not unlock encrypted volumes
- The script does not activate LVM volume groups automatically
- Some unusual layouts may only be identified heuristically
- Filesystem labels can be used as a fallback when `os-release` cannot be found

## Typical use cases

- Inventory all Linux installations on a system with multiple drives
- Check which distro is installed on an old disk before reusing it
- Confirm whether Btrfs-based installs are Bluefin, CachyOS, KDE Linux, or similar
- Produce machine-readable JSON for later processing
