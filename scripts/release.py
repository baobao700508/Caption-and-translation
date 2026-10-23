#!/usr/bin/env python3
"""Validate one source tree and publish one canonical, traceable macOS bundle."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_manifest():
    paths = [ROOT / name for name in ("Package.swift", "Package.resolved", "AGENTS.md")]
    for name in ("Sources", "Tests", "Resources", "scripts"):
        paths.extend(p for p in (ROOT / name).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts and p.name != ".DS_Store")
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def run(command, log=None, env=None, timeout=None):
    if log:
        print(f"执行：{' '.join(map(str, command))}；日志：{log}", flush=True)
        with log.open("w") as stream:
            subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True, timeout=timeout)
    else:
        subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


def running_apps():
    result = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    return [line.strip() for line in result.splitlines()
            if line.strip().endswith("/Contents/MacOS/LiveCaption")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--activate", action="store_true", help="发布后从桌面入口打开")
    parser.add_argument("--archive-legacy", action="store_true", help="归档 dist 内独立旧包")
    args = parser.parse_args()
    os.chdir(ROOT)
    releases = ROOT / "Releases"
    releases.mkdir(exist_ok=True)
    with (releases / ".publish.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("另一个发布任务正在运行，未修改现有 App。")
        source = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        version, build = source["CFBundleShortVersionString"], source["CFBundleVersion"]
        if not build.isdecimal():
            raise SystemExit("正式 build 必须是递增整数，请只修改 Resources/Info.plist。")
        previous = releases / "current.json"
        if previous.exists() and int(build) <= int(json.loads(previous.read_text())["build"]):
            raise SystemExit("build 未递增，拒绝覆盖现有正式版本。")
        stamp = time.strftime("%Y%m%d-%H%M%S")
        evidence = ROOT / "TestResults" / f"release-{version}-{build}-{stamp}"
        evidence.mkdir(parents=True)
        before = source_manifest()
        (evidence / "source-manifest.json").write_text(json.dumps(before, indent=2) + "\n")
        env = os.environ.copy()
        env.setdefault("LIVECAPTION_BUILD_PATH", ".build-selected-toolchain")
        sat_python = Path.home() / "Library/Application Support/LiveCaption/SaT/runtime/bin/python3"
        if sat_python.exists():
            env["LIVECAPTION_SAT_TEST_PYTHON"] = str(sat_python)
        run(["bash", "scripts/check.sh"], evidence / "checks.log", env)
        with tempfile.TemporaryDirectory(prefix=".stage-", dir=releases) as stage:
            app = Path(stage) / "LiveCaption.app"
            env["LIVECAPTION_APP_PATH"] = str(app)
            run(["bash", "scripts/build.sh"], evidence / "build.log", env)
            run(["codesign", "--verify", "--deep", "--strict", str(app)])
            if running_apps():
                raise SystemExit("仍有 LiveCaption 实例运行，未开始界面检查或替换文件。")
            # Execute the copied bundle directly, preserving its exact signed
            # executable. InterfaceSmoke disables preference writes and capture.
            check_app = Path(stage) / "InterfaceCheck.app"
            run(["ditto", str(app), str(check_app)])
            result = evidence / "interface.json"
            run([str(check_app / "Contents/MacOS/LiveCaption"), "--verify-interface",
                 str(result), "--verification-exit"], evidence / "interface.log", timeout=90)
            if not json.loads(result.read_text()).get("success"):
                raise SystemExit(f"原生界面检查失败，未发布；查看 {result}")
            if digest(check_app / "Contents/MacOS/LiveCaption") != digest(app / "Contents/MacOS/LiveCaption"):
                raise SystemExit("测试程序与待发布程序不一致，未发布。")
            if source_manifest() != before:
                raise SystemExit("验证期间源码发生变化，未发布；请合并后重新运行。")
            if running_apps():
                raise SystemExit("仍有 LiveCaption 实例运行，未替换文件；退出后重新发布。")
            actual = info(app)
            if (actual["CFBundleShortVersionString"], actual["CFBundleVersion"]) != (version, build):
                raise SystemExit("源码与构建版本不一致，未发布。")
            canonical = ROOT / "dist/LiveCaption.app"
            desktop = Path.home() / "Desktop/LiveCaption.app"
            if desktop.exists() and not desktop.is_symlink():
                raise SystemExit("桌面入口不是快捷方式，未替换；需先确认该文件的用途。")
            archive = releases / "Archive" / stamp
            archive.mkdir(parents=True)
            archived = []
            if canonical.exists():
                old = info(canonical)
                destination = archive / f"LiveCaption-{old['CFBundleShortVersionString']}-{old['CFBundleVersion']}.app"
                canonical.rename(destination)
                archived.append(str(destination))
            canonical.parent.mkdir(exist_ok=True)
            try:
                app.rename(canonical)
            except BaseException:
                if archived:
                    Path(archived[0]).rename(canonical)
                raise
            if args.archive_legacy:
                for old in sorted(canonical.parent.glob("*.app")):
                    if old != canonical:
                        destination = archive / old.name
                        old.rename(destination)
                        archived.append(str(destination))
            temp_link = desktop.with_name(".LiveCaption-release.app")
            if temp_link.is_symlink():
                temp_link.unlink()
            temp_link.symlink_to(canonical)
            temp_link.replace(desktop)
            manifest = {"version": version, "build": build, "published_at": stamp,
                        "app_path": str(canonical), "desktop_path": str(desktop),
                        "binary_sha256": digest(canonical / "Contents/MacOS/LiveCaption"),
                        "source_manifest": str(evidence / "source-manifest.json"),
                        "checks_log": str(evidence / "checks.log"), "interface_result": str(result),
                        "archived_apps": archived,
                        "included": ["Immediate persisted reflow switch; stale work rejected", "SaT-only local segmentation; automatic parameter saving; provider groups when disabled", "Google stop finalization",
                                     "WhisperKit", "default Tina voice; cloning disabled", "speaker ID logging", "text-only translation",
                                     "WebSocket playback catch-up"]}
            (evidence / "release.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            pending_manifest = releases / ".current.json.tmp"
            pending_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            pending_manifest.replace(previous)
            if args.activate:
                run(["open", str(desktop)])
                for _ in range(40):
                    if any(line.endswith(str(canonical / "Contents/MacOS/LiveCaption")) for line in running_apps()):
                        break
                    time.sleep(.25)
                else:
                    raise SystemExit("发布完成，但尚未确认新进程启动。")
            print(f"已发布 {version}（build {build}）：{canonical}\n发布记录：{previous}", flush=True)


if __name__ == "__main__":
    main()
