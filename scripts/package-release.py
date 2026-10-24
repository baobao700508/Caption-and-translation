#!/usr/bin/env python3
"""将已通过发布检查的 App 打包为 GitHub Release 与 Sparkle 签名更新源。"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from release import ROOT, digest, info, source_manifest

REPOSITORY = "https://github.com/baobao700508/Caption-and-translation"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", required=True, type=Path, help="面向用户的中文发布说明文件")
    parser.add_argument("--key-file", type=Path, default=Path.home() / "Library/Application Support/LiveCaptionRelease/ed25519.key")
    args = parser.parse_args()
    key = args.key_file.expanduser().resolve()
    if not key.is_file() or key.stat().st_mode & 0o077:
        raise SystemExit("需要仅当前用户可读写的本机更新私钥文件（权限 600），不查询钥匙串。")
    manifest = json.loads((ROOT / "Releases/current.json").read_text())
    app = ROOT / "dist/LiveCaption.app"
    metadata = info(app)
    version, build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
    if (version, build) != (manifest["version"], manifest["build"]):
        raise SystemExit("App 与发布记录版本不一致。")
    if digest(app / "Contents/MacOS/LiveCaption") != manifest["binary_sha256"]:
        raise SystemExit("App 与通过检查的可执行文件不一致。")
    if source_manifest() != json.loads(Path(manifest["source_manifest"]).read_text()):
        raise SystemExit("源码在发布检查后发生变化，请重新构建验证。")
    notes = args.notes.read_text().strip()
    if not notes:
        raise SystemExit("发布说明不能为空。")
    tools = ROOT / os.environ.get("LIVECAPTION_BUILD_PATH", ".build-selected-toolchain") / "artifacts/sparkle/Sparkle/bin"
    tag = f"v{version}-build{build}"
    output = ROOT / "Releases/GitHub" / tag
    output.mkdir(parents=True, exist_ok=False)
    archive = output / f"LiveCaption-{version}-build{build}-arm64.zip"
    run("codesign", "--verify", "--deep", "--strict", app)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    archive.with_suffix(".html").write_text("<p>" + html.escape(notes).replace("\n", "<br>") + "</p>\n")
    run(tools / "generate_appcast", "--ed-key-file", key, "--maximum-deltas", "0",
        "--download-url-prefix", f"{REPOSITORY}/releases/download/{tag}/", output)
    feed = output / "appcast.xml"
    item = ET.parse(feed).find("channel/item")
    if item is None or item.findtext(f"{{{SPARKLE}}}version") != build:
        raise SystemExit("更新源没有包含正确构建号。")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != f"{REPOSITORY}/releases/download/{tag}/{archive.name}":
        raise SystemExit("更新源下载地址不匹配。")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise SystemExit("更新源的文件长度不匹配。")
    run(tools / "sign_update", "--ed-key-file", key, "--verify", archive, enclosure.get(f"{{{SPARKLE}}}edSignature", ""))
    run(tools / "sign_update", "--ed-key-file", key, "--verify", feed)
    checksum = archive.with_suffix(".zip.sha256")
    checksum.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
    (output / "release-notes.md").write_text(notes + "\n")
    result = dict(tag=tag, version=version, build=build, repository=REPOSITORY,
                  assets=[str(p) for p in (archive, checksum, feed)],
                  notes=str(output / "release-notes.md"))
    (output / "github-release.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"已生成并验证更新包与签名更新源：{output}")


if __name__ == "__main__":
    main()
