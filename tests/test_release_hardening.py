"""Release boundaries that must remain fail-closed."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

from artifact_audit import audit_path, audit_tree, audit_zip, inspect_bytes


def load_release_smoke(project_root: Path):
    spec = importlib.util.spec_from_file_location(
        "release_smoke_hardening",
        project_root / "scripts/release_smoke.py",
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_release_uses_template_and_excludes_user_config(project_root):
    module = load_release_smoke(project_root)
    release_files = set(module.WINDOWS_FILES + module.MACOS_FILES)

    assert "data/config.example.json" in release_files
    assert "data/config.json" not in release_files
    assert "/data/config.json" in (project_root / ".gitignore").read_text(encoding="utf-8")
    template = json.loads(
        (project_root / "data/config.example.json").read_text(encoding="utf-8")
    )
    assert template["virustotal"]["enabled"] is False
    assert template["virustotal"]["apiKey"] == ""


def test_release_manifest_uses_portable_artifact_name(project_root, tmp_path, monkeypatch):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    archive = module.build_zip("portable", ["LICENSE"], executable_entries=set())

    metadata = module.validate_zip(archive)

    assert metadata["file"] == "portable.zip"
    assert str(project_root) not in json.dumps(metadata)


def test_release_zip_refuses_to_overwrite_existing_artifact(project_root, tmp_path, monkeypatch):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    destination = tmp_path / "portable.zip"
    destination.write_bytes(b"sentinel")

    with pytest.raises(FileExistsError):
        module.build_zip("portable", ["LICENSE"], executable_entries=set())

    assert destination.read_bytes() == b"sentinel"


def test_release_source_state_contains_no_checkout_path(project_root):
    module = load_release_smoke(project_root)
    state = module.source_state("0.3.0")

    assert set(state) == {"repository", "commit", "tag", "clean"}
    assert str(project_root) not in json.dumps(state)


def test_artifact_audit_rejects_secret_and_real_home_path():
    secret = inspect_bytes(
        "config.json",
        b'{"api' + b'Key": "not-a-placeholder-token"}',
    )
    personal_path = inspect_bytes("binary", b"/Users/" + b"privateperson/Projects/product")

    assert {finding.rule for finding in secret} == {"assigned-secret"}
    assert {finding.rule for finding in personal_path} == {"local-user-path"}
    assert not inspect_bytes("fixture", b"/Users/sample/Library/Caches")


def test_artifact_audit_rejects_common_private_keys_tokens_and_unquoted_secrets():
    samples = {
        "private-key": b"-----BEGIN " + b"RSA PRIVATE KEY-----\nmaterial",
        "slack-token": b"xox" + b"b-123456789012-abcdefghijklmnop",
        "assigned-secret": b"PASS" + b"WORD=" + b"definitely_real_password",
    }

    for expected, payload in samples.items():
        rules = {finding.rule for finding in inspect_bytes("secret", payload)}
        assert expected in rules


def test_artifact_tree_rejects_symlink_except_dmg_applications(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "safe.txt").write_text("Heznpc", encoding="utf-8")
    (payload / "escape").symlink_to("/tmp")

    findings = audit_tree(payload, allowed_symlinks=set())
    assert any(item.rule == "symlink" and item.entry == "escape" for item in findings)

    (payload / "escape").unlink()
    (payload / "Applications").symlink_to("/Applications")
    assert not audit_tree(payload, allowed_symlinks={"Applications"})


def test_artifact_tree_rejects_extended_attributes(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    target = payload / "safe.txt"
    target.write_text("Heznpc", encoding="utf-8")
    attribute = "com.heznpc.audit-test" if sys.platform == "darwin" else "user.heznpc-audit-test"
    try:
        if sys.platform == "darwin":
            subprocess.run(
                ["/usr/bin/xattr", "-w", attribute, "sk-" + "a" * 32, str(target)],
                check=True,
            )
        else:
            os.setxattr(target, attribute, b"sk-" + b"a" * 32)
    except (AttributeError, OSError):
        pytest.skip("extended attributes are unavailable on this filesystem")

    rules = {finding.rule for finding in audit_tree(payload, allowed_symlinks=set())}
    assert "extended-attribute" in rules
    assert "openai-token" in rules


def test_artifact_zip_rejects_traversal_and_symlink(tmp_path):
    archive_path = tmp_path / "unsafe.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("../escape.txt", "unsafe")
        symlink = zipfile.ZipInfo("root/link")
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(symlink, "/tmp")

    rules = {finding.rule for finding in audit_zip(archive_path)}
    assert "unsafe-path" in rules
    assert "symlink" in rules


def test_artifact_zip_rejects_hidden_member_metadata(tmp_path):
    archive_path = tmp_path / "metadata.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        info = zipfile.ZipInfo("root/file.txt")
        info.extra = b"\x99\x99\x04\x00test"
        archive.writestr(info, "safe")

    assert "zip-extra" in {finding.rule for finding in audit_zip(archive_path)}


def test_artifact_audit_rejects_symlink_root_file(tmp_path):
    target = tmp_path / "target.txt"
    target.write_text("safe", encoding="utf-8")
    link = tmp_path / "artifact.zip"
    link.symlink_to(target)

    assert {finding.rule for finding in audit_path(link, set())} == {"symlink-root"}


def test_mac_builder_embeds_release_identity_without_local_path(project_root):
    source = (project_root / "scripts/build_macos_swift_app.sh").read_text(
        encoding="utf-8"
    )

    assert "-file-prefix-map" in source
    assert "-debug-prefix-map" in source
    assert "-strict-concurrency=complete" in source
    assert "x86_64-apple-macosx" not in source  # triples are assembled from validated input
    assert '"data/config.example.json"' in source
    assert '"data/config.json"' not in source
    assert "build_macos_icon.sh" in source
    assert 'Contents/Resources/LICENSE' in source
    assert "CFBundleIconFile" in source
    assert "project-root.txt" not in source


def test_mac_packager_separates_local_and_public_trust(project_root):
    source = (project_root / "scripts/package_macos_release.sh").read_text(
        encoding="utf-8"
    )

    assert 'expected_tag="v$VERSION"' in source
    assert "distribution requires a clean worktree and index" in source
    assert 'output_dir="$DIST_DIR/local"' in source
    assert "refusing to overwrite an existing artifact" in source
    assert "artifact_audit.py" in source
    assert "vtool -show-build" in source
    assert "notarytool submit" in source
    assert "stapler validate" in source
    assert "gatekeeperAssessed" in source
    assert "LICENSE" in source
    assert "-ov" not in source
    assert "git -C \"$ROOT_DIR\" archive" in source
    assert "PCH_BUILD_DIR=$PACKAGE_BUILD_DIR" in source
    assert "/bin/ln \"$WORK_DMG_PATH\" \"$DMG_PATH\"" in source


def test_scanners_resolve_ignored_or_user_config_before_template(project_root):
    mac = (project_root / "scripts/scanner.sh").read_text(encoding="utf-8")
    windows = (project_root / "scripts/scanner.ps1").read_text(encoding="utf-8-sig")

    for source in (mac, windows):
        assert "config.example.json" in source
        assert "config.json" in source
    assert "Library/Application Support/PC Health Check/config.json" in mac
    assert mac.index("Library/Application Support/PC Health Check/config.json") < mac.index(
        "${PROJECT_DIR}/data/config.json"
    )
    assert "LOCALAPPDATA" in windows
