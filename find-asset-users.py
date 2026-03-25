#!/usr/bin/env python3
"""
Given one or more asset paths, print the content files that reuse them.

Usage:
  python3 find-asset-users.py [--repo-root PATH] [--content-only] <asset> [<asset> ...]
  python3 find-asset-users.py [--repo-root PATH] [--content-only] -

Options:
  --repo-root PATH   Root of the docs repo (default: parent of this script's directory)
  --content-only     Output only content file paths, one per line (useful for scripting)
  -                  Read asset paths from stdin, one per line

Examples:
  python3 find-asset-users.py assets/docs/pages/operations/upgrade.md
  git diff --name-only origin/main...HEAD | python3 find-asset-users.py --repo-root /workspace -
"""

import re
import sys
from pathlib import Path

# Matches {{< reuse "docs/pages/..." >}} or {{< reuse 'docs/pages/...' >}}
REUSE_PATTERN = re.compile(r'\{\{<\s*reuse\s+["\']([^"\']+)["\']\s*>?\}\}')


def build_index(content_dir: Path):
    """Map each asset key -> list of content files that reuse it."""
    index = {}
    for content_file in content_dir.rglob("*.md"):
        text = content_file.read_text(errors="replace")
        for match in REUSE_PATTERN.finditer(text):
            asset_key = match.group(1)  # e.g. "docs/pages/operations/upgrade.md"
            index.setdefault(asset_key, []).append(content_file)
    return index


def asset_to_key(asset_path: str) -> str:
    """Normalize an asset path to the key used in reuse shortcodes."""
    p = asset_path.lstrip("/")
    if p.startswith("assets/"):
        p = p[len("assets/"):]
    return p


def main():
    args = sys.argv[1:]

    # Parse --repo-root
    repo_root = None
    if "--repo-root" in args:
        idx = args.index("--repo-root")
        repo_root = Path(args[idx + 1])
        args = args[:idx] + args[idx + 2:]

    # Parse --content-only
    content_only = "--content-only" in args
    if content_only:
        args.remove("--content-only")

    if not args:
        print(__doc__)
        sys.exit(1)

    if repo_root is None:
        repo_root = Path(__file__).parent.parent

    content_dir = repo_root / "content"
    index = build_index(content_dir)

    # Read asset paths from stdin or args
    if args[0] == "-":
        raw_paths = [line.strip() for line in sys.stdin if line.strip()]
    else:
        raw_paths = args

    found_any = False
    for raw in raw_paths:
        key = asset_to_key(raw)
        users = index.get(key, [])
        if users:
            found_any = True
            if content_only:
                for f in sorted(users):
                    print(f.relative_to(repo_root))
            else:
                print(f"\nassets/{key}")
                for f in sorted(users):
                    print(f"  {f.relative_to(repo_root)}")
        elif not content_only:
            print(f"\nassets/{key}")
            print(f"  (no content files reuse this asset)")

    if not found_any:
        sys.exit(1)


if __name__ == "__main__":
    main()
