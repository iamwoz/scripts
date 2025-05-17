#!/usr/bin/env python3

import subprocess
import json
import re
import os
from pathlib import Path
import sys

OPENSEA_SMART = Path.home() / ".cache" / "openseachest" / "openSeaChest_SMART"

def list_zfs_pools():
    try:
        output = subprocess.check_output(["zpool", "list", "-H", "-o", "name"], text=True)
        return output.strip().splitlines()
    except subprocess.CalledProcessError:
        return []

def get_zfs_status(pool_name):
    try:
        return subprocess.check_output(["zpool", "status", "-v", "-P", pool_name], text=True)
    except subprocess.CalledProcessError:
        return ""

def get_devices_for_pool(pool_name):
    status = get_zfs_status(pool_name)
    devices = re.findall(r'(/dev/\S+)', status)
    return sorted(set(devices))

def get_device_states(pool_name):
    status = get_zfs_status(pool_name)
    states = {}
    for line in status.splitlines():
        match = re.search(r'^\s*(/dev/\S+)\s+(\w+)', line)
        if match:
            states[match.group(1)] = match.group(2)
    return states

def get_sd_dev(dev_path):
    try:
        pk = subprocess.check_output(["lsblk", "-no", "PKNAME", dev_path], text=True).strip()
        return f"/dev/{pk}" if pk else dev_path
    except:
        return dev_path

def get_sg_dev(sd_dev):
    try:
        base = os.path.basename(sd_dev)
        target = os.path.realpath(f"/sys/block/{base}/device")
        for sg in Path("/sys/class/scsi_generic").glob("sg*"):
            if os.path.realpath(sg / "device") == target:
                return f"/dev/{sg.name}"
    except:
        pass
    return "N/A"

def get_disk_info(sd_dev):
    base = os.path.basename(sd_dev)
    try:
        blk_json = subprocess.check_output(["lsblk", "-S", "-J"], text=True)
        blk_data = json.loads(blk_json)
        for dev in blk_data["blockdevices"]:
            if dev["name"] == base:
                return (
                    dev.get("vendor", "N/A"),
                    dev.get("model", "N/A"),
                    dev.get("serial", "N/A"),
                )
    except:
        pass
    return "N/A", "N/A", "N/A"

def get_year_and_written(sd_dev, sg_dev):
    year = "N/A"
    written = "N/A"
    poh = ""

    try:
        smart_info = subprocess.check_output(["smartctl", "-i", sd_dev], text=True, stderr=subprocess.DEVNULL)
        match = re.search(r'[Mm]anufacture.*?(\d{4})', smart_info)
        if match:
            year = match.group(1)
        else:
            attrs = subprocess.check_output(["smartctl", "-A", sd_dev], text=True, stderr=subprocess.DEVNULL)
            match = re.search(r'Power_On_Hours.*?(\d+)', attrs)
            if match:
                poh = match.group(1)
    except:
        pass

    if os.path.exists(sg_dev):
        try:
            output = subprocess.check_output(
                [str(OPENSEA_SMART), "-d", sg_dev, "-i"], text=True, stderr=subprocess.DEVNULL)
            match_year = re.search(r'Date Of Manufacture.*?(\d{4})', output)
            match_written = re.search(r'Total Bytes Written \(TB\):\s+([0-9.]+)', output)
            match_poh = re.search(r'Power On Hours:\s+([0-9.]+)', output)

            if match_year:
                year = match_year.group(1)
            if match_written:
                written = f"{match_written.group(1)} TB"
            if not poh and match_poh:
                poh = match_poh.group(1)
        except:
            pass

    if year == "N/A" and poh:
        try:
            current_year = int(subprocess.check_output(["date", "+%Y"], text=True).strip())
            est_year = current_year - int(float(poh)) // 8760
            year = f"{est_year} (est.)"
        except:
            pass

    return year, written

def is_smr(sd_dev):
    try:
        info = subprocess.check_output(["smartctl", "-i", sd_dev], text=True, stderr=subprocess.DEVNULL)
        return "SMR" in info
    except:
        return False

def get_device_size(dev_path):
    try:
        return subprocess.check_output(["lsblk", dev_path, "-dn", "-o", "SIZE"], text=True).strip()
    except:
        return "N/A"

def get_partuuid(dev_path):
    try:
        return subprocess.check_output(["blkid", "-s", "PARTUUID", "-o", "value", dev_path], text=True).strip()
    except:
        return "N/A"

def get_unassigned_devices(used_sd):
    unassigned = []
    for entry in Path("/dev").glob("sd?"):
        if str(entry) not in used_sd:
            unassigned.append(str(entry))
    return sorted(unassigned)

def print_header():
    print(f"{'Device':<36} {'Size':<6} {'Vendor':<10} {'Model':<24} {'Serial':<22} "
          f"{'/dev/sdX':<10} {'/dev/sgX':<10} {'STATE':<10} {'Year':<12} {'Written':<12} {'Type':<4}")
    print("-" * 172)

def print_device(dev_label, size, vendor, model, serial, sd_dev, sg_dev, state, year, written, smr):
    fmt = f"{dev_label:<36} {size:<6} {vendor:<10} {model:<24} {serial:<22} " \
          f"{sd_dev:<10} {sg_dev:<10} {state:<10} {year:<12} {written:<12} {smr:<4}"
    if smr == "YES":
        print(f"\033[31m{fmt}\033[0m")
    else:
        print(fmt)

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 zfs_info.py <pool-name> | --all")
        return

    arg = sys.argv[1]
    pools = list_zfs_pools()

    if arg == "--all":
        selected_pools = pools
    elif arg in pools:
        selected_pools = [arg]
    else:
        print(f"[ERROR] Invalid argument: '{arg}'")
        print("        Use '--all' or specify a valid ZFS pool name.")
        print("        Available pools:")
        for pool in pools:
            print("         ", pool)
        return

    seen = set()
    used_sd = set()

    for pool in selected_pools:
        print(f"\nPool: {pool}")
        print_header()
        states = get_device_states(pool)
        for dev in get_devices_for_pool(pool):
            if dev in seen:
                continue
            seen.add(dev)
            sd_dev = get_sd_dev(dev)
            sg_dev = get_sg_dev(sd_dev)
            vendor, model, serial = get_disk_info(sd_dev)
            size = get_device_size(dev)
            year, written = get_year_and_written(sd_dev, sg_dev)
            smr = "YES" if is_smr(sd_dev) else "NO"
            state = states.get(dev, "UNKNOWN")
            partuuid = get_partuuid(dev)
            print_device(partuuid, size, vendor, model, serial, sd_dev, sg_dev, state, year, written, smr)
            used_sd.add(sd_dev)

    print("\nUnassigned Devices:")
    print_header()
    for dev in get_unassigned_devices(used_sd):
        sd_dev = dev
        sg_dev = get_sg_dev(sd_dev)
        vendor, model, serial = get_disk_info(sd_dev)
        size = get_device_size(sd_dev)
        year, written = get_year_and_written(sd_dev, sg_dev)
        smr = "YES" if is_smr(sd_dev) else "NO"
        print_device(sd_dev, size, vendor, model, serial, sd_dev, sg_dev, "UNUSED", year, written, smr)

if __name__ == "__main__":
    main()
