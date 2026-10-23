#!/usr/bin/env python3
"""将当前 Sources 与指定 Git 基线做 Swift 语法树及桥接源码对照。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", help="基线 commit 或 tag")
args = parser.parse_args()
subprocess.run(["git", "rev-parse", "--verify", args.baseline + "^{commit}"], cwd=root, check=True, stdout=subprocess.DEVNULL)
toolchain = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()).parent.parent
host = toolchain / "lib/swift/host"
cache = root / ".tools/source-refactor-check"
cache.mkdir(parents=True, exist_ok=True)
checker = cache / "verify-source-refactor"
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
subprocess.run([str(toolchain / "bin/swiftc"), "-sdk", sdk, "-I", str(host), "-L", str(host), "-Xlinker", "-rpath", "-Xlinker", str(host), str(root / "scripts/verify-source-refactor.swift"), "-o", str(checker)], check=True)
with tempfile.TemporaryDirectory(prefix="source-refactor-") as scratch:
    before = Path(scratch)
    archive = subprocess.Popen(["git", "archive", args.baseline, "Sources", "Tests"], cwd=root, stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", scratch], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait():
        raise SystemExit("无法读取 Git 基线")
    comparison = subprocess.run([str(checker), str(before / "Sources"), str(root / "Sources")], capture_output=True, text=True, check=False)
    result = json.loads(comparison.stdout)
    # C/C++ 桥接和已有测试逐字节不变。
    unchanged = []
    for path in (before / "Sources").rglob("*"):
        if path.is_file() and path.suffix in {".c", ".cc", ".h", ".mm"}:
            relative = path.relative_to(before)
            unchanged.append(path.read_bytes() == (root / relative).read_bytes())
    for path in (before / "Tests").rglob("*"):
        if path.is_file():
            unchanged.append(path.read_bytes() == (root / path.relative_to(before)).read_bytes())
    # #filePath 参与 SaT 的开发态 worker 定位，文件可改名但目录深度不能变。
    macro_depths = lambda base: sorted(len(p.relative_to(base).parts) for p in (base / "Sources").rglob("*.swift") if "#filePath" in p.read_text())
    result["source_relative_resource_depth_unchanged"] = macro_depths(before) == macro_depths(root)
    result["bridge_and_existing_tests_byte_identical"] = all(unchanged)
    result["baseline"] = args.baseline
    result["success"] = result["success"] and all(unchanged) and result["source_relative_resource_depth_unchanged"]
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result["success"] else 1)
