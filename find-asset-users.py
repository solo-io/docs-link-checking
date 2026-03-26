#!/usr/bin/env python3
"""
Resolve asset file changes to the content pages that reuse them, and
optionally map to built HTML paths for link checking.

Usage:
  python3 find-asset-users.py [OPTIONS] <path> [<path> ...]
  python3 find-asset-users.py [OPTIONS] -        (read paths from stdin)

Options:
  --repo-root PATH          Root of the docs repo (default: parent of script dir)
  --content-only            Output affected content file paths, one per line.
                            Accepts mixed content/ and assets/ input: content/
                            files are passed through, assets/ are resolved to
                            their content pages. Exits 1 if nothing resolved.
  --html-paths              Output space-separated built HTML paths. Accepts
                            mixed content/ and assets/ input. Exits 1 if no
                            HTML files were found (caller should fall back to
                            checking all HTML).
  --public-prefix PREFIX    Public directory prefix for HTML paths
                            (e.g. 'public' or 'public/kagent-enterprise').
                            Required with --html-paths.

Examples:
  # Human-readable report (asset paths only)
  python3 find-asset-users.py --repo-root . assets/docs/pages/operations/upgrade.md

  # Content paths for product detection (mixed content + asset input)
  git diff --name-only origin/main...HEAD \\
    | python3 find-asset-users.py --repo-root /workspace --content-only -

  # HTML paths for lychee (mixed content + asset input)
  git diff --name-only origin/main...HEAD \\
    | python3 find-asset-users.py \\
        --repo-root /workspace \\
        --html-paths --public-prefix public/kagent-enterprise -
"""

import re
import sys
from pathlib import Path

REUSE_PATTERN = re.compile(r'\{\{<\s*reuse\s+["\']([^"\']+)["\']\s*>?\}\}')


def build_index(content_dir: Path) -> dict:
    """Map asset key -> list of content files that reuse it."""
    index = {}
    for content_file in content_dir.rglob("*.md"):
        text = content_file.read_text(errors="replace")
        if "reuse" not in text:
            continue
        for match in REUSE_PATTERN.finditer(text):
            asset_key = match.group(1)
            index.setdefault(asset_key, []).append(content_file)
    return index


def asset_to_key(asset_path: str) -> str:
    """Normalize an asset path to the key used in reuse shortcodes."""
    p = asset_path.lstrip("/")
    if p.startswith("assets/"):
        p = p[len("assets/"):]
    return p


def content_to_html(content_path: str, public_prefix: str) -> str:
    """Map a content/*.md path to its built public HTML path."""
    rel = content_path
    if rel.startswith("content/"):
        rel = rel[len("content/"):]
    if rel.endswith("/_index.md"):
        return f"{public_prefix}/{rel[:-len('/_index.md')]}/index.html"
    if rel == "_index.md":
        return f"{public_prefix}/index.html"
    return f"{public_prefix}/{rel[:-len('.md')]}/index.html"


def resolve_to_content(paths: list, repo_root: Path) -> list:
    """
    Given a mixed list of paths, return all affected content file paths.
    content/ files pass through; assets/ files are resolved via the reuse index.
    Other paths are ignored.
    """
    content_paths = [p for p in paths if p.startswith("content/") and p.endswith(".md")]
    asset_paths   = [p for p in paths if p.startswith("assets/")  and p.endswith(".md")]

    if asset_paths:
        index = build_index(repo_root / "content")
        for ap in asset_paths:
            for cf in index.get(asset_to_key(ap), []):
                content_paths.append(str(cf.relative_to(repo_root)))

    # Deduplicate preserving order
    seen = set()
    result = []
    for p in content_paths:
        if p not in seen:
            seen.add(p)
            result.append(p)
    return result


def main():
    args = sys.argv[1:]

    def pop_flag(flag):
        if flag in args:
            args.remove(flag)
            return True
        return False

    def pop_option(flag):
        if flag in args:
            idx = args.index(flag)
            val = args[idx + 1]
            args[idx:idx + 2] = []
            return val
        return None

    repo_root     = Path(pop_option("--repo-root") or Path(__file__).parent.parent)
    content_only  = pop_flag("--content-only")
    html_paths    = pop_flag("--html-paths")
    public_prefix = pop_option("--public-prefix") or "public"

    if not args:
        print(__doc__)
        sys.exit(1)

    raw_paths = [line.strip() for line in sys.stdin if line.strip()] if args[0] == "-" else args

    if html_paths:
        # Resolve mixed input to content paths, then map to HTML paths.
        html_files = []
        for cp in resolve_to_content(raw_paths, repo_root):
            html = content_to_html(cp, public_prefix)
            if (repo_root / html).exists():
                html_files.append(html)
        if not html_files:
            sys.exit(1)
        print(" ".join(html_files))

    elif content_only:
        # Resolve mixed input to content paths.
        result = resolve_to_content(raw_paths, repo_root)
        if not result:
            sys.exit(1)
        for p in result:
            print(p)

    else:
        # Human-readable report (asset paths only).
        index = build_index(repo_root / "content")
        found_any = False
        for raw in raw_paths:
            key = asset_to_key(raw)
            users = index.get(key, [])
            if users:
                found_any = True
                print(f"\nassets/{key}")
                for f in sorted(users):
                    print(f"  {f.relative_to(repo_root)}")
            else:
                print(f"\nassets/{key}")
                print(f"  (no content files reuse this asset)")
        if not found_any:
            sys.exit(1)


if __name__ == "__main__":
    main()
