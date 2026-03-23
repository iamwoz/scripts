#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from collections import defaultdict
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

REQUIRED_HELPERS = ["lsblk", "mount", "umount"]
OPTIONAL_HELPERS = ["blkid", "findmnt", "btrfs", "bootctl", "osinfo-query"]

LINUX_FS = {"ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs"}
SKIP_FS = {"vfat", "fat", "fat32", "exfat", "swap", "crypto_LUKS", "LVM2_member", "ntfs"}
OS_RELEASE_CANDIDATES = [
    "etc/os-release",
    "usr/lib/os-release",
    "usr/etc/os-release",
]
KNOWN_ROOT_SUBVOLS = [
    "@",
    "@root",
    "@/root",
    "@system",
    "root",
    "rootfs",
    "sysroot",
    "active",
]
SMALL_BOOT_MAX = 4 * 1024**3


@dataclass
class Disk:
    name: str
    path: str
    size: int = 0
    model: str = ""
    vendor: str = ""
    serial: str = ""
    tran: str = ""
    rota: Optional[bool] = None
    subsystems: str = ""


@dataclass
class Partition:
    path: str
    name: str
    fstype: str = ""
    size: int = 0
    label: str = ""
    partlabel: str = ""
    uuid: str = ""
    partuuid: str = ""
    mountpoints: List[str] = field(default_factory=list)
    pkname: str = ""
    type: str = ""


@dataclass
class ProbeResult:
    device: str
    disk: str
    filesystem: str
    size_gib: float
    classification: str
    distro: str = ""
    distro_id: str = ""
    version: str = ""
    variant: str = ""
    confidence: str = "low"
    confidence_score: int = 0
    source: str = ""
    notes: List[str] = field(default_factory=list)
    status: str = "ok"
    paths_checked: List[str] = field(default_factory=list)
    label: str = ""
    partlabel: str = ""


def which(name: str) -> Optional[str]:
    return shutil.which(name)


def run(cmd: List[str], check: bool = False, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
    )


def human_gib(size_bytes: int) -> float:
    return round(size_bytes / (1024**3), 1) if size_bytes else 0.0


def human_size(size_bytes: int) -> str:
    if not size_bytes:
        return "-"
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    value = float(size_bytes)
    idx = 0
    while value >= 1024.0 and idx < len(units) - 1:
        value /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(value)} {units[idx]}"
    return f"{value:.1f} {units[idx]}"


def transport_label(disk: Disk) -> str:
    tran = (disk.tran or "").strip().lower()
    if tran:
        return tran
    subs = (disk.subsystems or "").lower()
    if "nvme" in subs:
        return "nvme"
    if "usb" in subs:
        return "usb"
    if "scsi" in subs:
        return "scsi"
    return "-"


def media_type_label(disk: Disk) -> str:
    tran = transport_label(disk)
    if tran == "nvme":
        return "NVMe SSD"
    if disk.rota is True:
        return "HDD"
    if disk.rota is False:
        if tran == "usb":
            return "USB SSD"
        return "SSD"
    return "-"


def parse_os_release(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    try:
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                v = v[1:-1]
            data[k] = bytes(v, "utf-8").decode("unicode_escape", errors="ignore")
    except Exception:
        pass
    return data


def detect_confidence(classification: str, source: str, osr: Dict[str, str], notes: List[str]) -> Tuple[int, str]:
    score = 0

    if classification == "efi-system-partition":
        score = 95
    elif classification == "swap":
        score = 95
    elif classification == "boot-partition":
        score = 88
    elif classification == "container":
        score = 90
    elif classification == "other":
        score = 80
    elif classification == "unknown":
        score = 25
    elif classification == "linux-candidate":
        if source.startswith("os-release:"):
            score = 98
        elif source.startswith("ostree:"):
            score = 96
        elif source.startswith("filesystem-label"):
            score = 60
        elif source.startswith("heuristic:"):
            score = 35
        else:
            score = 45

        if osr.get("PRETTY_NAME"):
            score += 2
        elif osr.get("NAME"):
            score += 1
        if osr.get("ID"):
            score += 1
        if osr.get("VERSION_ID"):
            score += 1
    else:
        score = 40

    score -= min(12, len(notes) * 3)
    score = max(0, min(100, score))

    if score >= 85:
        return score, "high"
    if score >= 60:
        return score, "medium"
    return score, "low"


class MountManager:
    def __init__(self):
        self.base = Path(tempfile.mkdtemp(prefix="linux-distro-scan."))
        self.mounts: List[Path] = []

    def cleanup(self) -> None:
        for mnt in reversed(self.mounts):
            run(["umount", str(mnt)], capture=True)
            try:
                mnt.rmdir()
            except Exception:
                pass
        try:
            self.base.rmdir()
        except Exception:
            pass

    def mount(self, part: Partition, extra_opts: Optional[List[str]] = None, fstype: Optional[str] = None) -> Tuple[Optional[Path], Optional[str]]:
        mountpoint = self.base / f"{part.name}.{len(self.mounts)}"
        mountpoint.mkdir(parents=True, exist_ok=True)

        opts = ["ro"]
        fs = fstype or part.fstype
        if fs in {"ext2", "ext3", "ext4"}:
            opts.append("noload")
        elif fs == "xfs":
            opts.append("norecovery")
        if extra_opts:
            opts.extend(extra_opts)

        cmd = ["mount"]
        if fs:
            cmd += ["-t", fs]
        cmd += ["-o", ",".join(opts), part.path, str(mountpoint)]
        cp = run(cmd, capture=True)
        if cp.returncode != 0:
            try:
                mountpoint.rmdir()
            except Exception:
                pass
            return None, (cp.stderr or cp.stdout or "mount failed").strip()

        self.mounts.append(mountpoint)
        return mountpoint, None


def helper_status() -> Tuple[List[str], List[str]]:
    missing_required = [h for h in REQUIRED_HELPERS if which(h) is None]
    missing_optional = [h for h in OPTIONAL_HELPERS if which(h) is None]
    return missing_required, missing_optional


def installation_guidance(missing: List[str]) -> str:
    pkg_map = {
        "lsblk": "util-linux",
        "blkid": "util-linux",
        "mount": "util-linux",
        "umount": "util-linux",
        "findmnt": "util-linux",
        "btrfs": "btrfs-progs",
        "bootctl": "systemd",
        "osinfo-query": "libosinfo / osinfo-db-tools",
    }
    return "\n".join(f"- Missing '{item}' (usually provided by package: {pkg_map.get(item, 'unknown')})" for item in missing)


def get_disks_and_partitions() -> Tuple[Dict[str, Disk], List[Partition]]:
    cp = run([
        "lsblk", "-J", "-b",
        "-o", "NAME,PATH,TYPE,PKNAME,FSTYPE,SIZE,LABEL,PARTLABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL,VENDOR,SERIAL,TRAN,ROTA,SUBSYSTEMS"
    ])
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or "lsblk failed")

    data = json.loads(cp.stdout)
    disks: Dict[str, Disk] = {}
    partitions: List[Partition] = []

    def walk(nodes: List[Dict[str, object]], parent_disk: Optional[Disk] = None) -> None:
        for n in nodes:
            ntype = str(n.get("type") or "")
            if ntype == "disk":
                disk = Disk(
                    name=str(n.get("name") or ""),
                    path=str(n.get("path") or ""),
                    size=int(n.get("size") or 0),
                    model=str(n.get("model") or "").strip(),
                    vendor=str(n.get("vendor") or "").strip(),
                    serial=str(n.get("serial") or "").strip(),
                    tran=str(n.get("tran") or "").strip(),
                    rota=(None if n.get("rota") is None else bool(int(n.get("rota")))),
                    subsystems=str(n.get("subsystems") or "").strip(),
                )
                disks[disk.name] = disk
                children = n.get("children") or []
                if children:
                    walk(children, disk)
            elif ntype == "part":
                partitions.append(Partition(
                    path=str(n.get("path") or ""),
                    name=str(n.get("name") or ""),
                    fstype=str(n.get("fstype") or ""),
                    size=int(n.get("size") or 0),
                    label=str(n.get("label") or ""),
                    partlabel=str(n.get("partlabel") or ""),
                    uuid=str(n.get("uuid") or ""),
                    partuuid=str(n.get("partuuid") or ""),
                    mountpoints=[x for x in (n.get("mountpoints") or []) if x],
                    pkname=str(n.get("pkname") or (parent_disk.name if parent_disk else "")),
                    type=ntype,
                ))
                children = n.get("children") or []
                if children:
                    walk(children, parent_disk)
            else:
                children = n.get("children") or []
                if children:
                    walk(children, parent_disk)

    walk(data.get("blockdevices", []))
    return disks, partitions


def classify_partition(part: Partition) -> Tuple[str, List[str]]:
    notes: List[str] = []
    label_text = f"{part.label} {part.partlabel}".lower()
    mount_text = " ".join(part.mountpoints).lower()

    if part.fstype in {"vfat", "fat", "fat32"} and ("efi" in label_text or "esp" in label_text or "/boot/efi" in mount_text):
        return "efi-system-partition", notes
    if part.fstype == "swap":
        return "swap", notes
    if part.fstype in {"crypto_LUKS", "LVM2_member"}:
        return "container", notes
    if part.fstype in {"ext2", "ext3", "ext4"} and part.size and part.size <= SMALL_BOOT_MAX and ("boot" in label_text or "/boot" in mount_text):
        return "boot-partition", notes
    if part.fstype in SKIP_FS:
        return "other", notes
    if part.fstype in LINUX_FS:
        if part.size and part.size <= SMALL_BOOT_MAX and "boot" not in label_text and not part.label and not part.partlabel:
            notes.append("Small Linux filesystem; may be /boot rather than a root filesystem.")
        return "linux-candidate", notes
    return "unknown", notes


def parse_btrfs_subvols(part: Partition, manager: MountManager) -> List[str]:
    top, _ = manager.mount(part, extra_opts=["subvolid=5"], fstype="btrfs")
    if top is None:
        return []
    subvols: List[str] = []
    if which("btrfs"):
        cp = run(["btrfs", "subvolume", "list", "-o", str(top)])
        if cp.returncode == 0:
            for line in cp.stdout.splitlines():
                m = re.search(r" path (.+)$", line)
                if m:
                    subvols.append(m.group(1).strip())
    for guess in KNOWN_ROOT_SUBVOLS:
        if guess not in subvols:
            subvols.append(guess)
    return subvols


def find_os_release_paths(root: Path) -> List[Tuple[str, Path]]:
    found: List[Tuple[str, Path]] = []
    for rel in OS_RELEASE_CANDIDATES:
        p = root / rel
        if p.is_file():
            found.append((f"os-release:{rel}", p))

    ostree_base = root / "ostree" / "deploy"
    if ostree_base.is_dir():
        for stateroot in sorted(ostree_base.iterdir()):
            deploydir = stateroot / "deploy"
            if not deploydir.is_dir():
                continue
            for deploy in sorted(deploydir.iterdir()):
                if not deploy.is_dir():
                    continue
                for rel in OS_RELEASE_CANDIDATES:
                    p = deploy / rel
                    if p.is_file():
                        found.append((f"ostree:{stateroot.name}/{deploy.name}:{rel}", p))
    return found


def heuristic_from_metadata(part: Partition) -> Optional[Dict[str, str]]:
    text = " ".join(x for x in [part.label, part.partlabel] if x).strip()
    if not text:
        return None
    return {
        "PRETTY_NAME": text,
        "NAME": text,
        "ID": re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-"),
    }


def build_display_name(osr: Dict[str, str]) -> str:
    pretty = osr.get("PRETTY_NAME") or osr.get("NAME", "")
    version = osr.get("VERSION_ID", "")
    if pretty and version and version not in pretty:
        return f"{pretty} {version}"
    return pretty


def probe_candidate(part: Partition, manager: MountManager) -> ProbeResult:
    classification, notes = classify_partition(part)
    result = ProbeResult(
        device=part.path,
        disk=f"/dev/{part.pkname}" if part.pkname else "",
        filesystem=part.fstype or "unknown",
        size_gib=human_gib(part.size),
        classification=classification,
        notes=list(notes),
        label=part.label,
        partlabel=part.partlabel,
    )

    if classification != "linux-candidate":
        result.status = "skipped"
        result.source = "classification"
        score, level = detect_confidence(result.classification, result.source, {}, result.notes)
        result.confidence_score = score
        result.confidence = level
        return result

    if part.fstype == "btrfs":
        subvols = parse_btrfs_subvols(part, manager)
        if not subvols:
            result.notes.append("Could not list or infer Btrfs subvolumes from the top-level mount.")
        checked = set()
        for subvol in subvols:
            if subvol in checked:
                continue
            checked.add(subvol)
            mnt, _ = manager.mount(part, extra_opts=[f"subvol=/{subvol}"], fstype="btrfs")
            if mnt is None:
                continue
            result.paths_checked.append(f"subvol=/{subvol}")
            for source, path in find_os_release_paths(mnt):
                osr = parse_os_release(path)
                if osr.get("PRETTY_NAME") or osr.get("NAME"):
                    result.distro = build_display_name(osr)
                    result.distro_id = osr.get("ID", "")
                    result.version = osr.get("VERSION_ID", "")
                    result.variant = osr.get("VARIANT", "") or osr.get("VARIANT_ID", "")
                    result.source = f"{source} via subvol=/{subvol}"
                    score, level = detect_confidence(result.classification, source, osr, result.notes)
                    result.confidence_score = score
                    result.confidence = level
                    return result

        mnt, _ = manager.mount(part, extra_opts=["subvolid=5"], fstype="btrfs")
        if mnt is not None:
            result.paths_checked.append("subvolid=5")
            for source, path in find_os_release_paths(mnt):
                osr = parse_os_release(path)
                if osr.get("PRETTY_NAME") or osr.get("NAME"):
                    result.distro = build_display_name(osr)
                    result.distro_id = osr.get("ID", "")
                    result.version = osr.get("VERSION_ID", "")
                    result.variant = osr.get("VARIANT", "") or osr.get("VARIANT_ID", "")
                    result.source = f"{source} via subvolid=5"
                    score, level = detect_confidence(result.classification, source, osr, result.notes)
                    result.confidence_score = score
                    result.confidence = level
                    return result
    else:
        mnt, err = manager.mount(part, fstype=part.fstype)
        if mnt is None:
            result.status = "warning"
            result.notes.append(f"Mount failed: {err}")
        else:
            result.paths_checked.append("mounted-root")
            for source, path in find_os_release_paths(mnt):
                osr = parse_os_release(path)
                if osr.get("PRETTY_NAME") or osr.get("NAME"):
                    result.distro = build_display_name(osr)
                    result.distro_id = osr.get("ID", "")
                    result.version = osr.get("VERSION_ID", "")
                    result.variant = osr.get("VARIANT", "") or osr.get("VARIANT_ID", "")
                    result.source = source
                    score, level = detect_confidence(result.classification, source, osr, result.notes)
                    result.confidence_score = score
                    result.confidence = level
                    return result

    guess = heuristic_from_metadata(part)
    if guess:
        result.distro = build_display_name(guess)
        result.distro_id = guess.get("ID", "")
        result.source = "filesystem-label"
        result.notes.append("Derived from filesystem label/partition label rather than os-release.")
        score, level = detect_confidence(result.classification, result.source, guess, result.notes)
        result.confidence_score = score
        result.confidence = level
        return result

    result.status = "warning"
    result.source = "heuristic:none"
    result.notes.append("No os-release data found; unable to identify distro with confidence.")
    score, level = detect_confidence(result.classification, result.source, {}, result.notes)
    result.confidence_score = score
    result.confidence = level
    return result


def maybe_osinfo_hint(distro_id: str) -> Optional[str]:
    if not distro_id or which("osinfo-query") is None:
        return None
    cp = run(["osinfo-query", "os", f"short-id={distro_id}"])
    if cp.returncode == 0 and distro_id in cp.stdout:
        return f"Matched osinfo-db entry for '{distro_id}'."
    return None


def format_table(headers: List[str], rows: List[List[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, value in enumerate(row):
            widths[i] = max(widths[i], len(value))
    sep = "  "
    lines = [
        sep.join(headers[i].ljust(widths[i]) for i in range(len(headers))),
        sep.join("-" * widths[i] for i in range(len(headers))),
    ]
    for row in rows:
        lines.append(sep.join(row[i].ljust(widths[i]) for i in range(len(headers))))
    return "\n".join(lines)


def render_grouped_summary(disks: Dict[str, Disk], results: List[ProbeResult]) -> str:
    grouped: Dict[str, List[ProbeResult]] = defaultdict(list)
    for r in results:
        grouped[r.disk].append(r)

    lines: List[str] = []
    for disk_path in sorted(grouped.keys()):
        disk = None
        base = disk_path.replace("/dev/", "", 1) if disk_path.startswith("/dev/") else disk_path
        if base in disks:
            disk = disks[base]

        if disk:
            vendor_model = " ".join(x for x in [disk.vendor, disk.model] if x).strip() or "-"
            lines.append(f"{disk.path}  [{media_type_label(disk)} | {transport_label(disk)} | {human_size(disk.size)} | {vendor_model}]")
            if disk.serial:
                lines.append(f"  Serial: {disk.serial}")
        else:
            lines.append(f"{disk_path or '-'}")

        headers = ["Partition", "FS", "GiB", "Classification", "Linux type", "Confidence"]
        rows: List[List[str]] = []
        for r in sorted(grouped[disk_path], key=lambda x: x.device):
            rows.append([
                r.device,
                r.filesystem,
                f"{r.size_gib:.1f}",
                r.classification,
                r.distro or "-",
                f"{r.confidence} ({r.confidence_score})",
            ])
        table = format_table(headers, rows)
        lines.extend("  " + line for line in table.splitlines())
        lines.append("")
    return "\n".join(lines).rstrip()


def render_extended(disks: Dict[str, Disk], results: List[ProbeResult]) -> str:
    blocks = []
    for r in sorted(results, key=lambda x: (x.disk, x.device)):
        disk = None
        base = r.disk.replace("/dev/", "", 1) if r.disk.startswith("/dev/") else r.disk
        if base in disks:
            disk = disks[base]

        lines = [
            f"Device:        {r.device}",
            f"Disk:          {r.disk or '-'}",
            f"Filesystem:    {r.filesystem}",
            f"Size:          {r.size_gib:.1f} GiB",
            f"Class:         {r.classification}",
            f"Linux type:    {r.distro or '-'}",
            f"Distro ID:     {r.distro_id or '-'}",
            f"Version:       {r.version or '-'}",
            f"Variant:       {r.variant or '-'}",
            f"Confidence:    {r.confidence} ({r.confidence_score})",
            f"Source:        {r.source or '-'}",
            f"Status:        {r.status}",
        ]
        if disk:
            lines.extend([
                f"Drive model:   {' '.join(x for x in [disk.vendor, disk.model] if x).strip() or '-'}",
                f"Drive type:    {media_type_label(disk)}",
                f"Transport:     {transport_label(disk)}",
                f"Drive size:    {human_size(disk.size)}",
            ])
            if disk.serial:
                lines.append(f"Drive serial:  {disk.serial}")
        if r.label or r.partlabel:
            lines.append(f"Labels:        label={r.label or '-'} partlabel={r.partlabel or '-'}")
        if r.notes:
            lines.append("Notes:")
            lines.extend(f"  - {n}" for n in r.notes)
        if r.paths_checked:
            lines.append("Paths checked:")
            lines.extend(f"  - {p}" for p in r.paths_checked)
        hint = maybe_osinfo_hint(r.distro_id)
        if hint:
            lines.append(f"osinfo-db:     {hint}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inventory Linux installations across local disks with confidence scoring.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """
            Examples:
              sudo python3 scan.py
              sudo python3 scan.py --extended
              sudo python3 scan.py --debug
              sudo python3 scan.py --json
            """
        ),
    )
    parser.add_argument("--extended", action="store_true", help="Show detailed per-partition output.")
    parser.add_argument("--debug", action="store_true", help="Include extra diagnostics for improving the script over time.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("Run this script as root, for example: sudo python3 scan.py", file=sys.stderr)
        return 1

    missing_required, missing_optional = helper_status()
    if missing_required:
        print("Required external commands are missing:\n" + installation_guidance(missing_required), file=sys.stderr)
        print("\nInstall the missing packages and re-run the script.", file=sys.stderr)
        return 2

    try:
        disks, partitions = get_disks_and_partitions()
    except Exception as exc:
        print(f"Failed to enumerate disks/partitions: {exc}", file=sys.stderr)
        return 3

    manager = MountManager()
    try:
        results = [probe_candidate(part, manager) for part in partitions]
    finally:
        manager.cleanup()

    if args.debug:
        print("Debug: helper availability")
        print("  Required present: " + ", ".join(h for h in REQUIRED_HELPERS if which(h)))
        print("  Optional present: " + ", ".join(h for h in OPTIONAL_HELPERS if which(h)))
        if missing_optional:
            print("  Optional missing:")
            print(installation_guidance(missing_optional))
        print()

    if args.json:
        payload = {
            "disks": {k: asdict(v) for k, v in disks.items()},
            "results": [asdict(r) for r in results],
        }
        print(json.dumps(payload, indent=2))
        return 0

    print(render_grouped_summary(disks, results))

    if args.extended or args.debug:
        print("\nDetailed results\n")
        print(render_extended(disks, results))

    print("\nInterpretation notes:")
    print("- Confidence reflects how trustworthy the displayed result is for that row.")
    print("- For EFI, swap, boot, and container partitions, it reflects partition-type certainty.")
    print("- For Linux root candidates, it reflects distro-identification certainty.")
    print("- This script does not unlock encrypted volumes or activate LVM volume groups automatically.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
