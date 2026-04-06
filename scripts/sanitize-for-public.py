#!/usr/bin/env python3
"""
Sanitize the private proxmox-k8s repo for public release.

Creates a clean copy with:
- Personal info anonymized (username, GitHub handle, IPs, paths, location)
- Sensitive files excluded (secrets, kubeconfig, .tmp/)
- 'stash' service removed entirely
- 'torrent/downloader' renamed to 'downloader' everywhere
- Fresh directory ready for `git init`

Usage:
    python3 scripts/sanitize-for-public.py [--output ../proxmox-k8s-public]
    python3 scripts/sanitize-for-public.py --dry-run
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────

DEFAULT_OUTPUT = "../proxmox-k8s-public"

# Directories and files to exclude from copy (relative to repo root)
EXCLUDE_DIRS = {
    ".git",
    ".tmp",
    ".venv",
    "__pycache__",
    "helm/charts/stash",  # remove stash entirely
}

EXCLUDE_FILES = {
    "values-secret.yaml",
    ".env",
    ".DS_Store",
    "Thumbs.db",
}

EXCLUDE_SUFFIXES = {
    ".pem",
    ".key",
    ".pyc",
    ".swp",
    ".swo",
    ".tgz",
    ".tfstate",
    ".tfvars",
}

# Files to delete after copy (glob patterns relative to output root)
DELETE_AFTER_COPY = [
    "argocd/applications/stash.yaml.disabled",
]

# Directory renames: (old_relative_path, new_relative_path)
DIR_RENAMES = [
    ("helm/charts/vpn-downloader", "helm/charts/vpn-downloader"),
]

# File renames: (old_relative_path, new_relative_path)
FILE_RENAMES = [
    ("argocd/applications/vpn-downloader.yaml", "argocd/applications/vpn-downloader.yaml"),
]

# ── Text Replacements ────────────────────────────────────────────────────────
# Applied in order. More specific patterns first to avoid partial matches.

TEXT_REPLACEMENTS = [
    # ── GitHub identity (must come before generic 'user' replacement) ──
    ("youruser", "youruser"),

    # ── Personal username ──
    ("user", "user"),

    # ── Torrent/Downloader → Downloader ──
    # README title
    ("VPN Downloader (Gluetun VPN sidecar)", "VPN Downloader (Gluetun VPN sidecar)"),
    ("Download client with Gluetun VPN sidecar (WireGuard/Surfshark)", "Download client with Gluetun VPN sidecar (WireGuard/Surfshark)"),
    # Service/chart naming
    ("vpn-downloader", "vpn-downloader"),
    # Protect docker image BEFORE any downloader replacements
    ("linuxserver/qbittorrent", "linuxserver/qbittorrent"),
    # PVC and resource names
    ("downloader-config-nfs", "downloader-config-nfs"),
    ("downloader-config", "downloader-config"),
    ("downloader-ingress", "downloader-ingress"),
    # Container/app references
    ("downloader.homelab.local", "downloader.homelab.local"),
    ("downloader.default.svc.cluster.local", "downloader.default.svc.cluster.local"),
    # Service name in K8s
    ("name: downloader", "name: downloader"),
    ("name: Downloader", "name: Downloader"),
    # Port names
    ("name: dl-http", "name: dl-http"),
    ("name: download-tcp", "name: download-tcp"),
    ("name: download-udp", "name: download-udp"),
    # Descriptions
    ("Download Client (VPN)", "Download Client (VPN)"),
    ("Download Client", "Download Client"),
    ("Download client", "Download client"),
    ("download client", "download client"),
    # Container image (keep linuxserver/qbittorrent as it's the real image)
    # but rename the container name in deployment
    ("- name: downloader", "- name: downloader"),
    # Values YAML key
    ("downloader:", "downloader:"),
    (".Values.downloader.", ".Values.downloader."),
    # Mermaid diagrams and table references in README
    ("Downloader+VPN", "Downloader+VPN"),
    ("Downloader<br/>+ Gluetun VPN", "Downloader<br/>+ Gluetun VPN"),
    ("Downloader", "Downloader"),
    # Catch-all for remaining downloader references
    ("downloader", "downloader"),
    # Restore protected docker image
    ("linuxserver/qbittorrent", "linuxserver/qbittorrent"),
    # Homepage icon (keep 'downloader' as icon name — it's a dashboard icon slug)
    # Actually rename it to be consistent
    ("icon: downloader", "icon: downloader"),
    # Pod selector
    ("app=vpn-downloader", "app=vpn-downloader"),
    # Paths — must come after service name replacements
    ("/downloads-incomplete", "/downloads-incomplete"),
    ("/downloads", "/downloads"),
    # Volume names in templates
    ("name: downloads-incomplete", "name: downloads-incomplete"),
    ("name: downloads", "name: downloads"),
    # VPN firewall port comment context
    ("FIREWALL_VPN_INPUT_PORTS", "FIREWALL_VPN_INPUT_PORTS"),  # no change, just a marker

    # ── Network: blanket subnet shift ──
    ("192.168.1.", "192.168.1."),

    # ── Storage paths ──
    ("/data/hdd-internal", "/data/hdd-internal"),
    ("hdd-internal", "hdd-internal"),
    ("/data/nas-backups/kopia", "/data/nas-backups/kopia"),
    ("/data/nas-longhorn", "/data/nas-longhorn"),
    ("/data/nas-media", "/data/nas-media"),
    ("media-filtered", "media-filtered"),
    ("tube-archiver", "tube-archiver"),
    ("music", "music"),

    # ── Location ──
    ("Europe/London", "Europe/London"),
    ("latitude: 51.5074", "latitude: 51.5074"),
    ("longitude: -0.1278", "longitude: -0.1278"),
    ("label: London", "label: London"),
    ("serverCountries: UK", "serverCountries: UK"),
]

# ── Verification patterns (must NOT appear in output) ────────────────────────

VERIFY_ABSENT = [
    (r"user", "personal username"),
    (r"192\.168\.0\.", "original subnet"),
    (r"/volume1/", "NAS path"),
    (r"/root/HDD", "Proxmox HDD path"),
    (r"hdd-internal", "hdd-internal path reference"),
    (r"\bstash\b", "stash service"),
    (r"\btorrent\b", "torrent reference"),
    (r"(?<!linuxserver/)downloader", "downloader reference"),
]

# Files where 'stash' is allowed (none expected, but just in case)
VERIFY_STASH_EXCEPTIONS = set()

# ── Implementation ────────────────────────────────────────────────────────────

def should_exclude(rel_path: str, is_dir: bool) -> bool:
    parts = Path(rel_path).parts

    if is_dir:
        for exc_dir in EXCLUDE_DIRS:
            exc_parts = Path(exc_dir).parts
            # Match if any part of the path starts with the excluded dir
            for i in range(len(parts)):
                if parts[i:i+len(exc_parts)] == exc_parts:
                    return True
        return False

    # Check filename
    name = Path(rel_path).name
    if name in EXCLUDE_FILES:
        return True

    # Check suffix
    suffix = Path(rel_path).suffix
    if suffix in EXCLUDE_SUFFIXES:
        return True

    # Check if file ends with .disabled
    if name.endswith(".disabled"):
        return True

    # Check if inside an excluded directory
    for exc_dir in EXCLUDE_DIRS:
        exc_parts = Path(exc_dir).parts
        for i in range(len(parts)):
            if parts[i:i+len(exc_parts)] == exc_parts:
                return True

    return False


def copy_tree(src_root: Path, dst_root: Path, dry_run: bool = False) -> list[str]:
    copied = []
    for dirpath, dirnames, filenames in os.walk(src_root):
        rel_dir = os.path.relpath(dirpath, src_root)
        if rel_dir == ".":
            rel_dir = ""

        # Filter out excluded directories (modifying dirnames in-place skips them)
        dirnames[:] = [
            d for d in dirnames
            if not should_exclude(os.path.join(rel_dir, d) if rel_dir else d, is_dir=True)
        ]

        for fname in filenames:
            rel_file = os.path.join(rel_dir, fname) if rel_dir else fname
            if should_exclude(rel_file, is_dir=False):
                continue

            src_file = Path(dirpath) / fname
            dst_file = dst_root / rel_file

            if dry_run:
                print(f"  COPY {rel_file}")
            else:
                dst_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_file, dst_file)
            copied.append(rel_file)

    return copied


def delete_paths(root: Path, patterns: list[str], dry_run: bool = False):
    for pattern in patterns:
        target = root / pattern
        if target.exists():
            if dry_run:
                print(f"  DELETE {pattern}")
            else:
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()


def rename_dirs(root: Path, renames: list[tuple[str, str]], dry_run: bool = False):
    for old_rel, new_rel in renames:
        old_path = root / old_rel
        new_path = root / new_rel
        if old_path.exists():
            if dry_run:
                print(f"  RENAME DIR {old_rel} -> {new_rel}")
            else:
                new_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(old_path), str(new_path))


def rename_files(root: Path, renames: list[tuple[str, str]], dry_run: bool = False):
    for old_rel, new_rel in renames:
        old_path = root / old_rel
        new_path = root / new_rel
        if old_path.exists():
            if dry_run:
                print(f"  RENAME FILE {old_rel} -> {new_rel}")
            else:
                new_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(old_path), str(new_path))


def is_binary(file_path: Path) -> bool:
    try:
        with open(file_path, "rb") as f:
            chunk = f.read(8192)
            return b"\x00" in chunk
    except (OSError, IOError):
        return True


def apply_replacements(root: Path, dry_run: bool = False) -> dict[str, int]:
    stats = {}
    for dirpath, _, filenames in os.walk(root):
        for fname in filenames:
            fpath = Path(dirpath) / fname
            if is_binary(fpath):
                continue

            try:
                content = fpath.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue

            original = content
            file_changes = 0

            for old_text, new_text in TEXT_REPLACEMENTS:
                if old_text == new_text:
                    continue
                count = content.count(old_text)
                if count > 0:
                    content = content.replace(old_text, new_text)
                    file_changes += count

            if file_changes > 0:
                rel = os.path.relpath(fpath, root)
                stats[rel] = file_changes
                if dry_run:
                    print(f"  REPLACE {rel}: {file_changes} substitutions")
                else:
                    fpath.write_text(content, encoding="utf-8")

    return stats


# Files to skip during verification (they contain the replacement patterns themselves)
VERIFY_SKIP_FILES = {"sanitize-for-public.py"}


def verify_output(root: Path) -> list[str]:
    issues = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Check no .tmp directory
        if ".tmp" in dirnames:
            issues.append(f"FAIL: .tmp/ directory exists at {dirpath}")

        for fname in filenames:
            fpath = Path(dirpath) / fname
            rel = os.path.relpath(fpath, root)

            # Check no values-secret.yaml
            if fname == "values-secret.yaml":
                issues.append(f"FAIL: {rel} — secret file present")
                continue

            if fname in VERIFY_SKIP_FILES:
                continue

            if is_binary(fpath):
                continue

            try:
                content = fpath.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue

            for pattern, description in VERIFY_ABSENT:
                matches = list(re.finditer(pattern, content, re.IGNORECASE))
                if matches:
                    for m in matches:
                        # Get line number
                        line_num = content[:m.start()].count("\n") + 1
                        line_text = content.splitlines()[line_num - 1].strip()
                        issues.append(
                            f"FAIL: {rel}:{line_num} — {description} found: '{m.group()}' in: {line_text}"
                        )

    return issues


def main():
    parser = argparse.ArgumentParser(description="Sanitize repo for public release")
    parser.add_argument(
        "--output", "-o",
        default=DEFAULT_OUTPUT,
        help=f"Output directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--force", "-f",
        action="store_true",
        help="Overwrite output directory if it exists",
    )
    args = parser.parse_args()

    # Resolve paths
    src_root = Path(__file__).resolve().parent.parent
    dst_root = (src_root / args.output).resolve()

    print(f"Source:  {src_root}")
    print(f"Output:  {dst_root}")
    print(f"Dry run: {args.dry_run}")
    print()

    # Safety check
    if dst_root == src_root:
        print("ERROR: Output directory cannot be the same as source!", file=sys.stderr)
        sys.exit(1)

    if dst_root.exists():
        if args.force:
            if not args.dry_run:
                shutil.rmtree(dst_root)
            print(f"Removed existing output directory: {dst_root}")
        else:
            print(
                f"ERROR: Output directory already exists: {dst_root}\n"
                f"Use --force to overwrite.",
                file=sys.stderr,
            )
            sys.exit(1)

    # Step 1: Copy with exclusions
    print("Step 1: Copying files (excluding sensitive content)...")
    copied = copy_tree(src_root, dst_root, dry_run=args.dry_run)
    print(f"  {len(copied)} files copied\n")

    # Step 2: Delete remaining unwanted files
    print("Step 2: Deleting excluded files/dirs...")
    delete_paths(dst_root, DELETE_AFTER_COPY, dry_run=args.dry_run)
    print()

    # Step 3: Rename directories
    print("Step 3: Renaming directories...")
    rename_dirs(dst_root, DIR_RENAMES, dry_run=args.dry_run)
    print()

    # Step 4: Rename files
    print("Step 4: Renaming files...")
    rename_files(dst_root, FILE_RENAMES, dry_run=args.dry_run)
    print()

    # Step 5: Apply text replacements
    print("Step 5: Applying text replacements...")
    stats = apply_replacements(dst_root, dry_run=args.dry_run)
    total_subs = sum(stats.values())
    print(f"  {total_subs} substitutions across {len(stats)} files\n")

    # Step 6: Verification
    print("Step 6: Verifying output...")
    if not args.dry_run:
        issues = verify_output(dst_root)
        if issues:
            print(f"\n  ⚠ {len(issues)} issues found:\n")
            for issue in issues:
                print(f"    {issue}")
            print(
                "\n  Review these manually. Some may be false positives "
                "(e.g., 'stash' in unrelated context)."
            )
        else:
            print("  ✓ All verification checks passed!\n")
    else:
        print("  (skipped in dry-run mode)\n")

    # Summary
    print("=" * 60)
    if args.dry_run:
        print("DRY RUN complete. No files were modified.")
    else:
        print(f"Sanitized repo created at: {dst_root}")
        print()
        print("Next steps:")
        print(f"  cd {dst_root}")
        print("  git init")
        print("  git add .")
        print('  git commit -m "Initial public release"')
        print("  git remote add origin https://github.com/YOUR_USER/proxmox-k8s.git")
        print("  git push -u origin main")


if __name__ == "__main__":
    main()
