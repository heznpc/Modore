"""Release boundaries that must remain fail-closed."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import zipfile
from contextlib import nullcontext
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
    assert 'ALLOW_USER_TOOLCHAIN="${PCH_ALLOW_USER_TOOLCHAIN:-0}"' in source
    assert '"$ALLOW_USER_TOOLCHAIN" == "1" && "${PCH_SKIP_ADHOC_SIGN:-0}" == "1"' in source


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
    build_directory = repository / "build" / "macos"
    existing_app = build_directory / "PC Health Check Mac.app"
    existing_app.mkdir(parents=True)
    sentinel = existing_app / "user-file.txt"
    sentinel.write_text("preserve me\n", encoding="utf-8")
    environment = os.environ.copy()
    environment["PCH_BUILD_DIR"] = str(build_directory)

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
    source = (project_root / "검사하기.command").read_text(encoding="utf-8")

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
    assert "Library/Application Support/PC Health Check/config.json" in mac
    assert mac.index("Library/Application Support/PC Health Check/config.json") < mac.index(
        "${PROJECT_DIR}/data/config.json"
    )
    assert "LOCALAPPDATA" in windows
