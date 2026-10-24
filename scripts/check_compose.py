#!/usr/bin/env python3
"""Check compose files against ADR 0006 and what each stack declares in Nix.

Usage: check_compose.py MANIFEST.json STACKS_DIR

MANIFEST.json is `homeserver.stacksManifest`: for each stack, its compose
file, service names, public ports and data directory. Every compose.yml or
docker-compose.yml under STACKS_DIR belongs to the stack its directory is
named after. Each problem is printed as `<file>: <rule>: <detail>`, and any
problem exits 1. The flake check `compose-check` runs this (ticket 3.2, #23);
docs/runbooks/stacks.md explains each rule.
"""

import json
import os
import sys
from pathlib import Path

import yaml

PUBLIC = {"0.0.0.0"}
IPV6_ALL = {"::", "[::]"}
SOCKETS = {"/var/run/docker.sock", "/run/docker.sock"}
HOST_BINDING = "com.docker.network.bridge.host_binding_ipv4"
# Read-only host files many game images mount for the time zone.
READ_ONLY_ALLOWED = {"/etc/localtime", "/etc/timezone"}
COMPOSE_NAMES = {"compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"}


def port_range(text):
    """'8000' or '8000-8010' as a list of ints."""
    first, _, last = str(text).partition("-")
    return list(range(int(first), int(last or first) + 1))


def parse_port(entry):
    """A `ports:` entry as (host_ip, published ports, protocol). host_ip is
    '' when the entry names no address; published is [] when Docker picks
    the host port. Raises ValueError for `${VAR}`, which the check cannot see
    through."""
    if isinstance(entry, int):
        return "", [], "tcp"
    if isinstance(entry, dict):
        if any("$" in str(v) for v in entry.values()):
            raise ValueError(entry)
        published = entry.get("published")
        return (
            str(entry.get("host_ip", "")),
            port_range(published) if published not in (None, "") else [],
            entry.get("protocol", "tcp"),
        )
    text = str(entry)
    if "$" in text:
        raise ValueError(text)
    text, _, protocol = text.partition("/")
    if text.startswith("["):
        ip, _, rest = text[1:].partition("]:")
        ip = f"[{ip}]"
        parts = rest.split(":")
    else:
        parts = text.split(":")
        ip = ":".join(parts[:-2]) if len(parts) > 2 else ""
        parts = parts[-2:]
    published = port_range(parts[0]) if len(parts) == 2 and parts[0] else []
    return ip, published, protocol or "tcp"


def volume_source(volume):
    """The host side of a `volumes:` entry as written, or None if it has none."""
    if isinstance(volume, dict):
        return volume.get("source")
    source, _, rest = str(volume).partition(":")
    return source if rest else None


def bind_source(volume):
    """The host path of a bind mount, with whether it is read-only, or None
    for a named volume."""
    if isinstance(volume, dict):
        if volume.get("type") != "bind":
            return None
        return str(volume.get("source", "")), bool(volume.get("read_only"))
    source, _, rest = str(volume).partition(":")
    if not rest or not source.startswith(("/", ".", "~")):
        return None
    return source, rest.split(":")[-1] == "ro" if ":" in rest else False


def check_file(path, name, stack):
    """The problems in one compose file, as (rule, detail)."""
    problems = []
    doc = yaml.safe_load(path.read_text()) or {}
    services = doc.get("services") or {}
    declared = {(p["port"], p["protocol"]) for p in stack["publicPorts"]}
    data_dir = stack.get("dataDir")
    public = set()

    if set(services) != set(stack["services"]):
        problems.append(
            ("services-mismatch", f"file has {sorted(services)}, stack {name} declares {sorted(stack['services'])}")
        )

    for service_name, service in services.items():
        service = service or {}
        where = f"service {service_name}"
        if service.get("network_mode") == "host":
            problems.append(("host-network", f"{where} uses network_mode: host"))
        for entry in service.get("ports") or []:
            try:
                ip, published, protocol = parse_port(entry)
            except ValueError:
                problems.append(("interpolated-port", f"{where} port {entry!r} uses a variable"))
                continue
            if ip == "":
                problems.append(("no-address", f"{where} port {entry!r} names no host address"))
            elif ip in IPV6_ALL:
                problems.append(("ipv6-public", f"{where} port {entry!r} is public over IPv6 (ADR 0006: IPv4 only)"))
            elif ip in PUBLIC and not published:
                problems.append(("undeclared-public", f"{where} port {entry!r} is public on a host port Docker picks"))
            elif ip in PUBLIC:
                for port in published:
                    public.add((port, protocol))
                    if (port, protocol) not in declared:
                        problems.append(
                            ("undeclared-public", f"{where} publishes {port}/{protocol} on {ip}, not declared by stack {name}")
                        )
        for volume in service.get("volumes") or []:
            if "$" in str(volume_source(volume) or ""):
                problems.append(("interpolated-volume", f"{where} mount {volume!r} uses a variable"))
                continue
            bind = bind_source(volume)
            if bind is None:
                continue
            source, read_only = bind
            normal = os.path.normpath(source) if source.startswith("/") else source
            if normal in SOCKETS:
                problems.append(("docker-socket", f"{where} mounts the Docker socket {source}"))
            elif not normal.startswith("/"):
                problems.append(("bind-outside-data", f"{where} mounts relative path {source}"))
            elif read_only and normal in READ_ONLY_ALLOWED:
                pass
            elif data_dir is None or (normal != data_dir and not normal.startswith(data_dir.rstrip("/") + "/")):
                problems.append(("bind-outside-data", f"{where} mounts {source}, outside data directory {data_dir}"))

    for network_name, network in (doc.get("networks") or {}).items():
        if HOST_BINDING in ((network or {}).get("driver_opts") or {}):
            problems.append(("host-binding-opt", f"network {network_name} sets {HOST_BINDING}"))

    for port, protocol in sorted(declared - public):
        problems.append(("declared-unused", f"stack {name} declares {port}/{protocol}, which no service publishes on 0.0.0.0"))

    return problems


def declared_file(manifest_path, stack):
    """The bytes of the compose file a stack declares, or None if it names
    none (the fixtures). Relative to the manifest, for the fixtures."""
    if not stack.get("composeFile"):
        return None
    path = manifest_path.parent / stack["composeFile"]
    return path.read_bytes() if path.exists() else b""


def main():
    manifest_path = Path(sys.argv[1])
    manifest = json.loads(manifest_path.read_text())
    root = Path(sys.argv[2])
    files = sorted(p for p in root.rglob("*") if p.name in COMPOSE_NAMES)
    failed = False
    # Every stack's own compose file must be one of the files checked here,
    # so a stack cannot skip the check by keeping its file elsewhere.
    for name, stack in sorted(manifest.items()):
        declared = declared_file(manifest_path, stack)
        if declared is not None and not any(
            p.parent.name == name and p.read_bytes() == declared for p in files
        ):
            print(f"{name}: unlisted-file: stack {name}'s compose file is not {root.name}/**/{name}/compose.yml")
            failed = True
    for path in files:
        name = path.parent.name
        shown = path.relative_to(root)
        if name not in manifest:
            print(f"{shown}: unlisted-file: no stack named {name} is declared")
            failed = True
            continue
        problems = check_file(path, name, manifest[name])
        for rule, detail in problems:
            print(f"{shown}: {rule}: {detail}")
        failed |= bool(problems)
        if not problems:
            print(f"{shown}: ok")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
