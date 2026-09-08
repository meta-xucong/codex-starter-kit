"""Build the copyable, offline-auditable Codex capability pack.

The source tree is the editable catalog.  installer-pack/ is generated output and
contains only files that are safe to copy to another machine.  No network access,
credentials, caches, histories, or user artifacts are read by this script.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "installer-pack"
PACK_ID = "codex-starter"
PACK_VERSION = "1.2.0"
MIN_CODEX_VERSION = "0.144.0"
TESTED_CODEX_VERSION = os.environ.get("CODEX_TESTED_VERSION", "0.147.0")
STATUSES = {"ready", "requires-runtime", "requires-mcp", "requires-credential", "unsupported/disabled"}
AFTER_STATUSES = {"core-ready", "auto-installable-runtime", "guided-config", "unsupported"}
PACK_STATUSES = AFTER_STATUSES
TRANSIENT_NAMES = {".cache", ".git", ".codex", ".learnings", "drafts", "output", "__pycache__", "sessions", "memory", "logs", "createContent", "codex-data", "hooks", "node_modules", ".venv", "venv", "wheelhouse", "materialized", ".ds_store", "thumbs.db", "desktop.ini"}
# Plain `.lock` files can be deliberate reproducibility contracts (for example the
# Python requirements lock); cache/database locks are filtered explicitly below.
TRANSIENT_SUFFIXES = {".db", ".sqlite", ".sqlite3"}


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def read_manifest(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")]


def frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    lines = text[4:end].splitlines()
    values: dict[str, str] = {}
    index = 0
    while index < len(lines):
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", lines[index])
        if not match:
            index += 1
            continue
        key, raw = match.groups()
        raw = raw.strip()
        if key == "description" and raw in {"|", ">", "|-", ">-"}:
            chunks = []
            index += 1
            while index < len(lines) and (lines[index].startswith(" ") or not lines[index].strip()):
                chunks.append(lines[index].strip())
                index += 1
            values[key] = " ".join(item for item in chunks if item)
            continue
        values[key] = raw.strip('"').strip("'")
        index += 1
    return values


def parse_toml(path: Path) -> dict[str, str]:
    try:
        import tomllib

        return tomllib.loads(path.read_text(encoding="utf-8"))
    except ModuleNotFoundError:
        result: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r'^\s*(name|description|developer_instructions)\s*=\s*["\'](.*)["\']\s*$', line)
            if match:
                result[match.group(1)] = match.group(2)
        return result


def safe_copy_tree(source: Path, destination: Path) -> None:
    for candidate in source.rglob("*"):
        is_junction = getattr(candidate, "is_junction", lambda: False)
        if candidate.is_symlink() or is_junction():
            raise SystemExit(f"Refusing to copy a symbolic link or junction: {candidate}")

    def ignore(_directory: str, names: list[str]) -> set[str]:
        ignored = set()
        for name in names:
            lower = name.casefold()
            if name in TRANSIENT_NAMES or lower in {item.casefold() for item in TRANSIENT_NAMES}:
                ignored.add(name)
            elif lower.endswith(tuple(s.casefold() for s in TRANSIENT_SUFFIXES)):
                ignored.add(name)
            elif lower.endswith("_tasks.json") or lower.endswith(".json.lock"):
                ignored.add(name)
            elif lower.endswith("-market.json"):
                ignored.add(name)
            elif lower == ".env" or lower.startswith(".env."):
                ignored.add(name)
            elif lower.endswith(("credentials.json", "secrets.json")):
                ignored.add(name)
        return ignored

    shutil.copytree(source, destination, ignore=ignore, dirs_exist_ok=True)


def component_dependency(raw: str, status: str, capabilities: list[str]) -> dict:
    text = str(raw)
    required = status not in {"ready", "unsupported/disabled"}
    if text.startswith("python>="):
        return {"type":"runtime","name":"Python","minVersion":text.split(">=",1)[1],"architecture":"x64","required":required,"offlineInstallerFilename":"python-3.x.x-amd64.exe","detection":"python --version or py -3 --version","silentArgs":"/quiet InstallAllUsers=0 PrependPath=0 Include_test=0","restart":"recommended","license":"PSF License","source":"https://www.python.org/downloads/windows/","dependentCapabilities":capabilities}
    if text in {"python>=3.10 optional", "Python 3.10+"}:
        return {"type":"runtime","name":"Python","minVersion":"3.10","architecture":"x64","required":False,"offlineInstallerFilename":"python-3.x.x-amd64.exe","detection":"python --version or py -3 --version","silentArgs":"/quiet InstallAllUsers=0 PrependPath=0 Include_test=0","restart":"recommended","license":"PSF License","source":"https://www.python.org/downloads/windows/","dependentCapabilities":capabilities}
    if text.startswith("python"):
        return {"type":"runtime","name":"Python package runtime","minVersion":"3.10","architecture":"x64","required":required,"offlineInstallerFilename":"python-3.x.x-amd64.exe","detection":"python --version","silentArgs":"/quiet InstallAllUsers=0 PrependPath=0 Include_test=0","restart":"recommended","license":"PSF License","source":"https://www.python.org/downloads/windows/","dependentCapabilities":capabilities}
    if text in {"Windows PowerShell", "curl.exe or Invoke-RestMethod", "network"}:
        return {"type":"system","name":text,"minVersion":"Windows 10","architecture":"x64","required":required,"offlineInstallerFilename":None,"detection":"Get-Command curl.exe or Get-Command Invoke-RestMethod","silentArgs":None,"restart":"none","license":"Microsoft system component","source":"Windows 10/11","dependentCapabilities":capabilities}
    if text.endswith("-mcp") or text == "feishu-doc-mcp" or text.startswith("feishu-"):
        return {"type":"mcp","name":text,"minVersion":None,"architecture":"any","required":True,"offlineInstallerFilename":None,"detection":"MCP client lists the declared tools","silentArgs":None,"restart":"client reload","license":"user supplied","source":"user supplied MCP server","dependentCapabilities":capabilities}
    if text.endswith("_API_KEY") or text.endswith("_BASE_URL"):
        return {"type":"credential","name":text,"minVersion":None,"architecture":"any","required":True,"offlineInstallerFilename":None,"detection":f"environment variable {text} is non-empty","silentArgs":None,"restart":"client reload","license":"user supplied","source":"user environment or secret manager","dependentCapabilities":capabilities}
    if text in {"native-web-or-user-sources", "native-web-tool-or-user-sources"}:
        return {"type":"capability","name":text,"minVersion":None,"architecture":"any","required":False,"offlineInstallerFilename":None,"detection":"current Codex web tool or user-provided sources","silentArgs":None,"restart":"none","license":"current environment","source":"Codex or user supplied","dependentCapabilities":capabilities}
    if text in {"image-2-endpoint", "seedance-endpoint", "optional image endpoint"} or text.startswith("optional "):
        return {"type":"service","name":text,"minVersion":None,"architecture":"any","required":required,"offlineInstallerFilename":None,"detection":"endpoint configured by user","silentArgs":None,"restart":"none","license":"service provider terms","source":"user supplied","dependentCapabilities":capabilities}
    if "[" in text or text in {"pandas", "numpy", "matplotlib", "akshare", "openpyxl", "python-docx", "python-pptx", "pypdf", "pdfplumber", "reportlab", "html2text"}:
        package = text.split("[", 1)[0]
        return {"type":"python-package","name":package,"minVersion":"see runtime/wheelhouse-manifest.json","architecture":"any","required":required,"offlineInstallerFilename":f"{package}-wheelhouse.zip","detection":f"python -c \"import {package.replace('-', '_')}\"","silentArgs":None,"restart":"none","license":"package license","source":"PyPI or approved offline wheelhouse","dependentCapabilities":capabilities}
    return {"type":"dependency","name":text,"minVersion":None,"architecture":"any","required":required,"offlineInstallerFilename":None,"detection":"manual check","silentArgs":None,"restart":"none","license":"verify before use","source":"user supplied","dependentCapabilities":capabilities}


def normalize_dependency(raw, item: dict) -> dict:
    """Keep the audit's multidimensional dependency contract intact."""
    if isinstance(raw, dict):
        dependency = dict(raw)
        dependency.setdefault("required", True)
        dependency.setdefault("autoInstallable", False)
        dependency.setdefault("dependentCapabilities", item.get("capabilities", []))
        return dependency
    return component_dependency(str(raw), item["status"], item.get("capabilities", []))


def build_dependencies(audit: dict, agents: dict) -> dict:
    skills = []
    catalog: dict[str, dict] = {}
    for item in audit["skills"]:
        deps = [normalize_dependency(dep, item) for dep in item.get("dependencies", [])]
        for dependency in deps:
            dependency_id = dependency.get("id") or dependency.get("name")
            dependency["id"] = dependency_id
            if dependency_id not in catalog:
                catalog[dependency_id] = dict(dependency)
                catalog[dependency_id]["dependentSkills"] = []
            catalog[dependency_id]["required"] = bool(catalog[dependency_id].get("required")) or bool(dependency.get("required"))
            if item["id"] not in catalog[dependency_id]["dependentSkills"]:
                catalog[dependency_id]["dependentSkills"].append(item["id"])
        skills.append({
            "id": item["id"], "path": f"skills/{item['id']}", "status": item["status"],
            "afterRemediationStatus": item.get("afterRemediationStatus"),
            "installByDefault": bool(item.get("installByDefault", item.get("defaultEnabled", False))),
            "enableWhen": item.get("enableWhen", []),
            "dependencyTypes": sorted({dep.get("kind", dep.get("type", "unknown")) for dep in deps}),
            "dependencies": [dep.get("id") for dep in deps],
            "dependentCapabilities": item.get("capabilities", []),
            "healthCheck": item.get("verification", {}).get("smoke", ""), "notes": item.get("notes", "")
        })
    agent_items = []
    for item in agents["agents"]:
        required = item.get("requiredSkills", item.get("skills", []))
        optional = item.get("optionalSkills", [])
        blocked = item.get("blockedSkills", [])
        deps = [{"id":f"skill.{skill}","kind":"skill","name":skill,"required":True,"autoInstallable":True,"healthCheck":f"skills/{skill}/SKILL.md exists","dependentCapabilities":[item["description"]]} for skill in required]
        deps += [{"id":f"skill.{skill}","kind":"skill","name":skill,"required":False,"autoInstallable":True,"healthCheck":f"skills/{skill}/SKILL.md exists","dependentCapabilities":[item["description"]]} for skill in optional]
        deps += [{"id":f"skill.{skill}","kind":"skill","name":skill,"required":False,"autoInstallable":False,"blocked":True,"healthCheck":"blocked pending explicit compatibility/license approval","dependentCapabilities":[item["description"]]} for skill in blocked]
        for dependency in deps:
            dependency_id = dependency["id"]
            if dependency_id not in catalog:
                catalog[dependency_id] = dict(dependency)
                catalog[dependency_id]["dependentAgents"] = []
            catalog[dependency_id].setdefault("dependentAgents", [])
            if item["id"] not in catalog[dependency_id]["dependentAgents"]:
                catalog[dependency_id]["dependentAgents"].append(item["id"])
            catalog[dependency_id]["required"] = bool(catalog[dependency_id].get("required")) or bool(dependency.get("required"))
        for dependency_id in item.get("runtimeDependencies", []) + item.get("connectionDependencies", []):
            kind = "runtime" if str(dependency_id).startswith("runtime.") else "connection"
            dependency = {
                "id": dependency_id,
                "kind": kind,
                "name": dependency_id,
                "required": False,
                "autoInstallable": kind == "runtime",
                "healthCheck": f"{dependency_id}.healthy",
                "failureMessage": "可选增强未就绪时保留 Agent 基础能力并明确降级。",
                "dependentCapabilities": [item["description"]],
            }
            deps.append(dependency)
            if dependency_id not in catalog:
                catalog[dependency_id] = dict(dependency)
                catalog[dependency_id]["dependentSkills"] = []
            catalog[dependency_id].setdefault("dependentAgents", [])
            if item["id"] not in catalog[dependency_id]["dependentAgents"]:
                catalog[dependency_id]["dependentAgents"].append(item["id"])
            catalog[dependency_id]["required"] = bool(catalog[dependency_id].get("required")) or bool(dependency.get("required"))
        agent_items.append({
            "id": item["id"], "file": f"agents/{item['file']}", "name": item["name"], "description": item["description"],
            "status": item.get("status"), "readiness": item.get("readiness", {}), "requiredSkills": required, "optionalSkills": optional,
            "blockedSkills": blocked,
            "connectionDependencies": item.get("connectionDependencies", []), "runtimeDependencies": item.get("runtimeDependencies", []),
            "dependencyTypes": sorted({dep.get("kind", "unknown") for dep in deps}), "dependencies": deps, "dependentCapabilities":[item["description"]]
        })
    system = [
        {"type":"system","name":"Windows 10/11","minVersion":"10","architecture":"x64","required":True,"offlineInstallerFilename":None,"detection":"Get-CimInstance Win32_OperatingSystem","silentArgs":None,"restart":"none","license":"Microsoft","source":"Windows","dependentCapabilities":["installer"]},
        {"type":"runtime","name":"PowerShell","minVersion":"5.1","architecture":"x64","required":True,"offlineInstallerFilename":None,"detection":"$PSVersionTable.PSVersion","silentArgs":None,"restart":"none","license":"Microsoft","source":"Windows","dependentCapabilities":["installer"]}
    ]
    return {"schemaVersion":2,"id":PACK_ID,"version":PACK_VERSION,"policy":"No secrets, caches, history, databases, drafts or user content.","system":system,"dependencyCatalog":sorted(catalog.values(), key=lambda value: value["id"]),"skills":skills,"agents":agent_items}


def derived_agent_status(item: dict, audit: dict) -> str:
    skill_map = {skill["id"]: skill for skill in audit["skills"]}
    statuses = []
    for skill_id in item.get("requiredSkills", item.get("skills", [])):
        if skill_id not in skill_map:
            raise SystemExit(f"Agent required skill missing from audit: {item['id']} -> {skill_id}")
        statuses.append(skill_map[skill_id].get("afterRemediationStatus"))
    if any(status == "unsupported" for status in statuses):
        return "unsupported"
    if any(status == "guided-config" for status in statuses):
        return "guided-config"
    if any(status == "auto-installable-runtime" for status in statuses):
        return "auto-installable-runtime"
    return "core-ready"


def validate_sources(skill_names: list[str], audit: dict, agents: dict) -> None:
    expected = set(skill_names)
    seen_names: dict[str, str] = {}
    for skill_id in skill_names:
        doc = ROOT / "skills" / skill_id / "SKILL.md"
        metadata = frontmatter(doc)
        name = metadata.get("name", "").strip()
        description = metadata.get("description", "").strip()
        if name != skill_id:
            raise SystemExit(f"Skill name mismatch: {skill_id} has {name!r}")
        if not description:
            raise SystemExit(f"Skill description missing: {skill_id}")
        if name in seen_names:
            raise SystemExit(f"Duplicate skill name: {name} ({seen_names[name]}, {skill_id})")
        seen_names[name] = skill_id
    if len(seen_names) != 50:
        raise SystemExit(f"Expected 50 unique skill names, got {len(seen_names)}")
    known = set(seen_names)
    for item in audit["skills"]:
        if item.get("afterRemediationStatus") not in {"core-ready", "auto-installable-runtime", "guided-config", "unsupported"}:
            raise SystemExit(f"Missing afterRemediationStatus: {item['id']}")
        if bool(item.get("installByDefault", False)) and item["afterRemediationStatus"] != "core-ready":
            raise SystemExit(f"Non-core skill cannot be installed by default: {item['id']}")
        for dependency in item.get("dependencies", []):
            if not isinstance(dependency, dict) or not dependency.get("id") or not dependency.get("kind"):
                raise SystemExit(f"Dependency must be a multidimensional object: {item['id']}")
    agent_names = set()
    for item in agents["agents"]:
        expected_status = derived_agent_status(item, audit)
        if item.get("status") != expected_status:
            raise SystemExit(f"Agent status must be derived from requiredSkills: {item['id']} expected {expected_status} got {item.get('status')}")
        if item.get("readiness", {}).get("minimum") != expected_status:
            raise SystemExit(f"Agent readiness minimum must match requiredSkills: {item['id']}")
        path = ROOT / "agents" / item["file"]
        if not path.is_file():
            raise SystemExit(f"Agent file missing: {item['file']}")
        parsed = parse_toml(path)
        for required in ("name", "description", "developer_instructions"):
            if not str(parsed.get(required, "")).strip():
                raise SystemExit(f"Agent field missing: {item['file']} -> {required}")
        if "model" in parsed or "mcp" in parsed:
            raise SystemExit(f"Agent contains an unnecessary lock or unsupported field: {item['file']}")
        if parsed["name"] != item["name"]:
            raise SystemExit(f"Agent catalog name mismatch: {item['file']}")
        if parsed["name"] in agent_names:
            raise SystemExit(f"Duplicate agent name: {parsed['name']}")
        agent_names.add(parsed["name"])
        text = f"{parsed['description']}\n{parsed['developer_instructions']}"
        declared = set(item.get("skills", [])) | set(item.get("requiredSkills", [])) | set(item.get("optionalSkills", [])) | set(item.get("blockedSkills", []))
        for skill_id in re.findall(r"[a-z][a-z0-9]+(?:-[a-z0-9]+)+", text):
            if skill_id in known and skill_id not in declared:
                raise SystemExit(f"Agent dependency catalog incomplete: {item['file']} -> {skill_id}")
        for skill_id in declared:
            if skill_id not in known:
                raise SystemExit(f"Agent references missing skill: {item['file']} -> {skill_id}")
        if set(item.get("requiredSkills", [])) & set(item.get("optionalSkills", [])):
            raise SystemExit(f"Agent required/optional overlap: {item['file']}")
        if set(item.get("blockedSkills", [])) & (set(item.get("requiredSkills", [])) | set(item.get("optionalSkills", []))):
            raise SystemExit(f"Agent blocked Skill overlaps an executable dependency: {item['file']}")
        executable_skills = set(item.get("requiredSkills", [])) | set(item.get("optionalSkills", []))
        if set(item.get("skills", [])) != executable_skills:
            raise SystemExit(f"Agent skills must equal requiredSkills + optionalSkills: {item['file']}")
    forbidden_tokens = ["open" + "claw", "claw" + "dbot", "ran" + "claw"]
    forbidden = re.compile("|".join(re.escape(token) for token in forbidden_tokens), re.IGNORECASE)
    secret_like = re.compile(r"(?:sk-[A-Za-z0-9]{20,}|Bearer\\s+[A-Za-z0-9._-]{20,})")
    text_suffixes = {".md", ".py", ".js", ".ts", ".json", ".toml", ".ps1", ".sh", ".txt", ".yaml", ".yml", ".lock"}
    for path in [ROOT / "README.md", ROOT / "ENVIRONMENT-MCP-INVENTORY.md", ROOT / "agents", ROOT / "manifest", ROOT / "scripts", ROOT / "skills", ROOT / "runtime", ROOT / "config-fragments"]:
        paths = [path] if path.is_file() else [candidate for candidate in path.rglob("*") if candidate.is_file()]
        for candidate in paths:
            if candidate.name.casefold().endswith("-market.json") or candidate.suffix.lower() not in text_suffixes or any(part in TRANSIENT_NAMES for part in candidate.parts):
                continue
            text = candidate.read_text(encoding="utf-8")
            if forbidden.search(text):
                raise SystemExit(f"Legacy platform marker found: {candidate}")
            if secret_like.search(text):
                raise SystemExit(f"Secret-like token found: {candidate}")


def pack_files() -> list[Path]:
    return sorted(path for path in PACK.rglob("*") if path.is_file())


def git_head_commit() -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", "HEAD^{commit}"],
            capture_output=True,
            text=True,
            check=True,
        )
        commit = result.stdout.strip()
        if re.fullmatch(r"[0-9a-fA-F]{40}", commit):
            return commit.lower()
    except (OSError, subprocess.CalledProcessError):
        pass
    return None


def source_commit() -> str:
    commit = git_head_commit()
    if commit:
        return commit
    lock = ROOT / "manifest" / "source-commit.txt"
    if lock.is_file():
        commit = lock.read_text(encoding="utf-8").strip()
        if re.fullmatch(r"[0-9a-fA-F]{40}", commit):
            return commit.lower()
        raise SystemExit("manifest/source-commit.txt must contain one 40-character Git commit")
    return "uncommitted-source"


def source_commit_role() -> str:
    # A generated pack cannot record the hash of the commit that contains the
    # generated pack without a circular self-reference.  The commit is the
    # build-input pointer; sourceTreeSha256 is the exact reproducible identity.
    return "build-input" if git_head_commit() else "upstream-base"


def source_tree_sha256() -> str:
    """Hash the editable source inputs independently from generated installer-pack/."""
    roots = [
        ROOT / "README.md",
        ROOT / "ENVIRONMENT-MCP-INVENTORY.md",
        ROOT / "agents",
        ROOT / "config-fragments",
        ROOT / "docs",
        ROOT / "manifest",
        ROOT / "runtime",
        ROOT / "scripts",
        ROOT / "skills",
    ]
    candidates: list[Path] = []
    for root in roots:
        if root.is_file():
            candidates.append(root)
        elif root.is_dir():
            candidates.extend(path for path in root.rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in sorted(candidates, key=lambda item: item.relative_to(ROOT).as_posix()):
        relative = path.relative_to(ROOT).as_posix()
        if any(part.casefold() in {name.casefold() for name in TRANSIENT_NAMES} for part in path.parts):
            continue
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def checksum_lines() -> list[str]:
    lines = []
    for path in pack_files():
        relative = path.relative_to(PACK).as_posix()
        if relative == "checksums.sha256":
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest} *{relative}")
    return lines


def verify_pack_provenance() -> dict:
    """Verify generated metadata without rebuilding or mutating the pack."""
    pack_path = PACK / "pack.json"
    if not pack_path.is_file():
        raise SystemExit("installer-pack/pack.json is missing")
    pack = read_json(pack_path)
    commit = str(pack.get("sourceCommit", ""))
    role = str(pack.get("sourceCommitRole", ""))
    tree_hash = str(pack.get("sourceTreeSha256", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("pack.json sourceCommit must be a 40-character lowercase Git commit")
    if role not in {"build-input", "upstream-base"}:
        raise SystemExit(f"pack.json sourceCommitRole is invalid: {role!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", tree_hash):
        raise SystemExit("pack.json sourceTreeSha256 must be a 64-character lowercase SHA-256")
    expected_tree_hash = source_tree_sha256()
    if tree_hash != expected_tree_hash:
        raise SystemExit(
            "Generated pack is stale: "
            f"pack sourceTreeSha256={tree_hash}, current sourceTreeSha256={expected_tree_hash}. "
            "Run scripts/build-pack.py --check and commit the generated files."
        )
    return {
        "sourceCommit": commit,
        "sourceCommitRole": role,
        "sourceTreeSha256": tree_hash,
        "verified": True,
    }


def build() -> dict:
    audit = read_json(ROOT / "manifest" / "skill-audit.json")
    agents = read_json(ROOT / "manifest" / "agent-audit.json")
    skill_names = read_manifest(ROOT / "manifest" / "imported-skills.txt")
    audit_names = [item["id"] for item in audit["skills"]]
    if len(skill_names) != 50 or set(skill_names) != set(audit_names):
        raise SystemExit(f"Skill audit mismatch: manifest={len(skill_names)}, audit={len(audit_names)}")
    if set(item["status"] for item in audit["skills"]) - STATUSES:
        raise SystemExit("Unknown compatibility status in skill audit")
    validate_sources(skill_names, audit, agents)
    if PACK.exists():
        if PACK.parent != ROOT or PACK.name != "installer-pack":
            raise SystemExit("Refusing to recreate an unexpected pack path")
        shutil.rmtree(PACK)
    (PACK / "skills").mkdir(parents=True)
    (PACK / "agents").mkdir(parents=True)
    (PACK / "mcp").mkdir(parents=True)
    (PACK / "manifest").mkdir(parents=True)
    (PACK / "runtime").mkdir(parents=True)
    (PACK / "config-fragments").mkdir(parents=True)
    (PACK / "docs").mkdir(parents=True)
    for agent in sorted((ROOT / "agents").glob("*.toml")):
        shutil.copy2(agent, PACK / "agents" / agent.name)
    for name in skill_names:
        source = ROOT / "skills" / name
        if not (source / "SKILL.md").is_file():
            raise SystemExit(f"Missing SKILL.md: {name}")
        safe_copy_tree(source, PACK / "skills" / name)
    safe_copy_tree(ROOT / "runtime", PACK / "runtime")
    safe_copy_tree(ROOT / "config-fragments", PACK / "config-fragments")
    for runtime_script in ["materialize-python-wheelhouse.py", "materialize-python-wheelhouse.ps1"]:
        shutil.copy2(ROOT / "scripts" / runtime_script, PACK / "runtime" / runtime_script)
    for source_name, destination in [
        ("install-to-codex.ps1", PACK / "install-to-codex.ps1"),
        ("render-codex-config.ps1", PACK / "render-codex-config.ps1"),
        ("configure-codex.ps1", PACK / "configure-codex.ps1"),
        ("install-all.ps1", PACK / "install-all.ps1"),
        ("Install-Codex-Starter.cmd", PACK / "Install-Codex-Starter.cmd"),
        ("audit-codex-compatibility.py", PACK / "audit-codex-compatibility.py"),
        ("test-adapter-contracts.py", PACK / "test-adapter-contracts.py"),
        ("start-feishu-mcp.ps1", PACK / "mcp" / "start-feishu-mcp.ps1"),
    ]:
        shutil.copy2(ROOT / "scripts" / source_name, destination)
    for relative in ["README.md", "ENVIRONMENT-MCP-INVENTORY.md"]:
        shutil.copy2(ROOT / relative, PACK / relative)
    for doc_name in [
        "CODEX-ADAPTATION-DEVELOPMENT.md",
        "KNOWN-LIMITATIONS.md",
        "POST-MERGE-CORRECTIVE-DEVELOPMENT.md",
        "FULL-BUNDLE-ONE-CLICK-DEVELOPMENT.md",
    ]:
        shutil.copy2(ROOT / "docs" / doc_name, PACK / "docs" / doc_name)
    for relative in [
        "imported-skills.txt", "agents.txt", "agent-catalog.md", "source-notes.md",
        "skill-audit.json", "agent-audit.json", "runtime-artifacts.json",
        "mcp-servers.json", "api-services.json", "connection-fields.json",
        "feishu-mcp-research.md", "feishu-tools.json",
    ]:
        shutil.copy2(ROOT / "manifest" / relative, PACK / "manifest" / relative)
    write_json(PACK / "mcp" / "mcp-servers.json", read_json(ROOT / "manifest" / "mcp-servers.json"))
    write_json(PACK / "mcp" / "api-services.json", read_json(ROOT / "manifest" / "api-services.json"))
    write_json(PACK / "mcp" / "connection-fields.json", read_json(ROOT / "manifest" / "connection-fields.json"))
    (PACK / "mcp" / "README.md").write_text(
        "# External connection inventory\n\n"
        "`mcp-servers.json` describes MCP servers, while `api-services.json` describes direct HTTP/API services.\n"
        "`connection-fields.json` is the guided-configuration form contract. Real credentials and generated\n"
        "Codex configuration stay outside this public pack. `start-feishu-mcp.ps1` is an offline-only,\n"
        "redacting wrapper whose tool allowlist is locked by `../manifest/feishu-tools.json`.\n",
        encoding="utf-8", newline="\n"
    )
    for template in (ROOT / "manifest").glob("*.template.*"):
        shutil.copy2(template, PACK / "mcp" / template.name)
    default_skills = [item["id"] for item in audit["skills"] if item.get("installByDefault")]
    default_agents = [f"agents/{item['file']}" for item in agents["agents"]]
    commit = source_commit()
    tree_hash = source_tree_sha256()
    pack_manifest = {
        "schemaVersion": 2,
        "id": PACK_ID,
        "version": PACK_VERSION,
        "sourceCommit": commit,
        "sourceCommitRole": source_commit_role(),
        "sourceTreeSha256": tree_hash,
        "sourceDate": "2026-09-08",
        "compatibleCodex": {
            "minCodexVersion": MIN_CODEX_VERSION,
            "testedCodexVersion": TESTED_CODEX_VERSION,
            "agentFormat":"TOML with name/description/developer_instructions",
            "skillRoot":"%USERPROFILE%\\.agents\\skills",
            "agentRoot":"%USERPROFILE%\\.codex\\agents",
            "windows":["10","11"]
        },
        "statuses": sorted(PACK_STATUSES),
        "sourceStatuses": sorted(STATUSES),
        "defaultEnabled": {"skills": default_skills, "agents": default_agents},
        "sourcePolicy": {"noSecrets":True,"noUserContent":True,"bundledRuntimeMedia":True,"noUserRuntimeCache":True,"ownedFilesOnly":True,"noGlobalAgentsMd":True},
        "installOrder": [
            "verify-package-hashes", "install-approved-runtimes", "install-default-skills",
            "install-all-agents", "render-private-connections", "health-check", "reload-codex"
        ],
        "conflictStrategy": {
            "ownedFilesOnly": True,
            "skipUnlessOverwrite": True,
            "neverDeleteUnowned": True,
            "neverWriteGlobalAgentsMd": True
        },
        "extensionContract": {
            "schemaVersion": 2,
            "skill":"add manifest entry, skills/<id>/SKILL.md and optional skills/<id>/agents/openai.yaml; rerun builder",
            "agent":"add agents/<id>.toml and a matching manifest/agent-audit.json closure; rerun builder",
            "mcp":"add manifest/mcp-servers.json entry and a secret-free config-fragments template; keep credentials local",
            "apiService":"add manifest/api-services.json and connection-fields.json entries; never commit keys",
            "runtime":"add a pinned artifact record and an auditable offline manifest; do not bundle unverified binaries",
            "configFragment":"add a secret-free template with enable/disable and health-check rules"
        },
        "runtimeArtifacts": "manifest/runtime-artifacts.json",
        "mcpServers": "mcp/mcp-servers.json",
        "apiServices": "mcp/api-services.json",
        "connectionFields": "mcp/connection-fields.json",
        "compatibilityAudit": "audit-codex-compatibility.py",
        "adapterContractTests": "test-adapter-contracts.py",
        "configRenderer": "render-codex-config.ps1",
        "installer": "install-to-codex.ps1",
    }
    write_json(PACK / "pack.json", pack_manifest)
    write_json(PACK / "dependencies.json", build_dependencies(audit, agents))
    manifest = []
    for path in pack_files():
        relative = path.relative_to(PACK).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.append({"path":relative,"sha256":digest,"bytes":path.stat().st_size,"owned":True})
    write_json(PACK / "file-manifest.json", {"schemaVersion":2,"id":PACK_ID,"version":PACK_VERSION,"hashScope":"all pack files except file-manifest.json and checksums.sha256","files":manifest})
    (PACK / "checksums.sha256").write_text("\n".join(checksum_lines()) + "\n", encoding="utf-8", newline="\n")
    return {"skills":len(skill_names),"agents":len(default_agents),"defaultSkills":len(default_skills),"files":len(pack_files()),"sourceCommit":commit,"sourceTreeSha256":tree_hash}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="build the pack and print a summary")
    parser.add_argument("--verify", action="store_true", help="verify pack provenance without rebuilding")
    args = parser.parse_args()
    if args.check and args.verify:
        parser.error("--check and --verify are mutually exclusive")
    if args.verify:
        print(json.dumps(verify_pack_provenance(), ensure_ascii=False))
        return
    result = build()
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
