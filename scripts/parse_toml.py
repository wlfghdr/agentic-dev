#!/usr/bin/env python3
import sys
import os

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

def parse_simple_toml(file_path):
    import re
    config = {}
    current_section = None
    array_sections = {}
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            array_match = re.match(r"^\[\[([^\]]+)\]\]$", line)
            if array_match:
                sect = array_match.group(1)
                new_table = {}
                array_sections.setdefault(sect, []).append(new_table)
                config[sect] = array_sections[sect]
                current_section = new_table
                continue
            section_match = re.match(r"^\[([^\]]+)\]$", line)
            if section_match:
                sect = section_match.group(1)
                parts = sect.split(".")
                curr = config
                for p in parts[:-1]:
                    curr = curr.setdefault(p, {})
                current_section = curr.setdefault(parts[-1], {})
                continue
            kv_match = re.match(r"^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$", line)
            if kv_match and current_section is not None:
                key, val = kv_match.group(1), kv_match.group(2).strip()
                if "#" in val:
                    val = val.split("#", 1)[0].strip()
                if val.startswith("[") and val.endswith("]"):
                    items = []
                    for item in re.findall(r'"([^"]*)"', val):
                        items.append(item)
                    current_section[key] = items
                elif val.startswith('"') and val.endswith('"'):
                    current_section[key] = val[1:-1]
                elif val.lower() in ("true", "false"):
                    current_section[key] = val.lower() == "true"
                else:
                    try:
                        current_section[key] = int(val)
                    except ValueError:
                        current_section[key] = val
    return config

def main():
    if len(sys.argv) < 3:
        print("Usage: parse_toml.py <file> <query_path> [extra_arg]", file=sys.stderr)
        sys.exit(1)
    file_path = sys.argv[1]
    query = sys.argv[2]
    
    if tomllib:
        try:
            with open(file_path, "rb") as f:
                config = tomllib.load(f)
        except Exception:
            config = {}
    else:
        config = parse_simple_toml(file_path)
        
    # Query path parsing
    if query in ("repos.automerge", "repos.dependabot_automerge", "repos.release"):
        repo_name = sys.argv[3] if len(sys.argv) > 3 else ""
        key = query.split(".", 1)[1]
        defaults = {
            "automerge": False,
            "dependabot_automerge": True,
            "release": True,
        }
        repos = config.get("repos", [])
        found = False
        for r in repos:
            if r.get("name") == repo_name:
                print("true" if r.get(key, defaults[key]) else "false")
                found = True
                break
        if not found:
            print("true" if defaults[key] else "false")
    else:
        parts = query.split(".")
        curr = config
        for p in parts:
            if isinstance(curr, dict):
                curr = curr.get(p, {})
            else:
                curr = {}
        if isinstance(curr, list):
            print(" ".join(str(x) for x in curr))
        elif isinstance(curr, bool):
            print("true" if curr else "false")
        elif curr is not None and not isinstance(curr, dict):
            print(curr)
            
if __name__ == "__main__":
    main()
