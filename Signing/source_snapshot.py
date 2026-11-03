#!/usr/bin/env python3
"""Immutable local build inputs for DUO device signing; excludes common secrets and build outputs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile


INPUTS = ("Package.swift", "Package.resolved", "iOSClient", "Sources", "Signing/Simulator.entitlements", "LICENSE", "NOTICE")
REQUIRED = {"Package.swift", "iOSClient/Sill.xcodeproj/project.pbxproj", "Sources/StreamProtocol/Viewport.swift",
            "Signing/Simulator.entitlements", "LICENSE", "NOTICE"}
IGNORED_DIRS = {".git", ".build", ".swiftpm", "Build", "DerivedData", "Local", "Temp", "xcuserdata", "__pycache__"}
SECRET_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".ipa", ".cer", ".der"}
MAX_FILE_BYTES = 32 * 1024 * 1024


def _entries(root):
    root = root.resolve(strict=True)
    entries = {}

    def read_file(file_path):
        relative = file_path.relative_to(root).as_posix()
        if file_path.name == ".DS_Store" or file_path.suffix.lower() in SECRET_SUFFIXES:
            return
        resolved = file_path.resolve(strict=True)
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise ValueError("Signing input points outside the source tree or is not a file.")
        if resolved.stat().st_size > MAX_FILE_BYTES:
            raise ValueError("Signing input exceeds the source snapshot size limit.")
        data = resolved.read_bytes()
        if len(data) > MAX_FILE_BYTES:
            raise ValueError("Signing input changed beyond the source snapshot size limit.")
        executable = bool(resolved.stat().st_mode & stat.S_IXUSR)
        entries[relative] = (data, executable)

    for item in INPUTS:
        file_path = root / item
        if file_path.is_file() or file_path.is_symlink():
            read_file(file_path)
        elif file_path.is_dir():
            for directory, dirs, files in os.walk(file_path, followlinks=False):
                dirs[:] = sorted(name for name in dirs if name not in IGNORED_DIRS)
                for name in dirs:
                    if (Path(directory) / name).is_symlink():
                        raise ValueError("Signing source contains a directory symlink.")
                for name in sorted(files):
                    read_file(Path(directory) / name)
        elif item in REQUIRED or item in {"iOSClient", "Sources"}:
            raise ValueError("A required signing source input is missing.")
    if not REQUIRED.issubset(entries):
        raise ValueError("A required signing source file is missing.")
    return entries


def _manifest(entries):
    return {name: {"sha256": hashlib.sha256(data).hexdigest(), "executable": executable}
            for name, (data, executable) in sorted(entries.items())}


def _identifier(manifest):
    encoded = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_snapshot(local, source_id):
    if not isinstance(source_id, str) or not re.fullmatch(r"[0-9a-f]{64}", source_id):
        raise ValueError("The installed signing source identifier is invalid.")
    directory = local / "signing-sources" / source_id
    manifest = json.loads((directory / "manifest.json").read_text())
    if not isinstance(manifest, dict) or _identifier(manifest) != source_id:
        raise ValueError("The installed signing source manifest is invalid.")
    source = directory / "source"
    if _manifest(_entries(source)) != manifest:
        raise ValueError("The installed signing source snapshot was changed or is incomplete.")
    return source


def capture_snapshot(root, local):
    """Freeze one coherent set of build inputs. All retained data is local and private."""
    first = _entries(root)
    manifest = _manifest(first)
    if _manifest(_entries(root)) != manifest:
        raise RuntimeError("Signing source changed while its snapshot was being captured.")
    source_id = _identifier(manifest)
    store = local / "signing-sources"
    store.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = store / source_id
    if directory.exists():
        return source_id, validate_snapshot(local, source_id)
    temporary = Path(tempfile.mkdtemp(prefix=".capture-", dir=store))
    try:
        source = temporary / "source"
        for name, (data, executable) in first.items():
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as output:
                output.write(data)
            os.chmod(destination, 0o755 if executable else 0o644)
        (temporary / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True) + "\n")
        try:
            os.rename(temporary, directory)
        except FileExistsError:
            # A second process can only win with the same content identifier.
            pass
        return source_id, validate_snapshot(local, source_id)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
