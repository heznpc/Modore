"""Release boundaries that must remain fail-closed."""

from __future__ import annotations

import ast
import importlib.util
import hashlib
import json
import os
import re
import signal
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time
import zipfile
from contextlib import nullcontext
from pathlib import Path

import pytest

from artifact_audit import (
    PYTHON_RUNTIME_ORIGIN,
    audit_path,
    audit_tree,
    audit_zip,
    inspect_bytes,
)


def load_release_smoke(project_root: Path):
    spec = importlib.util.spec_from_file_location(
        "release_smoke_hardening",
        project_root / "scripts/release_smoke.py",
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_release_refuses_forbidden_named_entry(project_root, tmp_path, monkeypatch):
    """The allowlist gate rejects a forbidden artifact even if it exists on disk."""
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "PROJECT_ROOT", tmp_path)
    (tmp_path / "config.json").write_text("{}", encoding="utf-8")

    with pytest.raises(ValueError, match="forbidden"):
        module.assert_clean_file_list(["config.json"])


def test_source_audit_flags_real_secret_but_not_bracketed_placeholder():
    """inspect_bytes catches an assigned credential that merely contains '<',
    while a fully bracketed <TEMPLATE> is treated as a placeholder."""
    assert inspect_bytes("x.env", b'api_key = "S3cr<t!value99"'), "real secret must be flagged"
    assert not inspect_bytes("x.env", b'api_key = "<YOUR_KEY>"'), "bracketed template is a placeholder"


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
    assert not list(tmp_path.glob(".pch-release-recovery.*"))


def test_release_zip_refuses_to_overwrite_existing_artifact(project_root, tmp_path, monkeypatch):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    destination = tmp_path / "portable.zip"
    destination.write_bytes(b"sentinel")

    with pytest.raises(FileExistsError):
        module.build_zip("portable", ["LICENSE"], executable_entries=set())

    assert destination.read_bytes() == b"sentinel"


def test_release_zip_never_publishes_a_replaced_staging_entry(
    project_root, tmp_path, monkeypatch
):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    real_link = os.link

    def replace_source_before_link(source, destination, *, follow_symlinks=True):
        source_path = Path(source)
        source_path.rename(source_path.with_name(source_path.name + ".audited"))
        source_path.write_bytes(b"not-the-audited-zip")
        return real_link(
            source_path,
            destination,
            follow_symlinks=follow_symlinks,
        )

    monkeypatch.setattr(module.os, "link", replace_source_before_link)

    with pytest.raises(RuntimeError, match="audited"):
        module.build_zip("portable", ["LICENSE"], executable_entries=set())

    assert not (tmp_path / "portable.zip").exists()


def test_release_zip_writes_through_the_mkstemp_descriptor_not_its_path(
    project_root, tmp_path, monkeypatch
):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    victim = tmp_path / "victim.txt"
    victim.write_bytes(b"preserve-user-bytes")
    real_mkstemp = module.tempfile.mkstemp

    def replace_staging_name(*args, **kwargs):
        descriptor, raw_path = real_mkstemp(*args, **kwargs)
        path = Path(raw_path)
        path.unlink()
        path.symlink_to(victim)
        return descriptor, raw_path

    monkeypatch.setattr(module.tempfile, "mkstemp", replace_staging_name)

    with pytest.raises(RuntimeError, match="audited snapshot"):
        module.build_zip("portable", ["LICENSE"], executable_entries=set())

    assert victim.read_bytes() == b"preserve-user-bytes"
    assert not (tmp_path / "portable.zip").exists()


def test_release_recovery_rename_never_replaces_an_existing_entry(
    project_root, tmp_path
):
    module = load_release_smoke(project_root)
    if os.name == "nt":
        pytest.skip("dirfd rename helper is POSIX-only")
    source_directory = tmp_path / "source"
    recovery_directory = tmp_path / "recovery"
    source_directory.mkdir()
    recovery_directory.mkdir()
    (source_directory / "artifact.zip").write_bytes(b"audited")
    (recovery_directory / "artifact.zip").write_bytes(b"existing-user-file")
    flags = os.O_RDONLY | os.O_DIRECTORY
    source_descriptor = os.open(source_directory, flags)
    recovery_descriptor = os.open(recovery_directory, flags)
    try:
        with pytest.raises(FileExistsError):
            module.rename_entry_noreplace(
                source_descriptor,
                "artifact.zip",
                recovery_descriptor,
                "artifact.zip",
            )
    finally:
        os.close(recovery_descriptor)
        os.close(source_descriptor)

    assert (source_directory / "artifact.zip").read_bytes() == b"audited"
    assert (recovery_directory / "artifact.zip").read_bytes() == b"existing-user-file"


def test_release_recovery_cleanup_refuses_a_replaced_entry(project_root, tmp_path):
    module = load_release_smoke(project_root)
    source = tmp_path / "artifact.zip"
    same_inode = tmp_path / "same-inode.zip"
    source.write_bytes(b"audited")
    os.link(source, same_inode)
    audited_seal = module.seal_regular_file(source)
    expected_entry = module.FileEntryIdentity(
        audited_seal.device,
        audited_seal.inode,
        stat.S_IFREG,
    )
    matches, recovery = module.preserve_entry_for_review(source, expected_entry)
    assert matches is True
    assert recovery is not None
    recovery.unlink()
    os.link(same_inode, recovery)
    recovery.write_bytes(b"replacement")
    assert module.file_entry_identity(recovery) == expected_entry

    with pytest.raises(RuntimeError, match="changed before cleanup"):
        module.discard_preserved_entry(recovery, audited_seal)

    assert recovery.read_bytes() == b"replacement"


def test_release_source_state_contains_no_checkout_path(project_root):
    module = load_release_smoke(project_root)
    state = module.source_state("0.3.0")

    assert set(state) == {
        "repository",
        "commit",
        "tag",
        "tagObjectID",
        "tagSignatureVerified",
        "tagSignerPrincipal",
        "tagSignerFingerprint",
        "clean",
    }
    assert str(project_root) not in json.dumps(state)


def test_release_source_state_verifies_exact_annotated_tag(project_root, monkeypatch):
    module = load_release_smoke(project_root)
    commit = "a" * 40
    tag_object_id = "d" * 40
    signer_fingerprint = "SHA256:" + "A" * 43
    signer = module.ReleaseSigner(
        principal="heznpc",
        fingerprint=signer_fingerprint,
        public_key="ssh-ed25519 " + "A" * 68,
    )
    calls = []
    responses = {
        ("rev-parse", "--is-inside-work-tree"): (0, "true\n"),
        ("replace", "-l"): (0, ""),
        ("rev-parse", "HEAD"): (0, f"{commit}\n"),
        ("status", "--porcelain", "--untracked-files=all"): (0, ""),
        (
            "rev-parse",
            "--verify",
            "refs/tags/v0.3.0",
        ): (0, f"{tag_object_id}\n"),
        (
            "rev-parse",
            "--verify",
            f"{tag_object_id}^{{commit}}",
        ): (0, f"{commit}\n"),
        ("cat-file", "-t", tag_object_id): (0, "tag\n"),
    }

    def fake_run_git(*arguments, text=False, check=False):
        calls.append(arguments)
        returncode, stdout = responses[arguments]
        return subprocess.CompletedProcess(arguments, returncode, stdout=stdout, stderr="")

    monkeypatch.setattr(module, "GIT_EXECUTABLE", Path("/fixed/system/git"))
    monkeypatch.setattr(module, "run_git", fake_run_git)
    monkeypatch.setattr(module, "trusted_release_signer", lambda: nullcontext(signer))
    verified_tags = []
    monkeypatch.setattr(
        module,
        "verify_tag_with_signer",
        lambda object_id, actual_signer: verified_tags.append(
            (object_id, actual_signer)
        )
        is None,
    )

    state = module.source_state("0.3.0")

    assert state == {
        "repository": True,
        "commit": commit,
        "tag": "v0.3.0",
        "tagObjectID": tag_object_id,
        "tagSignatureVerified": True,
        "tagSignerPrincipal": "heznpc",
        "tagSignerFingerprint": signer_fingerprint,
        "clean": True,
    }
    assert verified_tags == [(tag_object_id, signer)]
    assert calls.count(("rev-parse", "--verify", "refs/tags/v0.3.0")) == 1
    assert not any(
        "refs/tags/v0.3.0" in argument
        for call in calls
        if call != ("rev-parse", "--verify", "refs/tags/v0.3.0")
        for argument in call
    )


def test_release_source_state_rejects_lightweight_tag_signature(
    project_root, monkeypatch
):
    module = load_release_smoke(project_root)
    commit = "b" * 40
    responses = {
        ("rev-parse", "--is-inside-work-tree"): (0, "true\n"),
        ("replace", "-l"): (0, ""),
        ("rev-parse", "HEAD"): (0, f"{commit}\n"),
        ("status", "--porcelain", "--untracked-files=all"): (0, ""),
        (
            "rev-parse",
            "--verify",
            "refs/tags/v0.3.0",
        ): (0, f"{commit}\n"),
        (
            "rev-parse",
            "--verify",
            f"{commit}^{{commit}}",
        ): (0, f"{commit}\n"),
        ("cat-file", "-t", commit): (0, "commit\n"),
    }

    def fake_run_git(*arguments, text=False, check=False):
        returncode, stdout = responses[arguments]
        return subprocess.CompletedProcess(arguments, returncode, stdout=stdout, stderr="")

    monkeypatch.setattr(module, "GIT_EXECUTABLE", Path("/fixed/system/git"))
    monkeypatch.setattr(module, "run_git", fake_run_git)
    monkeypatch.setattr(module, "trusted_release_signer", lambda: nullcontext(None))

    state = module.source_state("0.3.0")

    assert state["tag"] == "v0.3.0"
    assert state["tagObjectID"] == commit
    assert state["tagSignatureVerified"] is False


def test_release_mode_requires_verified_signed_annotated_tag(
    project_root, monkeypatch
):
    module = load_release_smoke(project_root)
    monkeypatch.setattr(
        module,
        "source_state",
        lambda _version: {
            "repository": True,
            "commit": "c" * 40,
            "tag": "v0.3.0",
            "tagObjectID": "d" * 40,
            "tagSignatureVerified": False,
            "tagSignerPrincipal": None,
            "tagSignerFingerprint": None,
            "clean": True,
        },
    )
    monkeypatch.setattr(sys, "argv", ["release_smoke.py", "--release"])
    monkeypatch.setattr(module, "python_is_isolated", lambda: True)
    monkeypatch.setattr(module, "release_signer_environment_is_complete", lambda: True)

    with pytest.raises(RuntimeError, match="verified signed annotated"):
        module.main()


def test_release_mode_rejects_tag_object_swap_during_build(
    project_root, tmp_path, monkeypatch
):
    module = load_release_smoke(project_root)
    before = {
        "repository": True,
        "commit": "c" * 40,
        "tag": "v0.3.0",
        "tagObjectID": "d" * 40,
        "tagSignatureVerified": True,
        "tagSignerPrincipal": "heznpc",
        "tagSignerFingerprint": "SHA256:" + "A" * 43,
        "clean": True,
    }
    after = {**before, "tagObjectID": "e" * 40}
    states = iter((before, after))

    def fake_build_zip(name, *_args, output_dir, **_kwargs):
        output_dir.mkdir(parents=True, exist_ok=True)
        destination = output_dir / f"{name}.zip"
        destination.write_bytes(b"temporary test archive")
        return destination

    monkeypatch.setattr(module, "DIST_DIR", tmp_path)
    monkeypatch.setattr(module, "source_state", lambda _version: next(states))
    monkeypatch.setattr(module, "swift_files_from_commit", lambda _commit: [])
    monkeypatch.setattr(module, "assert_clean_file_list", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "build_zip", fake_build_zip)
    monkeypatch.setattr(sys, "argv", ["release_smoke.py", "--release"])
    monkeypatch.setattr(module, "python_is_isolated", lambda: True)
    monkeypatch.setattr(module, "release_signer_environment_is_complete", lambda: True)
    monkeypatch.setenv("PCH_RELEASE_SIGNER_SHA256", before["tagSignerFingerprint"])

    with pytest.raises(RuntimeError, match="source checkout changed"):
        module.main()

    assert not list(tmp_path.glob("*.zip"))
    assert not (tmp_path / "release-manifest.json").exists()


def test_release_git_runner_uses_fixed_binary_and_minimal_environment(
    project_root, monkeypatch
):
    module = load_release_smoke(project_root)
    trusted_git = Path("/fixed/system/git")
    captured = {}

    def fake_run(command, **options):
        captured["command"] = command
        captured["options"] = options
        return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=b"")

    monkeypatch.setattr(module, "GIT_EXECUTABLE", trusted_git)
    monkeypatch.setattr(module.subprocess, "run", fake_run)

    module.run_git("status", "--porcelain")

    assert captured["command"] == [
        str(trusted_git),
        "--no-replace-objects",
        "-c",
        "core.fsmonitor=false",
        "-C",
        str(project_root),
        "status",
        "--porcelain",
    ]
    environment = captured["options"]["env"]
    assert environment["GIT_CONFIG_NOSYSTEM"] == "1"
    assert environment["GIT_CONFIG_GLOBAL"] == os.devnull
    assert environment["GIT_NO_REPLACE_OBJECTS"] == "1"
    assert environment["GIT_TERMINAL_PROMPT"] == "0"
    assert "HOME" not in environment
    assert "GIT_CONFIG_COUNT" not in environment
    assert captured["options"]["capture_output"] is True


def test_release_source_state_refuses_git_replace_refs(
    project_root, tmp_path, monkeypatch
):
    module = load_release_smoke(project_root)
    if module.GIT_EXECUTABLE is None:
        pytest.skip("fixed system Git is unavailable")
    repository = tmp_path / "repository"
    repository.mkdir()

    def git(*arguments: str):
        return subprocess.run(
            [str(module.GIT_EXECUTABLE), "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    git("init", "-q")
    git("config", "user.name", "Heznpc")
    git("config", "user.email", "heznpc@example.invalid")
    payload = repository / "payload.txt"
    payload.write_text("trusted\n", encoding="utf-8")
    git("add", "payload.txt")
    git("commit", "-qm", "trusted")
    trusted = git("rev-parse", "HEAD").stdout.strip()
    payload.write_text("replacement\n", encoding="utf-8")
    git("add", "payload.txt")
    git("commit", "-qm", "replacement")
    replacement = git("rev-parse", "HEAD").stdout.strip()
    git("replace", trusted, replacement)

    monkeypatch.setattr(module, "PROJECT_ROOT", repository)

    with pytest.raises(RuntimeError, match="Git replace refs"):
        module.source_state("0.3.0")


def test_release_source_state_pins_expected_ssh_signer(
    project_root, tmp_path, monkeypatch
):
    module = load_release_smoke(project_root)
    if module.GIT_EXECUTABLE is None or not Path("/usr/bin/ssh-keygen").is_file():
        pytest.skip("trusted Git or ssh-keygen is unavailable")
    repository = tmp_path / "repository"
    repository.mkdir()

    def git(*arguments: str, check: bool = True):
        return subprocess.run(
            [str(module.GIT_EXECUTABLE), "-C", str(repository), *arguments],
            check=check,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def generate_key(name: str) -> tuple[str, str, Path]:
        private_key = tmp_path / name
        subprocess.run(
            [
                "/usr/bin/ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "test-key",
                "-f",
                str(private_key),
            ],
            check=True,
        )
        fields = private_key.with_suffix(".pub").read_text(encoding="utf-8").split()
        public_key = " ".join(fields[:2])
        fingerprint = subprocess.run(
            ["/usr/bin/ssh-keygen", "-E", "sha256", "-lf", str(private_key.with_suffix(".pub"))],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.split()[1]
        return public_key, fingerprint, private_key

    expected_public_key, expected_fingerprint, expected_private_key = generate_key(
        "expected-key"
    )
    other_public_key, other_fingerprint, _other_private_key = generate_key("other-key")
    git("init", "-q")
    git("config", "user.name", "Heznpc")
    git("config", "user.email", "heznpc@example.invalid")
    (repository / "payload.txt").write_text("trusted\n", encoding="utf-8")
    git("add", "payload.txt")
    git("commit", "-qm", "trusted")
    git("config", "gpg.format", "ssh")
    git("config", "user.signingkey", str(expected_private_key))
    signed = git("tag", "-s", "v0.3.0", "-m", "signed fixture", check=False)
    if signed.returncode != 0:
        pytest.skip(f"system Git cannot create SSH-signed tags: {signed.stderr}")
    monkeypatch.setattr(module, "PROJECT_ROOT", repository)
    monkeypatch.setenv("PCH_RELEASE_SIGNER_PUBLIC_KEY", expected_public_key)
    monkeypatch.setenv("PCH_RELEASE_SIGNER_SHA256", expected_fingerprint)

    verified = module.source_state("0.3.0")

    assert verified["tagSignatureVerified"] is True
    assert verified["tagSignerPrincipal"] == "heznpc"
    assert verified["tagSignerFingerprint"] == expected_fingerprint

    # A ref name is not part of the SSH signature. The signed tag object's own
    # `tag` header must be bound to the version requested by the release.
    signed_object = git("rev-parse", "refs/tags/v0.3.0").stdout.strip()
    git("update-ref", "refs/tags/v9.9.9", signed_object)
    mismatched_name = module.source_state("9.9.9")
    assert mismatched_name["tag"] == "v9.9.9"
    assert mismatched_name["tagObjectID"] == signed_object
    assert mismatched_name["tagSignatureVerified"] is False
    assert mismatched_name["tagSignerPrincipal"] is None

    monkeypatch.setenv("PCH_RELEASE_SIGNER_PUBLIC_KEY", other_public_key)
    monkeypatch.setenv("PCH_RELEASE_SIGNER_SHA256", other_fingerprint)
    wrong_signer = module.source_state("0.3.0")

    assert wrong_signer["tagSignatureVerified"] is False
    assert wrong_signer["tagSignerPrincipal"] is None
    assert wrong_signer["tagSignerFingerprint"] is None


def test_release_mode_requires_python_isolation(project_root):
    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "release_smoke.py"),
            "--release",
        ],
        cwd=project_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )

    assert result.returncode == 2
    assert "requires Python isolated mode" in result.stderr


def test_release_mode_requires_external_signer_configuration(project_root):
    environment = os.environ.copy()
    environment.pop("PCH_RELEASE_SIGNER_PUBLIC_KEY", None)
    environment.pop("PCH_RELEASE_SIGNER_SHA256", None)
    result = subprocess.run(
        [
            sys.executable,
            "-I",
            "-B",
            str(project_root / "scripts" / "release_smoke.py"),
            "--release",
        ],
        cwd=project_root,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )

    assert result.returncode == 2
    assert "PCH_RELEASE_SIGNER_PUBLIC_KEY" in result.stderr
    assert "PCH_RELEASE_SIGNER_SHA256" in result.stderr


def test_release_smoke_ignores_hostile_git_path_and_configuration(
    project_root, tmp_path
):
    module = load_release_smoke(project_root)
    if module.GIT_EXECUTABLE is None:
        pytest.skip("fixed system Git is unavailable")

    marker = tmp_path / "ambient-git-ran"
    python_marker = tmp_path / "ambient-python-ran"
    hostile_bin = tmp_path / "bin"
    hostile_bin.mkdir()
    (hostile_bin / "sitecustomize.py").write_text(
        f"from pathlib import Path\nPath({str(python_marker)!r}).touch()\n",
        encoding="utf-8",
    )
    hostile_git = hostile_bin / ("git.exe" if os.name == "nt" else "git")
    hostile_git.write_text(
        f'#!/bin/sh\n/usr/bin/touch "{marker}"\nexit 99\n', encoding="utf-8"
    )
    hostile_git.chmod(0o755)
    hostile_config = tmp_path / "gitconfig"
    hostile_config.write_text(
        f"[core]\n\tfsmonitor = {hostile_git}\n", encoding="utf-8"
    )
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": str(hostile_bin),
            "HOME": str(tmp_path),
            "GIT_CONFIG_GLOBAL": str(hostile_config),
            "GIT_CONFIG_SYSTEM": str(hostile_config),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.fsmonitor",
            "GIT_CONFIG_VALUE_0": str(hostile_git),
            "PYTHONPATH": str(hostile_bin),
        }
    )

    result = subprocess.run(
        [
            sys.executable,
            "-I",
            "-B",
            str(project_root / "scripts" / "release_smoke.py"),
            "--check-only",
        ],
        cwd=project_root,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert not marker.exists()
    assert not python_marker.exists()


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


def test_artifact_metadata_only_accepts_a_dmg_without_parsing_binary_bytes(
    project_root, tmp_path
):
    image = tmp_path / "fixture.dmg"
    image.write_bytes(b"not-a-real-image private@example.org")

    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts/artifact_audit.py"),
            "--metadata-only",
            str(image),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)["ok"] is True


def test_artifact_tree_rejects_world_writable_entries(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    target = payload / "unsafe.txt"
    target.write_text("safe content", encoding="utf-8")
    target.chmod(0o666)

    assert "unsafe-mode" in {
        finding.rule for finding in audit_tree(payload, allowed_symlinks=set())
    }


def test_artifact_tree_exempts_only_an_exact_manifested_python_runtime(tmp_path):
    payload = tmp_path / "payload"
    runtime = payload / "Modore.app/Contents/Resources/modore-python"
    helper = runtime / "bin/python3.11"
    license_file = runtime / "lib/python3.11/LICENSE.txt"
    dynload_readme = runtime / "lib/python3.11/lib-dynload/README.txt"
    helper.parent.mkdir(parents=True)
    license_file.parent.mkdir(parents=True)
    dynload_readme.parent.mkdir(parents=True)
    helper.write_bytes(b"upstream-author@example.org")
    helper.chmod(0o755)
    license_file.write_bytes(b"another-upstream@example.org")
    dynload_readme.write_text("no extension modules", encoding="utf-8")
    (runtime / "ORIGIN.txt").write_text(PYTHON_RUNTIME_ORIGIN, encoding="utf-8")

    entries = []
    for path in sorted(item for item in runtime.rglob("*") if item.is_file()):
        relative = path.relative_to(runtime).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append(f"{digest}  ./{relative}\n")
    (runtime / "RUNTIME-MANIFEST.sha256").write_text("".join(entries), encoding="utf-8")

    assert not audit_tree(payload, allowed_symlinks=set())

    leaked = runtime / "lib/python3.11/local.py"
    leaked.write_text('api_key = "definitely-real-secret"\n', encoding="utf-8")
    findings = audit_tree(payload, allowed_symlinks=set())
    rules = {finding.rule for finding in findings}
    assert "runtime-manifest" in rules
    assert "assigned-secret" in rules


def test_artifact_tree_rejects_a_runtime_manifest_hash_mismatch(tmp_path):
    payload = tmp_path / "payload"
    runtime = payload / "Contents/Resources/modore-python"
    helper = runtime / "bin/python3.11"
    license_file = runtime / "lib/python3.11/LICENSE.txt"
    helper.parent.mkdir(parents=True)
    license_file.parent.mkdir(parents=True)
    helper.write_bytes(b"upstream@example.org")
    helper.chmod(0o755)
    license_file.write_text("license", encoding="utf-8")
    (runtime / "ORIGIN.txt").write_text(PYTHON_RUNTIME_ORIGIN, encoding="utf-8")
    (runtime / "RUNTIME-MANIFEST.sha256").write_text(
        "0" * 64 + "  ./bin/python3.11\n"
        + hashlib.sha256(license_file.read_bytes()).hexdigest()
        + "  ./lib/python3.11/LICENSE.txt\n"
        + hashlib.sha256(PYTHON_RUNTIME_ORIGIN.encode()).hexdigest()
        + "  ./ORIGIN.txt\n",
        encoding="utf-8",
    )

    rules = {finding.rule for finding in audit_tree(payload, allowed_symlinks=set())}
    assert "runtime-manifest" in rules
    assert "email-address" in rules


def test_artifact_tree_does_not_exempt_python_runtime_under_helpers(tmp_path):
    payload = tmp_path / "payload"
    runtime = payload / "Modore.app/Contents/Helpers/modore-python"
    helper = runtime / "bin/python3.11"
    license_file = runtime / "lib/python3.11/LICENSE.txt"
    dynload_readme = runtime / "lib/python3.11/lib-dynload/README.txt"
    helper.parent.mkdir(parents=True)
    license_file.parent.mkdir(parents=True)
    dynload_readme.parent.mkdir(parents=True)
    helper.write_bytes(b"upstream-author@example.org")
    helper.chmod(0o755)
    license_file.write_text("license", encoding="utf-8")
    dynload_readme.write_text("no extension modules", encoding="utf-8")
    (runtime / "ORIGIN.txt").write_text(PYTHON_RUNTIME_ORIGIN, encoding="utf-8")
    entries = []
    for path in sorted(item for item in runtime.rglob("*") if item.is_file()):
        relative = path.relative_to(runtime).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append(f"{digest}  ./{relative}\n")
    (runtime / "RUNTIME-MANIFEST.sha256").write_text("".join(entries), encoding="utf-8")

    rules = {finding.rule for finding in audit_tree(payload, allowed_symlinks=set())}
    assert "email-address" in rules


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
    assert "CFBundleURLTypes" in source
    assert "CFBundleURLSchemes:0 string modore" in source
    assert "CFBundleURLName string $IDENTIFIER" in source
    assert "project-root.txt" not in source
    assert source.startswith("#!/bin/bash -p")
    assert "run_clean /usr/bin/xcrun swift build" in source
    assert "/bin/ps -axo comm=" in source
    assert "app_binary_is_running" in source
    assert "/usr/bin/pgrep -f -x" not in source
    assert "PCH_BUILD_DIR must stay inside the repository build tree or user temp directory" in source
    assert "PCH_BUILD_DIR resolves outside the allowed build roots" in source
    assert "create_build_directory_without_symlinks" in source
    assert 'mktemp -d "$binary_staging/swift-build-$architecture.XXXXXX"' in source
    assert 'scratch_path="$BUILD_DIR/swift-build-$architecture"' not in source
    assert "existing_app_is_expected" in source
    assert "Previous app preserved for manual review" in source
    assert '/bin/rm -rf "$backup_app"' not in source
    assert 'KEEP_PREVIOUS_APP="${PCH_KEEP_PREVIOUS_APP:-0}"' in source
    assert 'if [[ "$KEEP_PREVIOUS_APP" == "1" ]]' in source
    assert '/bin/rm -rf "$backup_container"' not in source
    assert "build_support_reconcile_app_backup" in source
    assert "build_support_retire_preserved_backup" in source
    assert "Verified replacement; previous app backup removed" in source
    assert 'ALLOW_USER_TOOLCHAIN="${PCH_ALLOW_USER_TOOLCHAIN:-0}"' in source
    assert '"$ALLOW_USER_TOOLCHAIN" == "1" && "${PCH_SKIP_ADHOC_SIGN:-0}" == "1"' in source
    assert 'Contents/Resources/modore-python' in source
    assert 'Contents/Helpers/modore-python' not in source
    assert 'lib/python3.11/lib-dynload/README.txt' in source
    assert 'python_smoke_stderr' in source
    assert 'python_smoke_status=$?' in source
    assert '"$python_smoke_status" -ne 0' in source
    assert 'scree.py" sessions --limit 1 --home "$python_sessions_home"' in source
    assert 'python_sessions_status=$?' in source
    assert 'p["coverage"]["complete"] is True' in source
    assert 'source "$BUILD_SUPPORT_MODULE"' in source
    assert 'build_support_acquire_lock "$lock_file" "$current_uid"' in source
    assert "build_support_recover_staging_directories" in source
    assert "build_support_prune_runtime_cache" in source
    assert "build_support_download" in source
    assert 'PYTHON_RUNTIME_MAX_ARCHIVE_BYTES="268435456"' in source
    assert '"$PYTHON_RUNTIME_MAX_ARCHIVE_BYTES"' in source

    support = (project_root / "scripts/modules/build_support.sh").read_text(
        encoding="utf-8"
    )
    for curl_bound in (
        "--connect-timeout",
        "--max-time",
        "--proto-redir",
        "--retry-max-time",
        "--speed-limit",
        "--speed-time",
    ):
        assert curl_bound in support


def test_mac_builder_keeps_every_top_level_stdlib_dependency_imported_by_scree(
    project_root,
):
    builder = (project_root / "scripts/build_macos_swift_app.sh").read_text(
        encoding="utf-8"
    )
    match = re.search(r"for excluded in \\\n(?P<body>.*?)\; do", builder, re.DOTALL)
    assert match is not None
    excluded = set(re.findall(r"[A-Za-z][A-Za-z0-9_-]*", match.group("body")))

    tree = ast.parse(
        (project_root / "scripts/scree.py").read_text(encoding="utf-8")
    )
    imported = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            imported.update(alias.name.partition(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.partition(".")[0])

    assert imported.isdisjoint(excluded), (
        "embedded runtime prunes scree imports: "
        f"{sorted(imported & excluded)}"
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS lockf/stat behavior")
def test_mac_build_support_process_group_sigkill_recovers_only_its_staging(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    checkout = tmp_path / "checkout"
    build_directory = checkout / "build" / "macos"
    user_temp = tmp_path / "private-temp"
    build_directory.mkdir(parents=True, mode=0o700)
    user_temp.mkdir(mode=0o700)
    ready = tmp_path / "ready"
    harness = r'''
set -euo pipefail
source "$1"
root="$2"
build="$3"
temp="$4"
ready="$5"
uid="$(/usr/bin/id -u)"
build_support_acquire_lock "$build/.pch-build.lock" "$uid"
identity="$(build_support_identity "$root" "$build")"
build_support_recover_staging_directories "$build" ".pch-app-staging" "$identity" "$uid"
build_support_recover_staging_directories "$temp" "pch-swift-binaries" "$identity" "$uid"
if [[ "${6:-}" == "hold" ]]; then
    app="$(build_support_create_staging_directory "$build" ".pch-app-staging" "$identity" "$uid")"
    binary="$(build_support_create_staging_directory "$temp" "pch-swift-binaries" "$identity" "$uid")"
    /bin/mkdir "$app/payload" "$binary/payload"
    /usr/bin/printf 'partial app\n' > "$app/payload/file"
    /usr/bin/printf 'partial binary\n' > "$binary/payload/file"
    /usr/bin/printf '%s\n%s\n' "$app" "$binary" > "$ready"
    /bin/sleep 30
fi
'''
    command = [
        "/bin/bash",
        "-p",
        "-c",
        harness,
        "bash",
        str(support),
        str(checkout),
        str(build_directory),
        str(user_temp),
        str(ready),
    ]
    process = subprocess.Popen(
        [*command, "hold"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while (
        (not ready.exists() or ready.stat().st_size == 0)
        and process.poll() is None
        and time.monotonic() < deadline
    ):
        time.sleep(0.02)
    assert ready.exists() and ready.stat().st_size > 0, (
        process.stderr.read() if process.poll() is not None else ""
    )
    app_staging, binary_staging = [Path(line) for line in ready.read_text().splitlines()]

    # A concurrent invocation cannot acquire the kernel lock and therefore
    # cannot reclaim directories belonging to the active build.
    active_result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )
    assert active_result.returncode == 75
    assert app_staging.is_dir()
    assert binary_staging.is_dir()

    identity = hashlib.sha256(
        f"{checkout}\0{build_directory}\0".encode("utf-8")
    ).hexdigest()
    foreign_identity = "f" * 64 if identity != "f" * 64 else "e" * 64
    foreign = build_directory / f".pch-app-staging.{foreign_identity}.FOREIGN"
    foreign.mkdir()
    (foreign / ".pch-build-identity").write_text(
        foreign_identity + "\n", encoding="utf-8"
    )
    unmarked = build_directory / f".pch-app-staging.{identity}.UNMARKED"
    unmarked.mkdir()
    (unmarked / "user.txt").write_text("preserve\n", encoding="utf-8")
    forged_directory_mode = (
        build_directory / f".pch-app-staging.{identity}.FORGED-DIRECTORY-MODE"
    )
    forged_directory_mode.mkdir(mode=0o700)
    forged_directory_mode.chmod(0o755)
    forged_directory_marker = forged_directory_mode / ".pch-build-identity"
    forged_directory_marker.write_text(identity + "\n", encoding="utf-8")
    forged_directory_marker.chmod(0o600)
    forged_marker_mode = (
        build_directory / f".pch-app-staging.{identity}.FORGED-MARKER-MODE"
    )
    forged_marker_mode.mkdir(mode=0o700)
    forged_marker = forged_marker_mode / ".pch-build-identity"
    forged_marker.write_text(identity + "\n", encoding="utf-8")
    forged_marker.chmod(0o644)

    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    recovered = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert recovered.returncode == 0, recovered.stderr
    assert not app_staging.exists()
    assert not binary_staging.exists()
    assert foreign.is_dir()
    assert (unmarked / "user.txt").read_text(encoding="utf-8") == "preserve\n"
    assert forged_directory_mode.is_dir()
    assert forged_marker_mode.is_dir()
    assert (build_directory / ".pch-build.lock").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS lockf descriptor inheritance")
def test_mac_build_lock_survives_parent_only_sigkill_until_inheriting_child_exits(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    lock = tmp_path / "build.lock"
    ready = tmp_path / "ready"
    release = tmp_path / "release.fifo"
    os.mkfifo(release)
    harness = r'''
set -euo pipefail
source "$1"
build_support_acquire_lock "$2" "$(/usr/bin/id -u)"
( IFS= read -r _ < "$4" ) &
child=$!
/usr/bin/printf '%s\n' "$child" > "$3"
wait "$child"
'''
    process = subprocess.Popen(
        [
            "/bin/bash", "-p", "-c", harness, "bash",
            str(support), str(lock), str(ready), str(release),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while (
        (not ready.exists() or ready.stat().st_size == 0)
        and process.poll() is None
        and time.monotonic() < deadline
    ):
        time.sleep(0.01)
    assert ready.exists() and ready.stat().st_size > 0
    os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=5)

    acquire = [
        "/bin/bash", "-p", "-c",
        'source "$1"; build_support_acquire_lock "$2" "$(/usr/bin/id -u)"',
        "bash", str(support), str(lock),
    ]
    blocked = subprocess.run(acquire, capture_output=True, timeout=5)
    assert blocked.returncode == 75

    with release.open("w", encoding="utf-8") as stream:
        stream.write("finish\n")
    deadline = time.monotonic() + 3
    while True:
        acquired = subprocess.run(acquire, capture_output=True, timeout=5)
        if acquired.returncode == 0:
            break
        assert acquired.returncode == 75
        assert time.monotonic() < deadline
        time.sleep(0.02)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS lockf/stat behavior")
@pytest.mark.parametrize("unsafe_kind", ["symlink", "hardlink", "group-writable"])
def test_mac_build_lock_rejects_unsafe_path_without_touching_its_target(
    project_root, tmp_path, unsafe_kind
):
    support = project_root / "scripts/modules/build_support.sh"
    victim = tmp_path / "victim"
    victim.write_text("preserve\n", encoding="utf-8")
    lock = tmp_path / "build.lock"
    if unsafe_kind == "symlink":
        lock.symlink_to(victim)
    elif unsafe_kind == "hardlink":
        os.link(victim, lock)
    else:
        lock.write_text("preserve\n", encoding="utf-8")
        lock.chmod(0o660)
    result = subprocess.run(
        [
            "/bin/bash",
            "-p",
            "-c",
            'source "$1"; build_support_acquire_lock "$2" "$(/usr/bin/id -u)"',
            "bash",
            str(support),
            str(lock),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert result.returncode == 73
    assert victim.read_text(encoding="utf-8") == "preserve\n"
    if unsafe_kind == "symlink":
        assert lock.is_symlink()
    else:
        assert lock.read_text(encoding="utf-8") == "preserve\n"


@pytest.mark.skipif(sys.platform != "darwin", reason="uses the macOS curl build helper")
def test_mac_runtime_download_stalled_tls_peer_hits_external_hard_deadline(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    stop = threading.Event()

    def stall_peer():
        try:
            connection, _ = listener.accept()
            with connection:
                stop.wait(5)
        finally:
            listener.close()

    thread = threading.Thread(target=stall_peer, daemon=True)
    thread.start()
    destination = tmp_path / "runtime.download"
    started = time.monotonic()
    try:
        result = subprocess.run(
            [
                "/bin/bash",
                "-p",
                "-c",
                'source "$1"; build_support_download "$2" "$3" "$4" "$5" 10 10 10 10 1 1 1048576',
                "bash",
                str(support),
                str(Path.home()),
                str(tmp_path),
                str(destination),
                f"https://127.0.0.1:{port}/runtime.tar.gz",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=5,
        )
    finally:
        stop.set()
        thread.join(timeout=1)
    elapsed = time.monotonic() - started

    assert result.returncode == 124, result.stderr
    assert elapsed < 4
    assert not list(tmp_path.glob("*.pch-timeout"))


@pytest.mark.skipif(sys.platform != "darwin", reason="uses macOS curl and TLS")
@pytest.mark.parametrize("header_mode", ["missing", "false-content-length"])
def test_mac_runtime_download_caps_real_destination_growth_and_removes_partial(
    project_root, tmp_path, header_mode
):
    support = project_root / "scripts/modules/build_support.sh"
    certificate = tmp_path / "certificate.pem"
    private_key = tmp_path / "private-key.pem"
    openssl_config = tmp_path / "openssl.cnf"
    openssl_config.write_text(
        "[req]\n"
        "distinguished_name=dn\n"
        "x509_extensions=extensions\n"
        "prompt=no\n"
        "[dn]\n"
        "CN=localhost\n"
        "[extensions]\n"
        "subjectAltName=DNS:localhost,IP:127.0.0.1\n",
        encoding="utf-8",
    )
    certificate_result = subprocess.run(
        [
            "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-nodes", "-sha256", "-days", "1", "-keyout", str(private_key),
            "-out", str(certificate), "-config", str(openssl_config),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
    )
    assert certificate_result.returncode == 0, certificate_result.stderr

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(certificate, private_key)
    stop = threading.Event()

    def stream_without_trustworthy_length():
        try:
            raw_connection, _ = listener.accept()
            with raw_connection:
                with tls_context.wrap_socket(raw_connection, server_side=True) as connection:
                    request = b""
                    while b"\r\n\r\n" not in request:
                        block = connection.recv(4096)
                        if not block:
                            return
                        request += block
                    if header_mode == "missing":
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"
                        )
                    else:
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\n"
                            b"Content-Length: 1\r\n"
                            b"Transfer-Encoding: chunked\r\n"
                            b"Connection: close\r\n\r\n"
                        )
                    payload = b"x" * 4096
                    while not stop.is_set():
                        if header_mode == "missing":
                            connection.sendall(payload)
                        else:
                            connection.sendall(b"1000\r\n" + payload + b"\r\n")
                        time.sleep(0.001)
        except (BrokenPipeError, ConnectionResetError, OSError, ssl.SSLError):
            pass
        finally:
            listener.close()

    server_thread = threading.Thread(
        target=stream_without_trustworthy_length, daemon=True
    )
    server_thread.start()
    destination = tmp_path / "runtime.download"
    peak_size = 0
    observer_stop = threading.Event()

    def observe_destination():
        nonlocal peak_size
        while not observer_stop.is_set():
            try:
                peak_size = max(peak_size, destination.stat().st_size)
            except FileNotFoundError:
                pass
            time.sleep(0.001)

    observer = threading.Thread(target=observe_destination, daemon=True)
    observer.start()
    maximum_bytes = 65536
    try:
        result = subprocess.run(
            [
                "/bin/bash", "-p", "-c",
                'source "$1"; build_support_download "$2" "$3" "$4" "$5" 3 10 10 10 1 5 65536 "$6"',
                "bash", str(support), str(Path.home()), str(tmp_path),
                str(destination), f"https://localhost:{port}/runtime.tar.gz",
                str(certificate),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=8,
        )
    finally:
        observer_stop.set()
        stop.set()
        observer.join(timeout=1)
        server_thread.join(timeout=1)

    # curl may report its write failure or be delivered SIGXFSZ directly;
    # either way the kernel-enforced file limit must fail the transfer.
    assert result.returncode in {23, 63, 128 + signal.SIGXFSZ}, result.stderr
    assert peak_size >= maximum_bytes // 2
    assert peak_size <= maximum_bytes
    assert not destination.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS lockf/curl behavior")
def test_orphaned_download_keeps_lock_only_until_its_hard_deadline(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    lock = tmp_path / "build.lock"
    ready = tmp_path / "ready"
    destination = tmp_path / "runtime.download"
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    accepted = threading.Event()
    stop = threading.Event()

    def stall_peer():
        try:
            connection, _ = listener.accept()
            accepted.set()
            with connection:
                stop.wait(5)
        finally:
            listener.close()

    thread = threading.Thread(target=stall_peer, daemon=True)
    thread.start()
    harness = r'''
set -euo pipefail
source "$1"
build_support_acquire_lock "$2" "$(/usr/bin/id -u)"
/usr/bin/printf 'ready\n' > "$3"
build_support_download "$4" "$5" "$6" "$7" 10 10 10 10 1 1 1048576
'''
    process = subprocess.Popen(
        [
            "/bin/bash", "-p", "-c", harness, "bash", str(support),
            str(lock), str(ready), str(Path.home()), str(tmp_path),
            str(destination), f"https://127.0.0.1:{port}/runtime.tar.gz",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    assert accepted.wait(timeout=3)
    os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    acquire = [
        "/bin/bash", "-p", "-c",
        'source "$1"; build_support_acquire_lock "$2" "$(/usr/bin/id -u)"',
        "bash", str(support), str(lock),
    ]
    started = time.monotonic()
    blocked = subprocess.run(acquire, capture_output=True, timeout=5)
    assert blocked.returncode == 75
    deadline = started + 3
    try:
        while True:
            acquired = subprocess.run(acquire, capture_output=True, timeout=5)
            if acquired.returncode == 0:
                break
            assert acquired.returncode == 75
            assert time.monotonic() < deadline
            time.sleep(0.02)
    finally:
        stop.set()
        thread.join(timeout=1)
    assert time.monotonic() - started < 3
    assert not destination.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS stat flags")
def test_mac_runtime_cache_prunes_only_old_managed_single_link_archives(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    current = cache / "cpython-3.11.16+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz"
    old = cache / "cpython-3.11.15+20260701-aarch64-apple-darwin-install_only_stripped.tar.gz"
    unused_arch = cache / "cpython-3.11.16+20260825-x86_64-apple-darwin-install_only_stripped.tar.gz"
    unknown = cache / "notes.txt"
    symlink = cache / "cpython-3.10.9+20250101-aarch64-apple-darwin-install_only_stripped.tar.gz"
    directory = cache / "cpython-3.9.9+20240101-x86_64-apple-darwin-install_only_stripped.tar.gz"
    hardlink = cache / "cpython-3.8.9+20230101-aarch64-apple-darwin-install_only_stripped.tar.gz"
    for path in (current, old, unused_arch):
        path.write_bytes(path.name.encode("ascii"))
    unknown.write_text("preserve user file\n", encoding="utf-8")
    victim = tmp_path / "victim"
    victim.write_text("preserve target\n", encoding="utf-8")
    symlink.symlink_to(victim)
    directory.mkdir()
    hardlink_source = tmp_path / "hardlink-source"
    hardlink_source.write_text("preserve linked bytes\n", encoding="utf-8")
    os.link(hardlink_source, hardlink)

    result = subprocess.run(
        [
            "/bin/bash",
            "-p",
            "-c",
            'source "$1"; build_support_prune_runtime_cache "$2" "$(/usr/bin/id -u)" "$3"',
            "bash",
            str(support),
            str(cache),
            current.name,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    assert current.is_file()
    assert not old.exists()
    assert not unused_arch.exists()
    assert unknown.read_text(encoding="utf-8") == "preserve user file\n"
    assert symlink.is_symlink()
    assert victim.read_text(encoding="utf-8") == "preserve target\n"
    assert directory.is_dir()
    assert hardlink.is_file()
    assert hardlink_source.read_text(encoding="utf-8") == "preserve linked bytes\n"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS immutable file flags")
def test_mac_runtime_cache_prune_reports_unlink_failure_without_masking_it(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    blocked = cache / "cpython-1.0.0+20200101-aarch64-apple-darwin-install_only_stripped.tar.gz"
    later = cache / "cpython-9.0.0+20990101-aarch64-apple-darwin-install_only_stripped.tar.gz"
    blocked.write_bytes(b"immutable managed archive")
    later.write_bytes(b"later managed archive")
    subprocess.run(["/usr/bin/chflags", "uchg", str(blocked)], check=True)

    try:
        result = subprocess.run(
            [
                "/bin/bash",
                "-p",
                "-c",
                'source "$1"; build_support_prune_runtime_cache "$2" "$(/usr/bin/id -u)"',
                "bash",
                str(support),
                str(cache),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=5,
        )

        assert result.returncode != 0
        assert blocked.is_file()
        assert later.is_file(), "pruning continued after its first unlink failure"
    finally:
        subprocess.run(["/usr/bin/chflags", "nouchg", str(blocked)], check=False)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS lockf/stat behavior")
@pytest.mark.parametrize("replacement_installed", [False, True])
def test_mac_app_backup_recovers_both_process_group_sigkill_swap_states(
    project_root, tmp_path, replacement_installed
):
    support = project_root / "scripts/modules/build_support.sh"
    checkout = tmp_path / "checkout"
    build_directory = checkout / "build" / "macos"
    build_directory.mkdir(parents=True, mode=0o700)
    final_app = build_directory / "Modore.app"
    final_app.mkdir()
    (final_app / "valid").write_text("old\n", encoding="utf-8")
    ready = tmp_path / "ready"
    crash_harness = r'''
set -euo pipefail
source "$1"
uid="$(/usr/bin/id -u)"
build_support_acquire_lock "$3/.pch-build.lock" "$uid"
identity="$(build_support_identity "$2" "$3")"
backup="$(build_support_create_staging_directory "$3" ".pch-app-backup" "$identity" "$uid")"
/bin/mv "$3/Modore.app" "$backup/Modore.app"
if [[ "$5" == "installed" ]]; then
    /bin/mkdir "$3/Modore.app"
    /usr/bin/printf 'new\n' > "$3/Modore.app/valid"
fi
/usr/bin/printf '%s\n' "$backup" > "$4"
/bin/sleep 30
'''
    process = subprocess.Popen(
        [
            "/bin/bash", "-p", "-c", crash_harness, "bash", str(support),
            str(checkout), str(build_directory), str(ready),
            "installed" if replacement_installed else "missing",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while (
        (not ready.exists() or ready.stat().st_size == 0)
        and process.poll() is None
        and time.monotonic() < deadline
    ):
        time.sleep(0.01)
    assert ready.exists() and ready.stat().st_size > 0
    backup = Path(ready.read_text(encoding="utf-8").strip())
    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)

    recovery_harness = r'''
set -euo pipefail
source "$1"
validate_app() { [[ -d "$1" && ! -L "$1" && -f "$1/valid" && ! -L "$1/valid" ]]; }
uid="$(/usr/bin/id -u)"
build_support_acquire_lock "$3/.pch-build.lock" "$uid"
identity="$(build_support_identity "$2" "$3")"
build_support_reconcile_app_backup "$3" "$3/Modore.app" "Modore.app" "$identity" "$uid" 0 validate_app
/usr/bin/printf 'recovered=%s preserved=%s\n' "$BUILD_SUPPORT_BACKUP_RECOVERED" "$BUILD_SUPPORT_PRESERVED_BACKUP"
'''
    recovered = subprocess.run(
        [
            "/bin/bash", "-p", "-c", recovery_harness, "bash", str(support),
            str(checkout), str(build_directory),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert recovered.returncode == 0, recovered.stderr
    expected = "new\n" if replacement_installed else "old\n"
    assert (final_app / "valid").read_text(encoding="utf-8") == expected
    assert not backup.exists()
    assert not list(build_directory.glob(".pch-app-backup.*"))
    assert (
        "recovered=0" if replacement_installed else "recovered=1"
    ) in recovered.stdout


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS stat behavior")
def test_mac_keep_previous_backup_rotates_to_exactly_one_owned_generation(
    project_root, tmp_path
):
    support = project_root / "scripts/modules/build_support.sh"
    checkout = tmp_path / "checkout"
    build_directory = checkout / "build" / "macos"
    build_directory.mkdir(parents=True, mode=0o700)
    final_app = build_directory / "Modore.app"
    final_app.mkdir()
    (final_app / "valid").write_text("current\n", encoding="utf-8")
    identity = hashlib.sha256(
        f"{checkout}\0{build_directory}\0".encode("utf-8")
    ).hexdigest()

    def create_backup(version: str) -> Path:
        result = subprocess.run(
            [
                "/bin/bash", "-p", "-c",
                'source "$1"; build_support_create_staging_directory "$2" ".pch-app-backup" "$3" "$(/usr/bin/id -u)"',
                "bash", str(support), str(build_directory), identity,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=5,
        )
        assert result.returncode == 0, result.stderr
        container = Path(result.stdout.strip())
        app = container / "Modore.app"
        app.mkdir()
        (app / "valid").write_text(version + "\n", encoding="utf-8")
        return container

    first = create_backup("first")
    reconcile = r'''
set -euo pipefail
source "$1"
validate_app() { [[ -d "$1" && -f "$1/valid" ]]; }
build_support_reconcile_app_backup "$2" "$2/Modore.app" "Modore.app" "$3" "$(/usr/bin/id -u)" 1 validate_app
/usr/bin/printf '%s\n' "$BUILD_SUPPORT_PRESERVED_BACKUP"
'''
    preserved = subprocess.run(
        ["/bin/bash", "-p", "-c", reconcile, "bash", str(support),
         str(build_directory), identity],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )
    assert preserved.returncode == 0, preserved.stderr
    assert Path(preserved.stdout.strip()) == first

    retire = r'''
set -euo pipefail
source "$1"
validate_app() { [[ -d "$1" && -f "$1/valid" ]]; }
build_support_retire_preserved_backup "$2" "$3" "Modore.app" "$4" "$(/usr/bin/id -u)" validate_app
'''
    retired = subprocess.run(
        ["/bin/bash", "-p", "-c", retire, "bash", str(support), str(first),
         str(build_directory), identity],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )
    assert retired.returncode == 0, retired.stderr
    assert not first.exists()

    second = create_backup("second")
    preserved_again = subprocess.run(
        ["/bin/bash", "-p", "-c", reconcile, "bash", str(support),
         str(build_directory), identity],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )
    assert preserved_again.returncode == 0, preserved_again.stderr
    assert Path(preserved_again.stdout.strip()) == second
    assert list(build_directory.glob(".pch-app-backup.*")) == [second]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS stat behavior")
@pytest.mark.parametrize(
    "unsafe_state",
    [
        "foreign", "unmarked", "ambiguous", "extra-payload", "invalid-app",
        "forged-directory-mode", "forged-marker-mode",
    ],
)
def test_mac_app_backup_preserves_and_rejects_untrusted_or_ambiguous_state(
    project_root, tmp_path, unsafe_state
):
    support = project_root / "scripts/modules/build_support.sh"
    checkout = tmp_path / "checkout"
    build_directory = checkout / "build" / "macos"
    build_directory.mkdir(parents=True, mode=0o700)
    final_app = build_directory / "Modore.app"
    final_app.mkdir()
    (final_app / "valid").write_text("current\n", encoding="utf-8")
    identity = hashlib.sha256(
        f"{checkout}\0{build_directory}\0".encode("utf-8")
    ).hexdigest()

    def create_owned(container_identity: str = identity, *, valid: bool = True) -> Path:
        result = subprocess.run(
            [
                "/bin/bash", "-p", "-c",
                'source "$1"; build_support_create_staging_directory "$2" ".pch-app-backup" "$3" "$(/usr/bin/id -u)"',
                "bash", str(support), str(build_directory), container_identity,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=5,
        )
        assert result.returncode == 0, result.stderr
        container = Path(result.stdout.strip())
        app = container / "Modore.app"
        app.mkdir()
        if valid:
            (app / "valid").write_text("backup\n", encoding="utf-8")
        return container

    if unsafe_state == "foreign":
        foreign_identity = "f" * 64 if identity != "f" * 64 else "e" * 64
        containers = [create_owned(foreign_identity)]
    elif unsafe_state == "unmarked":
        container = build_directory / f".pch-app-backup.{identity}.UNMARKED"
        container.mkdir(mode=0o700)
        app = container / "Modore.app"
        app.mkdir()
        (app / "valid").write_text("backup\n", encoding="utf-8")
        containers = [container]
    elif unsafe_state == "ambiguous":
        containers = [create_owned(), create_owned()]
    elif unsafe_state == "extra-payload":
        container = create_owned()
        (container / "unexpected.txt").write_text("preserve\n", encoding="utf-8")
        containers = [container]
    elif unsafe_state == "forged-directory-mode":
        container = create_owned()
        container.chmod(0o755)
        containers = [container]
    elif unsafe_state == "forged-marker-mode":
        container = create_owned()
        (container / ".pch-build-identity").chmod(0o644)
        containers = [container]
    else:
        containers = [create_owned(valid=False)]

    reconcile = r'''
source "$1"
validate_app() { [[ -d "$1" && -f "$1/valid" ]]; }
build_support_reconcile_app_backup "$2" "$2/Modore.app" "Modore.app" "$3" "$(/usr/bin/id -u)" 0 validate_app
'''
    result = subprocess.run(
        ["/bin/bash", "-p", "-c", reconcile, "bash", str(support),
         str(build_directory), identity],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert result.returncode == 73
    assert all(container.exists() for container in containers)
    assert (final_app / "valid").read_text(encoding="utf-8") == "current\n"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS builder boundary")
def test_mac_builder_rejects_out_of_scope_build_directory(project_root, tmp_path):
    repository = tmp_path / "project"
    script_directory = repository / "scripts"
    script_directory.mkdir(parents=True)
    builder = script_directory / "build_macos_swift_app.sh"
    builder.write_bytes(
        (project_root / "scripts/build_macos_swift_app.sh").read_bytes()
    )
    builder.chmod(0o755)
    outside = Path.home() / f".pch-out-of-scope-build-test-{os.getpid()}"
    assert not outside.exists()
    environment = os.environ.copy()
    environment["PCH_BUILD_DIR"] = str(outside)

    result = subprocess.run(
        [str(builder)],
        cwd=repository,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
    )

    assert result.returncode == 64
    assert "must stay inside" in result.stderr
    assert not outside.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS builder boundary")
@pytest.mark.parametrize("link_at_build_root", [False, True])
def test_mac_builder_rejects_intermediate_symlink_without_external_side_effect(
    project_root, tmp_path, link_at_build_root
):
    repository = tmp_path / "project"
    script_directory = repository / "scripts"
    script_directory.mkdir(parents=True)
    builder = script_directory / "build_macos_swift_app.sh"
    builder.write_bytes(
        (project_root / "scripts/build_macos_swift_app.sh").read_bytes()
    )
    builder.chmod(0o755)
    outside = tmp_path / "outside"
    outside.mkdir()
    escaped = outside / "must-not-exist"
    build_root = repository / "build"
    if link_at_build_root:
        build_root.symlink_to(outside, target_is_directory=True)
        requested = build_root / escaped.name
    else:
        build_root.mkdir()
        (build_root / "redirect").symlink_to(outside, target_is_directory=True)
        requested = build_root / "redirect" / escaped.name
    environment = os.environ.copy()
    environment["PCH_BUILD_DIR"] = str(requested)

    result = subprocess.run(
        [str(builder)],
        cwd=repository,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
    )

    assert result.returncode == 64
    assert "intermediate symlink" in result.stderr
    assert not escaped.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS builder boundary")
def test_mac_builder_preserves_unrecognized_existing_app(project_root, tmp_path):
    repository = tmp_path / "project"
    script_directory = repository / "scripts"
    script_directory.mkdir(parents=True)
    builder = script_directory / "build_macos_swift_app.sh"
    builder.write_bytes(
        (project_root / "scripts/build_macos_swift_app.sh").read_bytes()
    )
    builder.chmod(0o755)
    module_directory = script_directory / "modules"
    module_directory.mkdir()
    (module_directory / "build_support.sh").write_bytes(
        (project_root / "scripts/modules/build_support.sh").read_bytes()
    )
    build_directory = repository / "build" / "macos"
    existing_app = build_directory / "Modore.app"
    existing_app.mkdir(parents=True)
    sentinel = existing_app / "user-file.txt"
    sentinel.write_text("preserve me\n", encoding="utf-8")
    environment = os.environ.copy()
    environment["PCH_BUILD_DIR"] = str(build_directory)
    # This test exercises preservation of an unrecognized destination, not
    # distribution trust. Hosted macOS runners own their preinstalled Xcode,
    # so opt into the build script's explicit non-distribution exception.
    environment["PCH_ALLOW_USER_TOOLCHAIN"] = "1"

    result = subprocess.run(
        [str(builder)],
        cwd=repository,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
    )

    assert result.returncode == 73
    assert "preserve and review it manually" in result.stderr
    assert sentinel.read_text(encoding="utf-8") == "preserve me\n"
    assert not list(build_directory.glob(".pch-app-backup.*"))


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
    assert 'EMBEDDED_PYTHON="$APP_DIR/Contents/Resources/modore-python/bin/python3.11"' in source
    assert 'EMBEDDED_PYTHON_ROOT="$APP_DIR/Contents/Resources/modore-python"' in source
    assert 'Contents/Helpers/modore-python' not in source
    assert "/bin/ln \"$WORK_DMG_PATH\" \"$DMG_PATH\"" in source
    assert source.startswith("#!/bin/bash -p")
    assert "/usr/bin/env -i" in source
    assert "run_clean /usr/bin/python3 -I -B" in source
    assert "run_clean /usr/bin/xcrun swift --version" in source
    assert 'build_environment+=("PCH_ALLOW_USER_TOOLCHAIN=1")' in source
    assert '"$MODE" == "distribution" || "$tool_owner" != "$current_uid"' in source
    assert '"swiftVersion": swift_version' in source
    assert "GIT_CONFIG_NOSYSTEM=1" in source
    assert "GIT_CONFIG_GLOBAL=/dev/null" in source
    assert "GIT_NO_REPLACE_OBJECTS=1" in source
    assert "/usr/bin/git --no-replace-objects" in source
    assert "core.fsmonitor=false" in source
    assert "release tooling refuses repositories with Git replace refs" in source
    assert 'expected_tag_ref="refs/tags/$expected_tag"' in source
    assert 'rev-parse --verify "$expected_tag_ref"' in source
    assert 'cat-file -t "$tag_object_id"' in source
    assert 'rev-parse --verify "$tag_object_id^{commit}"' in source
    assert '"/usr/bin/ssh-keygen", "-Y", "verify"' in source
    assert "reverify_distribution_source" in source
    assert 'current_tag_object_id" == "$tag_object_id"' in source
    assert "tag --points-at HEAD" not in source
    assert '"$expected_tag_ref^{commit}"' not in source
    assert "distribution requires %s to be an annotated tag object" in source
    assert "distribution requires pinned SSH signature validation for %s" in source
    assert '[[ -n "$exact_tag" && "$git_clean" == "true"' in source
    assert '"tagObjectID": tag_object_id or None' in source
    assert '"tagSignatureVerified": source_tag_signature_verified == "true"' in source
    assert '"tagSignerPrincipal": tag_signer_principal or None' in source
    assert '"tagSignerFingerprint": tag_signer_fingerprint or None' in source
    assert "PCH_RELEASE_SIGNER_PUBLIC_KEY" in source
    assert "PCH_RELEASE_SIGNER_SHA256" in source
    assert "PCH_CODESIGN_TEAM_ID" in source
    assert "PCH_CODESIGN_CERT_SHA256" in source
    assert "verify_developer_signature_identity" in source
    assert "SecStaticCodeCheckValidity" in source
    assert "SecCertificateCopyData" in source
    assert "--extract-certificates" not in source
    assert "makeAnonymousSnapshot" in source
    assert "unlink(temporaryPath)" in source
    assert 'path: "/dev/fd/\\(snapshotDescriptor)"' in source
    assert 'last_codesign_snapshot_sha256" == "$sha256"' in source
    assert '"teamIdentifier": codesign_team_id or None' in source
    assert '"certificateSHA256": codesign_cert_sha256 or None' in source
    assert "os.O_EXCL" in source
    assert "os.O_NOFOLLOW" in source
    assert "tempfile.TemporaryFile" in source
    assert 'f"/dev/fd/{allowed_signers.fileno()}"' in source
    assert '"-n", "git"' in source
    assert source.index('/bin/ln "$WORK_METADATA_PATH" "$METADATA_PATH"') < source.index(
        '/bin/ln "$WORK_DMG_PATH" "$DMG_PATH"'
    )
    assert "staged_dmg_identity" in source
    assert "staged_metadata_identity" in source
    assert "verify_final_staged_artifacts" in source
    assert "published artifact pair is not the audited inode pair" in source
    assert 'verify_developer_signature_identity "$WORK_DMG_PATH"' in source
    assert 'run_clean_git_verify_tag "$tag_object_id" "$expected_tag"' in source
    assert 'rollback_published_file "$DMG_PATH"' in source
    assert "renameatx_np" in source
    assert "0x00000004,  # RENAME_EXCL" in source
    assert '/bin/rm -f "$rollback_path"' not in source
    python_sign = '--sign "$identity" ' + "\\\n" + '        "$EMBEDDED_PYTHON"'
    app_sign = '--sign "$identity" ' + "\\\n" + '        "$APP_DIR"'
    python_sign_index = source.index(python_sign)
    manifest_refresh_index = source.index(
        "    refresh_embedded_python_manifest\n", python_sign_index
    )
    app_sign_index = source.index(app_sign)
    assert python_sign_index < manifest_refresh_index < app_sign_index


def test_mac_packager_sanitizes_dmg_before_distribution_trust_checks(project_root):
    source = (project_root / "scripts/package_macos_release.sh").read_text(
        encoding="utf-8"
    )

    xattr_cleanup = '/usr/bin/xattr -c "$WORK_DMG_PATH"'
    acl_cleanup = '/bin/chmod -N "$WORK_DMG_PATH"'
    dmg_sign = 'run_clean /usr/bin/codesign --force --timestamp --sign "$identity" "$WORK_DMG_PATH"'
    notarize = 'run_clean /usr/bin/xcrun notarytool submit "$WORK_DMG_PATH"'
    staple_validate = 'run_clean /usr/bin/xcrun stapler validate "$WORK_DMG_PATH"'
    final_xattr_read = 'dmg_extended_attributes="$(/usr/bin/xattr "$WORK_DMG_PATH")"'
    mounted_audit = '"$AUDIT_SCRIPT" --allow-symlink Applications "$mount_dir"'
    final_source_check = 'if [[ "$MODE" == "distribution" ]] && ! reverify_distribution_source; then'
    metadata_publish = '/bin/ln "$WORK_METADATA_PATH" "$METADATA_PATH"'

    assert source.count(xattr_cleanup) == 1
    assert source.count(acl_cleanup) == 1
    assert source.index(xattr_cleanup) < source.index(dmg_sign) < source.index(notarize)
    assert source.index(acl_cleanup) < source.index(dmg_sign)
    assert source.index(staple_validate) < source.index(final_xattr_read)
    assert "xattr_names_are_allowed" in source
    assert '"$AUDIT_SCRIPT" --metadata-only "$WORK_DMG_PATH"' in source
    assert source.index(final_xattr_read) < source.index(mounted_audit)
    assert source.index(mounted_audit) < source.index(final_source_check)
    assert source.index(final_source_check) < source.index(metadata_publish)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS release harness")
def test_mac_packager_requires_a_verified_annotated_tag(project_root, tmp_path):
    if not Path("/usr/bin/ssh-keygen").is_file():
        pytest.skip("system ssh-keygen is unavailable")
    developer_dir = Path(
        subprocess.run(
            ["/usr/bin/xcode-select", "-p"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
    )
    swift_tool = Path(
        subprocess.run(
            ["/usr/bin/xcrun", "--find", "swift"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
    ).resolve()
    if developer_dir.stat().st_uid != 0 or swift_tool.stat().st_uid != 0:
        pytest.skip("distribution packaging requires a root-owned toolchain")

    repository = tmp_path / "project"
    script_directory = repository / "scripts"
    script_directory.mkdir(parents=True)
    package_script = script_directory / "package_macos_release.sh"
    package_script.write_bytes(
        (project_root / "scripts/package_macos_release.sh").read_bytes()
    )
    package_script.chmod(0o755)
    (repository / "LICENSE").write_text("test\n", encoding="utf-8")

    def git(*arguments: str, check: bool = True):
        return subprocess.run(
            ["/usr/bin/git", "-C", str(repository), *arguments],
            check=check,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    environment = os.environ.copy()
    for name in (
        "PCH_APP_VERSION",
        "PCH_CODESIGN_IDENTITY",
        "PCH_CODESIGN_TEAM_ID",
        "PCH_CODESIGN_CERT_SHA256",
        "PCH_NOTARY_PROFILE",
        "PCH_RELEASE_SIGNER_PUBLIC_KEY",
        "PCH_RELEASE_SIGNER_SHA256",
    ):
        environment.pop(name, None)

    def package(*arguments: str):
        return subprocess.run(
            [str(package_script), *arguments],
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )

    git("init", "-q")
    git("config", "user.name", "Heznpc")
    git("config", "user.email", "heznpc@example.invalid")
    git("add", "scripts/package_macos_release.sh", "LICENSE")
    git("commit", "-qm", "fixture")

    head_commit = git("rev-parse", "HEAD").stdout.strip()
    replacement_commit = git(
        "commit-tree",
        "HEAD^{tree}",
        "-p",
        "HEAD",
        "-m",
        "replacement fixture",
    ).stdout.strip()
    git("replace", head_commit, replacement_commit)
    replaced = package("--check")
    assert replaced.returncode == 2
    assert "Git replace refs" in replaced.stderr
    git("replace", "-d", head_commit)

    def generate_key(name: str) -> tuple[Path, str, str]:
        private_key = tmp_path / name
        subprocess.run(
            [
                "/usr/bin/ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "test-key",
                "-f",
                str(private_key),
            ],
            check=True,
        )
        public_key_path = private_key.with_suffix(".pub")
        public_key = " ".join(
            public_key_path.read_text(encoding="utf-8").split()[:2]
        )
        fingerprint = subprocess.run(
            ["/usr/bin/ssh-keygen", "-E", "sha256", "-lf", str(public_key_path)],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.split()[1]
        return private_key, public_key, fingerprint

    signing_key, signing_public_key, signing_fingerprint = generate_key("signing-key")
    environment["PCH_RELEASE_SIGNER_PUBLIC_KEY"] = signing_public_key
    environment["PCH_RELEASE_SIGNER_SHA256"] = signing_fingerprint
    git("config", "gpg.format", "ssh")
    git("config", "user.signingkey", str(signing_key))

    git("tag", "v0.3.0")
    lightweight = package()
    assert lightweight.returncode == 2
    assert "annotated tag object" in lightweight.stderr

    git("tag", "-d", "v0.3.0")
    git("tag", "-a", "v0.3.0", "-m", "unsigned fixture")
    unsigned = package()
    assert unsigned.returncode == 2
    assert "pinned SSH signature validation" in unsigned.stderr

    git("tag", "-d", "v0.3.0")
    signed_tag = git("tag", "-s", "v0.3.0", "-m", "signed fixture", check=False)
    if signed_tag.returncode != 0:
        pytest.skip(f"system Git cannot create SSH-signed tags: {signed_tag.stderr}")

    check_result = package("--check")
    assert check_result.returncode == 0, check_result.stderr
    assert "tagObjectType\ttag" in check_result.stdout
    assert "tagSignatureVerified\ttrue" in check_result.stdout
    assert "tagSignerPrincipal\theznpc" in check_result.stdout
    assert f"tagSignerFingerprint\t{signing_fingerprint}" in check_result.stdout
    assert "cleanWorktree\ttrue" in check_result.stdout

    signed_object = git("rev-parse", "refs/tags/v0.3.0").stdout.strip()
    git("update-ref", "refs/tags/v9.9.9", signed_object)
    environment["PCH_APP_VERSION"] = "9.9.9"
    mismatched_internal_name = package("--check")
    assert mismatched_internal_name.returncode == 0, mismatched_internal_name.stderr
    assert "tagObjectType\ttag" in mismatched_internal_name.stdout
    assert "tagSignatureVerified\tfalse" in mismatched_internal_name.stdout
    assert "tagSignerPrincipal\tmissing" in mismatched_internal_name.stdout
    environment.pop("PCH_APP_VERSION")

    _other_key, other_public_key, other_fingerprint = generate_key("other-key")
    environment["PCH_RELEASE_SIGNER_PUBLIC_KEY"] = other_public_key
    environment["PCH_RELEASE_SIGNER_SHA256"] = other_fingerprint
    wrong_signer = package("--check")
    assert wrong_signer.returncode == 0, wrong_signer.stderr
    assert "tagSignatureVerified\tfalse" in wrong_signer.stdout
    assert "tagSignerPrincipal\tmissing" in wrong_signer.stdout

    environment["PCH_RELEASE_SIGNER_PUBLIC_KEY"] = signing_public_key
    environment["PCH_RELEASE_SIGNER_SHA256"] = signing_fingerprint

    signed_distribution = package()
    assert signed_distribution.returncode == 2
    assert "PCH_CODESIGN_IDENTITY is required" in signed_distribution.stderr


def test_dmg_raw_bytes_require_mounted_tree_audit(tmp_path):
    image = tmp_path / "compressed.dmg"
    image.write_bytes(b"random-binary-private@example.org")

    rules = {finding.rule for finding in audit_path(image, set())}

    assert rules == {"unexpanded-disk-image"}


def test_source_finder_launcher_uses_protected_clean_environment(project_root):
    source = (project_root / "scan.command").read_text(encoding="utf-8")

    assert source.startswith("#!/bin/bash -p")
    assert 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin"' in source
    assert "unset BASH_ENV ENV CDPATH GLOBIGNORE" in source
    assert "/usr/bin/env -i" in source
    assert "run_clean /bin/bash -p" in source


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS release harness")
def test_mac_packager_ignores_hostile_interpreter_environment(project_root, tmp_path):
    marker = tmp_path / "bash-env-ran"
    script_directory = tmp_path / "project" / "scripts"
    script_directory.mkdir(parents=True)
    package_script = script_directory / "package_macos_release.sh"
    package_script.write_bytes(
        (project_root / "scripts/package_macos_release.sh").read_bytes()
    )
    package_script.chmod(0o755)
    payload = tmp_path / "payload.sh"
    payload.write_text(f'/usr/bin/touch "{marker}"\n', encoding="utf-8")
    hostile_bin = tmp_path / "bin"
    hostile_bin.mkdir()
    for name in ("python3", "swift"):
        shim = hostile_bin / name
        shim.write_text(f'#!/bin/sh\n/usr/bin/touch "{marker}"\nexit 99\n', encoding="utf-8")
        shim.chmod(0o755)
    site = tmp_path / "sitecustomize.py"
    site.write_text(f'import pathlib; pathlib.Path({str(marker)!r}).touch()\n', encoding="utf-8")
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": str(hostile_bin),
            "BASH_ENV": str(payload),
            "PYTHONPATH": str(tmp_path),
            "DEVELOPER_DIR": str(tmp_path),
            "TOOLCHAINS": "attacker",
            "SWIFT_EXEC": str(hostile_bin / "swift"),
        }
    )

    result = subprocess.run(
        [str(package_script), "--check"],
        cwd=script_directory.parent,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert not marker.exists()


def test_scanners_resolve_ignored_or_user_config_before_template(project_root):
    mac = (project_root / "scripts/scanner.sh").read_text(encoding="utf-8")
    windows = (project_root / "scripts/scanner.ps1").read_text(encoding="utf-8-sig")

    for source in (mac, windows):
        assert "config.example.json" in source
        assert "config.json" in source
    # The support directory component comes from the shared module so the rename
    # migration keeps a single source of truth. Assert the composed path rather
    # than a hard-coded product name.
    user_config = 'Library/Application Support/$SUPPORT_DIR_NAME/config.json'
    assert user_config in mac
    assert mac.index(user_config) < mac.index("${PROJECT_DIR}/data/config.json")
    assert "LOCALAPPDATA" in windows


@pytest.mark.skipif(sys.platform != "darwin", reason="runs the macOS scanner entry point")
def test_release_extracted_scanner_does_not_abort_on_a_missing_module(project_root, tmp_path):
    """Run the extracted scanner through its explicit runtime validation path.

    The validation command sources every module shipped in the source archive,
    prints a fixed milestone, and exits before collecting system state.  A clean
    exit therefore proves the entry point reached the line after its dynamic
    imports; merely killing a still-running scan after a few seconds did not.
    """
    module = load_release_smoke(project_root)
    extracted = tmp_path / "extracted"
    for rel in module.MACOS_FILES:
        src = project_root / rel
        if not src.is_file():
            continue
        dst = extracted / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        dst.chmod(src.stat().st_mode)

    isolated_home = tmp_path / "home"
    isolated_home.mkdir(mode=0o700)
    environment = os.environ.copy()
    environment["HOME"] = str(isolated_home)
    result = subprocess.run(
        ["/bin/bash", "scripts/scanner.sh", "--validate-runtime"],
        cwd=extracted,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "Modore scanner runtime valid\n"
    assert result.stderr == ""
    assert list(isolated_home.iterdir()) == []


def test_mac_source_release_ships_the_ai_work_audit(project_root):
    """The Mac source release must contain the AI work audit used by Modore.

    README presents the user-facing capability rather than the internal module
    name, but omitting its CLI implementation would still make the documented
    source build incomplete.
    """
    module = load_release_smoke(project_root)
    assert "scripts/scree.py" in module.MACOS_FILES


def test_release_ships_frictions_and_the_mcp_surfaces_dependencies(project_root):
    """friction.py imports scree.py at module scope, and mcp_server.py runs both
    as subprocesses. Shipping any one of the three without the others produces a
    release where the documented command fails at import or at first call — the
    exact failure mode the scree test above exists to prevent, one layer up."""
    module = load_release_smoke(project_root)
    for script in ("scripts/scree.py", "scripts/friction.py", "scripts/moraine.py",
                   "scripts/mcp_server.py"):
        assert script in module.MACOS_FILES


# MothballCore's destructive half. These are linked into Modore's binary by the
# vendor dependency but must stay unreachable from Modore's own code until the
# approval discipline below is satisfied.
MOTHBALL_DESTRUCTIVE_SYMBOLS = (
    "ArchiveOrchestrator",
    "Restorer",
    "ArchiveRun",
    "trashItem",
)


def test_modore_cannot_reach_mothballs_destructive_api(project_root):
    """Absorbing Mothball absorbed two different deletion disciplines, and only
    one of them is Modore's.

    Modore destroys nothing without a preview that issues a single-use 64-byte
    approval token, a 15-minute owner-only manifest naming canonical paths and
    measured sizes, a remeasure at the destructive boundary, and a receipt --
    `create_approval_manifest` / `consume_approval_manifest` in cleanup.sh, the
    token check in CleanupModels.swift, the staging in RuntimeWorkspace. That
    chain is what README's "destruction is gated on an on-screen human
    approval" actually refers to.

    MothballCore's `ArchiveOrchestrator.archive()` is careful in its own right
    -- it refuses `/` and `$HOME`, verifies the archive before touching the
    original, and moves to Trash rather than unlinking -- but it is an
    IN-PROCESS Swift call that takes no token and consumes no manifest. It is
    already compiled into Modore's binary through the vendor dependency, so
    nothing but this test stands between a future `try orchestrator.archive(…)`
    in a view action and a second deletion path that the approval chain never
    sees.

    An approval token elsewhere in the same source file does not prove the
    destructive call consumed it. Until this dependency is split into a
    read-only product or the call boundary accepts Modore's approval manifest,
    Modore source must not name the destructive symbols at all.
    """
    sources = sorted((project_root / "macos" / "Modore" / "Sources").rglob("*.swift"))
    assert sources, "expected Modore Swift sources to exist"

    reachable: list[str] = []
    for path in sources:
        text = path.read_text(encoding="utf-8")
        # Comments explain the boundary; only code may not cross it.
        code = "\n".join(line for line in text.splitlines()
                          if not line.lstrip().startswith(("//", "///", "*")))
        touched = [sym for sym in MOTHBALL_DESTRUCTIVE_SYMBOLS if sym in code]
        if touched:
            rel = path.relative_to(project_root)
            reachable.append(f"{rel}: {', '.join(touched)}")

    assert not reachable, (
        "Mothball's destructive API is reachable from Modore source. Keep the "
        "dependency read-only until its call boundary enforces Modore's approval "
        "manifest:\n  " + "\n  ".join(reachable))


def test_the_shipped_mothball_surface_is_scan_and_classify_only(project_root):
    """The other half of the same boundary, stated positively: what Modore
    actually uses from MothballCore today is its read-only git inspection.

    Pinned because the import is what makes the destructive half available --
    `import MothballCore` brings the whole module, not the two types
    MothballService names -- so the harmless-looking line is the one worth
    keeping under review."""
    service = (project_root / "macos" / "Modore" / "Sources" / "Modore"
               / "Services" / "MothballService.swift").read_text(encoding="utf-8")
    assert "RepoScanner()" in service
    assert "SafetyClassifier" in service
    for destructive in MOTHBALL_DESTRUCTIVE_SYMBOLS:
        assert destructive not in service


@pytest.mark.skipif(sys.platform != "darwin", reason="swift build is macOS-only")
def test_release_extracted_swift_package_actually_builds(project_root, tmp_path):
    """Ground truth for the Package.swift -> vendor/mothball local dependency:
    copy exactly what MACOS_FILES ships into a clean directory and run a real
    `swift build` from there, the same way a source-release user would.

    Verified directly while wiring this dependency: SwiftPM resolves the
    mothball manifest structurally, so every target it declares — including
    MothballApp and MothballCoreTests, which Modore's own product never
    imports — must have its source directory present, or the build fails at
    manifest resolution before compiling anything (deleting only
    Sources/MothballApp from an otherwise complete checkout reproduces this).
    A file-list assertion can't catch that class of failure; only an actual
    build can."""
    module = load_release_smoke(project_root)
    extracted = tmp_path / "extracted"
    for rel in module.MACOS_FILES:
        src = project_root / rel
        if not src.is_file():
            continue
        dst = extracted / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        dst.chmod(src.stat().st_mode)

    result = subprocess.run(
        ["swift", "build", "--package-path", "macos/Modore"],
        cwd=extracted,
        capture_output=True,
        text=True,
        timeout=300,
    )

    assert result.returncode == 0, (
        f"swift build failed from the extracted release:\nSTDOUT:\n{result.stdout}\n"
        f"STDERR:\n{result.stderr}"
    )
