#!/usr/bin/env python3
"""Verify literal vega-cli D-Bus calls against the canonical XML methods."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CALL = re.compile(r"vega::dbus::(?:call|call_data)\s+([A-Z][A-Za-z0-9]+)\s+([A-Z][A-Za-z0-9]+)")
LOCALIZED = {
    ("Hardware", "Inventory"): "InventoryLocalized",
    ("Hardware", "FirmwareStatus"): "FirmwareStatusLocalized",
    ("Services", "ListServices"): "ListServicesLocalized",
    ("Services", "ListAllServices"): "ListAllServicesLocalized",
    ("Snapshots", "DiffPackages"): "DiffPackagesLocalized",
}


def methods(xml_dir: Path, interface: str) -> set[str]:
    path = xml_dir / f"org.lyraos.Vega1.{interface}.xml"
    if not path.is_file():
        raise RuntimeError(f"missing canonical interface: {path}")
    return {node.attrib["name"] for node in ET.parse(path).iter("method")}


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <canonical-dbus-directory>", file=sys.stderr)
        return 2
    xml_dir = Path(sys.argv[1])
    calls: set[tuple[str, str]] = set()
    for path in sorted((ROOT / "lib").glob("*.sh")):
        calls.update(CALL.findall(path.read_text(encoding="utf-8")))
    errors = []
    for interface, method in sorted(calls):
        wire_method = LOCALIZED.get((interface, method), method)
        if wire_method not in methods(xml_dir, interface):
            errors.append(f"{interface}.{method} -> missing {wire_method}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"validated {len(calls)} literal vega-cli calls against canonical D-Bus XML")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
