#!/usr/bin/env python3
"""Load and validate node inventory YAML, emit normalized JSON."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any

ALLOWED_ROLES = {"control-plane", "worker", "etcd", "api-lb"}


def load_yaml_via_ruby(path: str) -> Any:
    cmd = [
        "ruby",
        "-ryaml",
        "-rjson",
        "-e",
        "obj=YAML.safe_load(File.read(ARGV[0])); puts JSON.generate(obj)",
        path,
    ]
    try:
        out = subprocess.check_output(cmd, text=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"failed to parse YAML '{path}' via ruby: {exc}") from exc
    return json.loads(out)


def validate_inventory(data: Any) -> list[dict[str, Any]]:
    nodes = data.get("nodes") if isinstance(data, dict) else data
    if not isinstance(nodes, list):
        raise ValueError("inventory must be a list or an object with a top-level 'nodes' list")

    names: set[str] = set()
    normalized: list[dict[str, Any]] = []
    cp_count = 0
    etcd_count = 0

    for idx, node in enumerate(nodes, start=1):
        if not isinstance(node, dict):
            raise ValueError(f"nodes[{idx}] must be an object")

        name = str(node.get("name", "")).strip()
        role = str(node.get("role", "")).strip()
        ip = str(node.get("ip", "")).strip()
        cpu = node.get("cpu")
        memory_mb = node.get("memory_mb")
        pool = node.get("pool")

        if not name:
            raise ValueError(f"nodes[{idx}].name is required")
        if name in names:
            raise ValueError(f"duplicate node name: {name}")
        names.add(name)

        if role not in ALLOWED_ROLES:
            raise ValueError(f"nodes[{idx}].role '{role}' is invalid")
        if not ip:
            raise ValueError(f"nodes[{idx}].ip is required")

        try:
            cpu_int = int(cpu)
            mem_int = int(memory_mb)
        except Exception as exc:  # noqa: BLE001
            raise ValueError(f"nodes[{idx}] cpu and memory_mb must be integers") from exc
        if cpu_int <= 0 or mem_int <= 0:
            raise ValueError(f"nodes[{idx}] cpu and memory_mb must be > 0")

        if role == "worker":
            if not isinstance(pool, str) or not pool.strip():
                raise ValueError(f"nodes[{idx}] worker nodes require non-empty pool")
            pool = pool.strip()
        else:
            pool = None

        if role == "control-plane":
            cp_count += 1
        if role == "etcd":
            etcd_count += 1

        normalized.append(
            {
                "name": name,
                "role": role,
                "ip": ip,
                "cpu": cpu_int,
                "memory_mb": mem_int,
                **({"pool": pool} if pool else {}),
            }
        )

    if cp_count < 1:
        raise ValueError("inventory requires at least one control-plane node")
    if etcd_count < 3:
        raise ValueError("inventory requires at least three etcd nodes")

    return normalized


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory_file")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    data = load_yaml_via_ruby(args.inventory_file)
    nodes = validate_inventory(data)
    if args.pretty:
        print(json.dumps({"nodes": nodes}, indent=2))
    else:
        print(json.dumps({"nodes": nodes}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
