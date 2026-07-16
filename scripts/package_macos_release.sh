#!/bin/bash -p
# Build and verify a standalone Mac app. Distribution mode is tag/sign/notary gated.

set -euo pipefail
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
APP_NAME="PC Health Check Mac.app"
VERSION="${PCH_APP_VERSION:-0.3.0}"
MINIMUM_SYSTEM_VERSION="${PCH_MINIMUM_SYSTEM_VERSION:-13.0}"
ARCH_REQUEST="${PCH_BUILD_ARCHS:-universal}"
DIST_DIR="${PCH_DISTRIBUTION_DIR:-$ROOT_DIR/dist}"
MODE="distribution"
SKIP_NOTARIZATION=0

usage() {
    /usr/bin/printf '%s\n' \
        "Usage: scripts/package_macos_release.sh [--check|--local|--skip-notarization]" \
        "" \
        "  --check              Report prerequisites and release-gate state; do not build." \
        "  --local              Build an ad-hoc signed DMG under dist/local/." \
        "  --skip-notarization  Build a signed, explicitly non-publishable smoke artifact." \
        "" \
        "Distribution environment:" \
        "  PCH_CODESIGN_IDENTITY       Developer ID Application identity." \
        "  PCH_CODESIGN_TEAM_ID        Expected 10-character Apple Team ID." \
        "  PCH_CODESIGN_CERT_SHA256    Expected leaf certificate SHA-256 (64 hex)." \
        "  PCH_NOTARY_PROFILE          notarytool Keychain profile name." \
        "  PCH_RELEASE_SIGNER_PUBLIC_KEY  SSH public key (type + base64, no comment)." \
        "  PCH_RELEASE_SIGNER_SHA256      Expected OpenSSH SHA256 fingerprint." \
        "  PCH_APP_VERSION             Version whose v<version> tag must point at HEAD." \
        "  PCH_BUILD_ARCHS             universal (default), arm64, or x86_64." \
        "  PCH_MINIMUM_SYSTEM_VERSION  Deployment target (default: 13.0)."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check" ;;
        --local) MODE="local" ;;
        --skip-notarization) SKIP_NOTARIZATION=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            /usr/bin/printf 'ERROR: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [[ "$MODE" == "local" && "$SKIP_NOTARIZATION" == "1" ]]; then
    /usr/bin/printf 'ERROR: --local is already unsigned for distribution; do not combine it with --skip-notarization.\n' >&2
    exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_APP_VERSION must be a numeric X.Y.Z version: %s\n' "$VERSION" >&2
    exit 64
fi
if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: macOS packaging requires macOS.\n' >&2
    exit 1
fi

current_uid="$(/usr/bin/id -u)"
account_home="$(/usr/bin/dscacheutil -q user -a uid "$current_uid" 2>/dev/null \
    | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
[[ -n "$account_home" && "$account_home" == /* && -d "$account_home" && ! -L "$account_home" ]] || {
    /usr/bin/printf 'ERROR: cannot establish the current account home directory.\n' >&2
    exit 1
}
[[ -n "$user_temp" && "$user_temp" == /* && -d "$user_temp" && ! -L "$user_temp" ]] || {
    /usr/bin/printf 'ERROR: cannot establish the current account temporary directory.\n' >&2
    exit 1
}
account_home="$(cd -P "$account_home" && /bin/pwd -P)"
user_temp="$(cd -P "$user_temp" && /bin/pwd -P)"
for trusted_directory in "$account_home" "$user_temp"; do
    owner_uid="$(/usr/bin/stat -f '%u' "$trusted_directory")"
    permissions="$(/usr/bin/stat -f '%Lp' "$trusted_directory")"
    if [[ "$owner_uid" != "$current_uid" || $((8#$permissions & 0022)) -ne 0 ]]; then
        /usr/bin/printf 'ERROR: unsafe owner or permissions on trusted directory: %s\n' "$trusted_directory" >&2
        exit 1
    fi
done
clean_environment=(
    "HOME=$account_home"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=$user_temp"
    "LANG=en_US.UTF-8"
    "LC_ALL=en_US.UTF-8"
)
run_clean() {
    /usr/bin/env -i "${clean_environment[@]}" "$@"
}
run_clean_git() {
    /usr/bin/env -i "${clean_environment[@]}" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_NO_REPLACE_OBJECTS=1 \
        /usr/bin/git --no-replace-objects -c core.fsmonitor=false "$@"
}
release_signer_principal="heznpc"
release_signer_public_key="${PCH_RELEASE_SIGNER_PUBLIC_KEY:-}"
release_signer_fingerprint="${PCH_RELEASE_SIGNER_SHA256:-}"
release_signer_configured=false
prepare_release_signer() {
    local key_type key_data key_extra fingerprint_line actual_fingerprint
    if [[ -z "$release_signer_public_key" && -z "$release_signer_fingerprint" ]]; then
        return 0
    fi
    if [[ -z "$release_signer_public_key" || -z "$release_signer_fingerprint" ]]; then
        /usr/bin/printf 'ERROR: PCH_RELEASE_SIGNER_PUBLIC_KEY and PCH_RELEASE_SIGNER_SHA256 must be set together.\n' >&2
        return 2
    fi
    if [[ "$release_signer_public_key" == *$'\n'* || "$release_signer_public_key" == *$'\r'* ]]; then
        /usr/bin/printf 'ERROR: release signer public key must be a single line.\n' >&2
        return 2
    fi
    IFS=$' \t' read -r key_type key_data key_extra <<< "$release_signer_public_key"
    if [[ -z "$key_type" || -z "$key_data" || -n "$key_extra" \
        || "$release_signer_public_key" != "$key_type $key_data" ]]; then
        /usr/bin/printf 'ERROR: release signer public key must contain only key type and key data.\n' >&2
        return 2
    fi
    if [[ ! "$release_signer_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
        /usr/bin/printf 'ERROR: PCH_RELEASE_SIGNER_SHA256 is not an OpenSSH SHA-256 fingerprint.\n' >&2
        return 2
    fi
    [[ -x /usr/bin/ssh-keygen ]] || {
        /usr/bin/printf 'ERROR: trusted /usr/bin/ssh-keygen is unavailable.\n' >&2
        return 2
    }
    fingerprint_line="$(/usr/bin/printf '%s\n' "$release_signer_public_key" \
        | run_clean /usr/bin/ssh-keygen -E sha256 -lf -)" || {
        /usr/bin/printf 'ERROR: release signer public key is invalid.\n' >&2
        return 2
    }
    actual_fingerprint="$(/usr/bin/printf '%s\n' "$fingerprint_line" | /usr/bin/awk '{print $2; exit}')"
    if [[ "$actual_fingerprint" != "$release_signer_fingerprint" ]]; then
        /usr/bin/printf 'ERROR: release signer public key does not match expected SHA-256 fingerprint.\n' >&2
        return 2
    fi
    release_signer_configured=true
}
release_signer_files_are_valid() {
    local fingerprint_line actual_fingerprint
    [[ "$release_signer_configured" == "true" ]] || return 1
    fingerprint_line="$(/usr/bin/printf '%s\n' "$release_signer_public_key" \
        | run_clean /usr/bin/ssh-keygen -E sha256 -lf -)" || return 1
    actual_fingerprint="$(/usr/bin/printf '%s\n' "$fingerprint_line" | /usr/bin/awk '{print $2; exit}')"
    [[ "$actual_fingerprint" == "$release_signer_fingerprint" ]]
}
run_clean_git_verify_tag() {
    local tag_object_id="$1"
    local expected_tag_name="$2"
    release_signer_files_are_valid || return 1
    run_clean /usr/bin/python3 -I -B - \
        "$ROOT_DIR" "$tag_object_id" "$release_signer_principal" \
        "$release_signer_public_key" "$release_signer_fingerprint" \
        "$expected_tag_name" <<'PY'
import os
import subprocess
import sys
import tempfile

(
    root,
    tag_object_id,
    principal,
    public_key,
    expected_fingerprint,
    expected_tag,
) = sys.argv[1:]
environment = {
    "HOME": os.environ["HOME"],
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "LC_ALL": "C",
}
fingerprint = subprocess.run(
    ["/usr/bin/ssh-keygen", "-E", "sha256", "-lf", "-"],
    input=public_key + "\n",
    text=True,
    encoding="utf-8",
    capture_output=True,
    env=environment,
    check=False,
)
fields = fingerprint.stdout.split()
if fingerprint.returncode != 0 or len(fields) < 2 or fields[1] != expected_fingerprint:
    raise SystemExit(2)
with tempfile.TemporaryFile(mode="w+b") as allowed_signers:
    os.fchmod(allowed_signers.fileno(), 0o400)
    allowed_signers.write(f"{principal} {public_key}\n".encode("utf-8"))
    allowed_signers.flush()
    os.fsync(allowed_signers.fileno())
    allowed_signers.seek(0)
    with tempfile.TemporaryFile(mode="w+b") as signature_file:
        tag = subprocess.run(
            [
                "/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false",
                "-C", root, "cat-file", "tag", tag_object_id,
            ],
            capture_output=True,
            env=environment,
            check=False,
        )
        marker = b"-----BEGIN SSH SIGNATURE-----"
        marker_offset = tag.stdout.rfind(marker)
        if tag.returncode != 0 or marker_offset <= 0:
            raise SystemExit(2)
        signed_payload = tag.stdout[:marker_offset]
        signature = tag.stdout[marker_offset:]
        header, separator, _ = signed_payload.partition(b"\n\n")
        try:
            expected_tag_header = b"tag " + expected_tag.encode("ascii")
        except UnicodeEncodeError:
            raise SystemExit(2)
        tag_headers = [
            line
            for line in header.split(b"\n")
            if line == b"tag"
            or line.startswith((b"tag ", b"tag\t", b"tag\r", b"tag\v", b"tag\f"))
        ]
        if separator != b"\n\n" or tag_headers != [expected_tag_header]:
            raise SystemExit(2)
        if not signature.rstrip().endswith(b"-----END SSH SIGNATURE-----"):
            raise SystemExit(2)
        signature_file.write(signature)
        signature_file.flush()
        os.fsync(signature_file.fileno())
        signature_file.seek(0)
        allowed_path = f"/dev/fd/{allowed_signers.fileno()}"
        signature_path = f"/dev/fd/{signature_file.fileno()}"
        result = subprocess.run(
            [
                "/usr/bin/ssh-keygen", "-Y", "verify",
                "-f", allowed_path,
                "-I", principal,
                "-n", "git",
                "-s", signature_path,
            ],
            input=signed_payload,
            env=environment,
            pass_fds=(allowed_signers.fileno(), signature_file.fileno()),
            check=False,
        )
        raise SystemExit(result.returncode)
PY
}
prepare_release_signer
resolve_trusted_tool_link() {
    local source="$1"
    local target directory
    if [[ -L "$source" ]]; then
        target="$(/usr/bin/readlink "$source")" || return 1
        [[ "$target" == /* ]] || target="$(/usr/bin/dirname "$source")/$target"
    else
        target="$source"
    fi
    directory="$(cd -P "$(/usr/bin/dirname "$target")" && /bin/pwd -P)" || return 1
    target="$directory/$(/usr/bin/basename "$target")"
    [[ -f "$target" && ! -L "$target" && -x "$target" ]] || return 1
    /usr/bin/printf '%s\n' "$target"
}

required_commands=(codesign hdiutil ditto shasum xcrun plutil tar)
for command_name in "${required_commands[@]}"; do
    if ! /usr/bin/command -v "$command_name" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: required command missing: %s\n' "$command_name" >&2
        exit 1
    fi
done
[[ -x /usr/bin/python3 ]] || {
    /usr/bin/printf 'ERROR: required command missing: /usr/bin/python3\n' >&2
    exit 1
}

developer_dir="$(run_clean /usr/bin/xcode-select -p)"
swift_tool="$(run_clean /usr/bin/xcrun --find swift)"
swift_real="$(resolve_trusted_tool_link "$swift_tool")" || {
    /usr/bin/printf 'ERROR: selected Swift tool link is unsafe.\n' >&2
    exit 1
}
case "$developer_dir" in
    /Applications/*.app/Contents/Developer|/Library/Developer/CommandLineTools) ;;
    *) /usr/bin/printf 'ERROR: selected developer directory is outside trusted system locations.\n' >&2; exit 1 ;;
esac
for trusted_tool_path in "$developer_dir" "$swift_real"; do
    tool_owner="$(/usr/bin/stat -f '%u' "$trusted_tool_path")"
    tool_permissions="$(/usr/bin/stat -f '%Lp' "$trusted_tool_path")"
    if [[ $((8#$tool_permissions & 0022)) -ne 0 \
        || ( "$tool_owner" != "0" \
            && ( "$MODE" == "distribution" || "$tool_owner" != "$current_uid" ) ) ]]; then
        /usr/bin/printf 'ERROR: selected toolchain owner or permissions are unsafe for this packaging mode: %s\n' \
            "$trusted_tool_path" >&2
        exit 1
    fi
done
[[ "$developer_dir" == /* && -d "$developer_dir" && ! -L "$developer_dir" \
    && "$swift_tool" == "$developer_dir/"* && "$swift_real" == "$developer_dir/"* \
    && -x "$swift_tool" && -x "$swift_real" ]] || {
    /usr/bin/printf 'ERROR: selected Xcode/Swift toolchain path is unsafe.\n' >&2
    exit 1
}
swift_version_output="$(run_clean /usr/bin/xcrun swift --version 2>&1)"
swift_version="${swift_version_output%%$'\n'*}"

expected_tag="v$VERSION"
expected_tag_ref="refs/tags/$expected_tag"
tag_object_type=""
tag_object_id=""
tag_target_commit=""
tag_at_head=""
tag_signature_verified=false
tag_signer_principal=""
tag_signer_fingerprint=""
if [[ -x /usr/bin/git ]] \
    && run_clean_git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_repository=true
    replace_refs="$(run_clean_git -C "$ROOT_DIR" replace -l)" || {
        /usr/bin/printf 'ERROR: cannot verify that Git replace refs are absent.\n' >&2
        exit 2
    }
    if [[ -n "$replace_refs" ]]; then
        /usr/bin/printf 'ERROR: release tooling refuses repositories with Git replace refs.\n' >&2
        exit 2
    fi
    head_commit="$(run_clean_git -C "$ROOT_DIR" rev-parse HEAD)"
    short_commit="$(run_clean_git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
    if [[ -z "$(run_clean_git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
        git_clean=true
    else
        git_clean=false
    fi
    tag_object_id="$(run_clean_git -C "$ROOT_DIR" rev-parse --verify "$expected_tag_ref" 2>/dev/null || true)"
    if [[ -n "$tag_object_id" ]]; then
        tag_object_type="$(run_clean_git -C "$ROOT_DIR" cat-file -t "$tag_object_id" 2>/dev/null || true)"
        tag_target_commit="$(run_clean_git -C "$ROOT_DIR" rev-parse --verify "$tag_object_id^{commit}" 2>/dev/null || true)"
    fi
    if [[ -n "$tag_target_commit" && "$tag_target_commit" == "$head_commit" ]]; then
        tag_at_head="$expected_tag"
    fi
    if [[ "$tag_object_type" == "tag" && "$tag_target_commit" == "$head_commit" \
        && "$release_signer_configured" == "true" ]] \
        && run_clean_git_verify_tag "$tag_object_id" "$expected_tag" >/dev/null 2>&1; then
        tag_signature_verified=true
        tag_signer_principal="$release_signer_principal"
        tag_signer_fingerprint="$release_signer_fingerprint"
    fi
else
    git_repository=false
    head_commit=""
    short_commit="source"
    git_clean=false
fi

if [[ "$MODE" == "check" ]]; then
    identity_count="$(run_clean /usr/bin/security find-identity -p codesigning -v 2>/dev/null | /usr/bin/grep -c 'Developer ID Application' || true)"
    /usr/bin/printf 'mode\tcheck\n'
    /usr/bin/printf 'version\t%s\n' "$VERSION"
    /usr/bin/printf 'expectedTag\t%s\n' "$expected_tag"
    /usr/bin/printf 'gitRepository\t%s\n' "$git_repository"
    /usr/bin/printf 'tagAtHead\t%s\n' "$([[ -n "$tag_at_head" ]] && echo true || echo false)"
    /usr/bin/printf 'tagObjectType\t%s\n' "${tag_object_type:-missing}"
    /usr/bin/printf 'tagSignatureVerified\t%s\n' "$tag_signature_verified"
    /usr/bin/printf 'tagSignerPrincipal\t%s\n' "${tag_signer_principal:-missing}"
    /usr/bin/printf 'tagSignerFingerprint\t%s\n' "${tag_signer_fingerprint:-missing}"
    /usr/bin/printf 'releaseSignerConfigured\t%s\n' "$release_signer_configured"
    /usr/bin/printf 'cleanWorktree\t%s\n' "$git_clean"
    /usr/bin/printf 'commit\t%s\n' "${head_commit:-unavailable}"
    /usr/bin/printf 'architectureRequest\t%s\n' "$ARCH_REQUEST"
    /usr/bin/printf 'minimumSystemVersion\t%s\n' "$MINIMUM_SYSTEM_VERSION"
    /usr/bin/printf 'developerIdIdentities\t%s\n' "$identity_count"
    /usr/bin/printf 'codesignIdentityConfigured\t%s\n' "$([[ -n "${PCH_CODESIGN_IDENTITY:-}" ]] && echo true || echo false)"
    /usr/bin/printf 'codesignTeamConfigured\t%s\n' "$([[ -n "${PCH_CODESIGN_TEAM_ID:-}" ]] && echo true || echo false)"
    /usr/bin/printf 'codesignCertificateFingerprintConfigured\t%s\n' "$([[ -n "${PCH_CODESIGN_CERT_SHA256:-}" ]] && echo true || echo false)"
    /usr/bin/printf 'notaryProfileConfigured\t%s\n' "$([[ -n "${PCH_NOTARY_PROFILE:-}" ]] && echo true || echo false)"
    if run_clean /usr/bin/xcrun --find notarytool >/dev/null 2>&1; then
        /usr/bin/printf 'notarytool\tavailable\n'
    else
        /usr/bin/printf 'notarytool\tmissing\n'
    fi
    exit 0
fi

identity="${PCH_CODESIGN_IDENTITY:-}"
expected_codesign_team_id="${PCH_CODESIGN_TEAM_ID:-}"
expected_codesign_cert_sha256="${PCH_CODESIGN_CERT_SHA256:-}"
notary_profile="${PCH_NOTARY_PROFILE:-}"
if [[ "$MODE" == "distribution" ]]; then
    if [[ "$release_signer_configured" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires PCH_RELEASE_SIGNER_PUBLIC_KEY and PCH_RELEASE_SIGNER_SHA256.\n' >&2
        exit 2
    fi
    if [[ "$git_repository" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires a Git checkout for tag and commit verification.\n' >&2
        exit 2
    fi
    if [[ "$git_clean" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires a clean worktree and index.\n' >&2
        exit 2
    fi
    if [[ -z "$tag_at_head" || "$tag_target_commit" != "$head_commit" ]]; then
        /usr/bin/printf 'ERROR: distribution requires tag %s to resolve exactly to HEAD.\n' "$expected_tag" >&2
        exit 2
    fi
    if [[ "$tag_object_type" != "tag" ]]; then
        /usr/bin/printf 'ERROR: distribution requires %s to be an annotated tag object.\n' "$expected_tag" >&2
        exit 2
    fi
    if [[ "$tag_signature_verified" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires pinned SSH signature validation for %s.\n' "$expected_tag" >&2
        exit 2
    fi
    if [[ -z "$identity" ]]; then
        /usr/bin/printf 'ERROR: PCH_CODESIGN_IDENTITY is required for distribution.\n' >&2
        exit 2
    fi
    if [[ ! "$expected_codesign_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        /usr/bin/printf 'ERROR: PCH_CODESIGN_TEAM_ID must be the expected 10-character Apple Team ID.\n' >&2
        exit 2
    fi
    if [[ ! "$expected_codesign_cert_sha256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        /usr/bin/printf 'ERROR: PCH_CODESIGN_CERT_SHA256 must be the expected 64-hex leaf certificate fingerprint.\n' >&2
        exit 2
    fi
    expected_codesign_cert_sha256="$(/usr/bin/printf '%s' "$expected_codesign_cert_sha256" | /usr/bin/tr '[:lower:]' '[:upper:]')"
    if ! run_clean /usr/bin/security find-identity -p codesigning -v \
        | /usr/bin/grep -F "\"$identity\"" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: configured signing identity is not available in Keychain.\n' >&2
        exit 2
    fi
    if [[ "$SKIP_NOTARIZATION" != "1" && -z "$notary_profile" ]]; then
        /usr/bin/printf 'ERROR: PCH_NOTARY_PROFILE is required for a publishable distribution.\n' >&2
        exit 2
    fi
fi

reverify_distribution_source() {
    local current_replace_refs current_head current_status current_tag_object_id
    local current_tag_object_type current_tag_target_commit
    current_replace_refs="$(run_clean_git -C "$ROOT_DIR" replace -l)" || return 1
    [[ -z "$current_replace_refs" ]] || return 1
    current_head="$(run_clean_git -C "$ROOT_DIR" rev-parse HEAD)" || return 1
    current_status="$(run_clean_git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" || return 1
    current_tag_object_id="$(run_clean_git -C "$ROOT_DIR" rev-parse --verify "$expected_tag_ref" 2>/dev/null)" || return 1
    [[ "$current_head" == "$head_commit" && -z "$current_status" \
        && "$current_tag_object_id" == "$tag_object_id" ]] || return 1
    current_tag_object_type="$(run_clean_git -C "$ROOT_DIR" cat-file -t "$tag_object_id" 2>/dev/null)" || return 1
    current_tag_target_commit="$(run_clean_git -C "$ROOT_DIR" rev-parse --verify "$tag_object_id^{commit}" 2>/dev/null)" || return 1
    [[ "$current_tag_object_type" == "tag" \
        && "$current_tag_target_commit" == "$head_commit" \
        && "$tag_signer_principal" == "$release_signer_principal" \
        && "$tag_signer_fingerprint" == "$release_signer_fingerprint" ]] || return 1
    run_clean_git_verify_tag "$tag_object_id" "$expected_tag" >/dev/null 2>&1
}

package_workspace="$(/usr/bin/mktemp -d "$user_temp/pch-package.XXXXXX")"
artifact_workspace=""
preserve_artifact_workspace=false
mount_dir="$package_workspace/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == "true" ]]; then
        run_clean /usr/bin/hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    fi
    if [[ -n "$artifact_workspace" && "$preserve_artifact_workspace" != "true" ]]; then
        /bin/rm -rf "$artifact_workspace"
    elif [[ -n "$artifact_workspace" ]]; then
        /usr/bin/printf 'WARNING: preserving recovery workspace: %s\n' "$artifact_workspace" >&2
    fi
    /bin/rm -rf "$package_workspace"
}
trap cleanup EXIT

actual_codesign_team_id=""
actual_codesign_cert_sha256=""
last_codesign_artifact_kind=""
last_codesign_snapshot_sha256=""
final_dmg_snapshot_sha256=""
verify_developer_signature_identity() {
    local signed_path="$1"
    local evidence team_id certificate_sha256 artifact_kind artifact_sha256 extra
    evidence="$(run_clean /usr/bin/xcrun swift - \
        "$signed_path" "$identity" "$expected_codesign_team_id" \
        "$expected_codesign_cert_sha256" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation
import Security

guard CommandLine.arguments.count == 5 else { exit(2) }
let path = CommandLine.arguments[1]
let expectedSubject = CommandLine.arguments[2]
let expectedTeam = CommandLine.arguments[3]
let expectedCertificate = CommandLine.arguments[4]

struct AnonymousSnapshot {
    let descriptor: Int32
    let path: String
    let sha256: String
}

func makeAnonymousSnapshot(of sourcePath: String) -> AnonymousSnapshot? {
    let sourceDescriptor = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard sourceDescriptor >= 0 else { return nil }
    defer { close(sourceDescriptor) }

    var sourceStatus = stat()
    guard fstat(sourceDescriptor, &sourceStatus) == 0,
          (sourceStatus.st_mode & S_IFMT) == S_IFREG else { return nil }

    var template = Array((NSTemporaryDirectory() + "/pch-signature-snapshot.XXXXXX").utf8CString)
    let snapshotDescriptor = mkstemp(&template)
    guard snapshotDescriptor >= 0 else { return nil }
    let temporaryPath = String(cString: template)
    guard unlink(temporaryPath) == 0 else {
        close(snapshotDescriptor)
        return nil
    }

    var succeeded = false
    defer {
        if !succeeded {
            close(snapshotDescriptor)
        }
    }
    guard fchmod(snapshotDescriptor, sourceStatus.st_mode & 0o777) == 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
        let count = read(sourceDescriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBytes { bytes in
                write(
                    snapshotDescriptor,
                    bytes.baseAddress!.advanced(by: written),
                    count - written
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                return nil
            }
            written += result
        }
    }

    var snapshotStatus = stat()
    guard fstat(snapshotDescriptor, &snapshotStatus) == 0,
          snapshotStatus.st_size == sourceStatus.st_size,
          fsync(snapshotDescriptor) == 0,
          lseek(snapshotDescriptor, 0, SEEK_SET) == 0 else { return nil }

    var hasher = SHA256()
    while true {
        let count = read(snapshotDescriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    guard lseek(snapshotDescriptor, 0, SEEK_SET) == 0 else { return nil }
    let digest = hasher.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
    succeeded = true
    return AnonymousSnapshot(
        descriptor: snapshotDescriptor,
        path: "/dev/fd/\(snapshotDescriptor)",
        sha256: digest
    )
}

var pathStatus = stat()
guard lstat(path, &pathStatus) == 0,
      (pathStatus.st_mode & S_IFMT) != S_IFLNK else { exit(3) }

var snapshot: AnonymousSnapshot?
let verificationPath: String
let artifactKind: String
let artifactSHA256: String
switch pathStatus.st_mode & S_IFMT {
case S_IFREG:
    guard let created = makeAnonymousSnapshot(of: path) else { exit(3) }
    snapshot = created
    verificationPath = created.path
    artifactKind = "regular"
    artifactSHA256 = created.sha256
case S_IFDIR:
    // Security.framework cannot create SecStaticCode from a directory FD.
    // Bundle paths here are confined to the private package workspace or a
    // read-only mounted image, and no release digest is derived from them.
    verificationPath = path
    artifactKind = "directory"
    artifactSHA256 = "-"
default:
    exit(3)
}
defer {
    if let snapshot {
        close(snapshot.descriptor)
    }
}

var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(
    URL(fileURLWithPath: verificationPath) as CFURL,
    SecCSFlags(),
    &code
) == errSecSuccess, let code else { exit(3) }
let validationFlags = SecCSFlags(rawValue:
    kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
)
guard SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess else { exit(4) }
var information: CFDictionary?
guard SecCodeCopySigningInformation(
    code,
    SecCSFlags(rawValue: kSecCSSigningInformation),
    &information
) == errSecSuccess, let dictionary = information as NSDictionary? else { exit(5) }
let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
guard let leaf = certificates.first else { exit(6) }
let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
let certificate = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
    .map { String(format: "%02X", $0) }
    .joined()
guard subject == expectedSubject,
      team == expectedTeam,
      certificate == expectedCertificate else { exit(7) }
print("\(team)\t\(certificate)\t\(artifactKind)\t\(artifactSHA256)")
SWIFT
)" || {
        /usr/bin/printf 'ERROR: cannot validate pinned Developer ID evidence: %s\n' "$signed_path" >&2
        return 1
    }
    IFS=$'\t' read -r team_id certificate_sha256 artifact_kind artifact_sha256 extra <<< "$evidence"
    if [[ "$team_id" != "$expected_codesign_team_id" \
        || "$certificate_sha256" != "$expected_codesign_cert_sha256" \
        || -n "$extra" ]]; then
        /usr/bin/printf 'ERROR: Developer ID signature does not match the pinned identity, Team ID, and certificate.\n' >&2
        return 1
    fi
    case "$artifact_kind" in
        regular)
            [[ "$artifact_sha256" =~ ^[a-f0-9]{64}$ ]] || {
                /usr/bin/printf 'ERROR: immutable signed-file snapshot did not produce SHA-256 evidence.\n' >&2
                return 1
            }
            ;;
        directory)
            [[ "$artifact_sha256" == "-" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    actual_codesign_team_id="$team_id"
    actual_codesign_cert_sha256="$certificate_sha256"
    last_codesign_artifact_kind="$artifact_kind"
    last_codesign_snapshot_sha256="$artifact_sha256"
}

BUILD_ROOT="$ROOT_DIR"
if [[ "$MODE" == "distribution" ]]; then
    source_archive="$package_workspace/source.tar"
    BUILD_ROOT="$package_workspace/source"
    /bin/mkdir -p "$BUILD_ROOT"
    run_clean_git -C "$ROOT_DIR" archive \
        --format=tar \
        --output="$source_archive" \
        "$head_commit"
    run_clean /usr/bin/tar -xf "$source_archive" -C "$BUILD_ROOT"
fi

PACKAGE_BUILD_DIR="$package_workspace/build"
APP_DIR="$PACKAGE_BUILD_DIR/$APP_NAME"
EXECUTABLE="$APP_DIR/Contents/MacOS/PCHealthCheckMac"
AUDIT_SCRIPT="$BUILD_ROOT/scripts/artifact_audit.py"
build_environment=(
    "PCH_APP_VERSION=$VERSION"
    "PCH_MINIMUM_SYSTEM_VERSION=$MINIMUM_SYSTEM_VERSION"
    "PCH_BUILD_ARCHS=$ARCH_REQUEST"
    "PCH_STRICT_BUILD=1"
    "PCH_BUILD_DIR=$PACKAGE_BUILD_DIR"
)
if [[ "$MODE" == "distribution" ]]; then
    build_environment+=("PCH_SKIP_ADHOC_SIGN=1")
else
    # Hosted macOS CI images can own their preinstalled Xcode as the ephemeral
    # runner account. This exception is restricted to explicitly nonpublishable
    # local artifacts; distribution still requires a root-owned toolchain.
    build_environment+=("PCH_ALLOW_USER_TOOLCHAIN=1")
fi
/usr/bin/env -i "${clean_environment[@]}" "${build_environment[@]}" \
    "$BUILD_ROOT/scripts/build_macos_swift_app.sh"

if [[ "$MODE" == "distribution" ]]; then
    if ! reverify_distribution_source; then
        /usr/bin/printf 'ERROR: source checkout changed while the distribution app was building.\n' >&2
        exit 2
    fi
fi

if [[ ! -x "$EXECUTABLE" ]]; then
    /usr/bin/printf 'ERROR: app executable is missing.\n' >&2
    exit 3
fi
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$APP_DIR/Contents/Info.plist")"
bundle_short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_identifier" != "me.heznpc.pchealthcheck.mac" \
    || "$bundle_version" != "$VERSION" \
    || "$bundle_short_version" != "$VERSION" ]]; then
    /usr/bin/printf 'ERROR: app identity/version does not match the package request.\n' >&2
    exit 3
fi
if [[ -f "$APP_DIR/Contents/Resources/project-root.txt" ]]; then
    /usr/bin/printf 'ERROR: standalone app leaked a local project-root marker.\n' >&2
    exit 3
fi
if [[ ! -x "$APP_DIR/Contents/Resources/runtime/scripts/scanner.sh" ]]; then
    /usr/bin/printf 'ERROR: standalone runtime scanner is missing.\n' >&2
    exit 3
fi
if [[ -e "$APP_DIR/Contents/Resources/runtime/data/config.json" ]]; then
    /usr/bin/printf 'ERROR: standalone app must not bundle a user config.json.\n' >&2
    exit 3
fi
for required_resource in \
    "$APP_DIR/Contents/Resources/runtime/data/config.example.json" \
    "$APP_DIR/Contents/Resources/LICENSE" \
    "$APP_DIR/Contents/Resources/AppIcon.icns"; do
    if [[ ! -f "$required_resource" ]]; then
        /usr/bin/printf 'ERROR: required app resource missing: %s\n' "$required_resource" >&2
        exit 3
    fi
done

bundle_minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
    /usr/bin/printf 'ERROR: bundle minimum macOS %s does not match requested %s.\n' \
        "$bundle_minimum" "$MINIMUM_SYSTEM_VERSION" >&2
    exit 3
fi

actual_architectures="$(run_clean /usr/bin/xcrun lipo -archs "$EXECUTABLE")"
for architecture in $actual_architectures; do
    binary_minimum="$(run_clean /usr/bin/xcrun vtool -show-build -arch "$architecture" "$EXECUTABLE" | /usr/bin/awk '$1 == "minos" {print $2; exit}')"
    if [[ "$binary_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
        /usr/bin/printf 'ERROR: %s slice minimum macOS is %s, expected %s.\n' \
            "$architecture" "${binary_minimum:-unknown}" "$MINIMUM_SYSTEM_VERSION" >&2
        exit 3
    fi
done
if [[ "$actual_architectures" == *"arm64"* && "$actual_architectures" == *"x86_64"* ]]; then
    architecture_label="universal"
elif [[ "$actual_architectures" == "arm64" || "$actual_architectures" == "x86_64" ]]; then
    architecture_label="$actual_architectures"
else
    /usr/bin/printf 'ERROR: unexpected app architectures: %s\n' "$actual_architectures" >&2
    exit 3
fi
if [[ "$ARCH_REQUEST" == "universal" || "$ARCH_REQUEST" == "universal2" ]]; then
    if [[ "$architecture_label" != "universal" ]]; then
        /usr/bin/printf 'ERROR: Universal 2 was requested but the app has: %s\n' "$actual_architectures" >&2
        exit 3
    fi
fi

run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" "$APP_DIR"

signature_kind="ad-hoc"
notarized=false
stapled=false
gatekeeper=false
if [[ "$MODE" == "distribution" ]]; then
    run_clean /usr/bin/codesign \
        --force \
        --strict \
        --options runtime \
        --timestamp \
        --sign "$identity" \
        "$APP_DIR"
    signature_kind="developer-id"
fi
run_clean /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
if [[ "$MODE" == "distribution" ]]; then
    verify_developer_signature_identity "$APP_DIR"
fi
run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" "$APP_DIR"

if [[ "$MODE" == "local" ]]; then
    local_build_id="$short_commit"
    if [[ "$git_repository" == "true" && "$git_clean" != "true" ]]; then
        local_build_id="$local_build_id-dirty"
    fi
    output_dir="$DIST_DIR/local"
    artifact_name="PC-Health-Check-Mac-v$VERSION-local-unsigned-$architecture_label-$local_build_id.dmg"
elif [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    output_dir="$DIST_DIR/local"
    artifact_name="PC-Health-Check-Mac-v$VERSION-signed-not-notarized-$architecture_label-$short_commit.dmg"
else
    output_dir="$DIST_DIR"
    artifact_name="PC-Health-Check-Mac-v$VERSION-$architecture_label.dmg"
fi
DMG_PATH="$output_dir/$artifact_name"
METADATA_PATH="$DMG_PATH.metadata.json"
/bin/mkdir -p "$output_dir"
if [[ -e "$DMG_PATH" || -L "$DMG_PATH" || -e "$METADATA_PATH" || -L "$METADATA_PATH" ]]; then
    /usr/bin/printf 'ERROR: refusing to overwrite an existing artifact: %s\n' "$DMG_PATH" >&2
    exit 4
fi

artifact_workspace="$(/usr/bin/mktemp -d "$output_dir/.pch-package.XXXXXX")"
WORK_DMG_PATH="$artifact_workspace/$artifact_name"
WORK_METADATA_PATH="$artifact_workspace/$artifact_name.metadata.json"
staging_dir="$package_workspace/dmg-staging"
/bin/mkdir -p "$staging_dir" "$mount_dir"

run_clean /usr/bin/ditto --norsrc --noextattr --noacl "$APP_DIR" "$staging_dir/$APP_NAME"
/bin/cp -X "$BUILD_ROOT/LICENSE" "$staging_dir/LICENSE"
/usr/bin/xattr -cr "$staging_dir"
/bin/chmod -RN "$staging_dir"
/bin/ln -s /Applications "$staging_dir/Applications"
run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" --allow-symlink Applications "$staging_dir"

run_clean /usr/bin/hdiutil create \
    -volname "PC Health Check Mac" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    "$WORK_DMG_PATH" >/dev/null
/usr/bin/xattr -c "$WORK_DMG_PATH"
/bin/chmod -N "$WORK_DMG_PATH"

if [[ "$MODE" == "distribution" ]]; then
    run_clean /usr/bin/codesign --force --timestamp --sign "$identity" "$WORK_DMG_PATH"
    run_clean /usr/bin/codesign --verify --strict --verbose=2 "$WORK_DMG_PATH"
    verify_developer_signature_identity "$WORK_DMG_PATH"
    if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
        run_clean /usr/bin/xcrun notarytool submit "$WORK_DMG_PATH" \
            --keychain-profile "$notary_profile" \
            --wait
        notarized=true
        run_clean /usr/bin/xcrun stapler staple "$WORK_DMG_PATH"
        run_clean /usr/bin/xcrun stapler validate "$WORK_DMG_PATH"
        stapled=true
        run_clean /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$WORK_DMG_PATH"
        gatekeeper=true
    fi
fi

# Signing/notarization/stapling must not leave arbitrary Finder metadata or
# ACLs. macOS may retain its protected com.apple.provenance marker even after
# xattr -c; allow that one name only and audit its bytes for secrets/PII.
# This is a read-only post-trust check; do not mutate the final signed DMG.
xattr_names_are_allowed() {
    local names="$1"
    [[ -z "$names" || "$names" == "com.apple.provenance" ]]
}
dmg_extended_attributes="$(/usr/bin/xattr "$WORK_DMG_PATH")" || {
    /usr/bin/printf 'ERROR: cannot inspect final DMG extended attributes.\n' >&2
    exit 5
}
dmg_mode="$(/bin/ls -lde "$WORK_DMG_PATH" | /usr/bin/awk 'NR == 1 {print $1}')"
if ! xattr_names_are_allowed "$dmg_extended_attributes" || [[ "$dmg_mode" == *+* ]]; then
    /usr/bin/printf 'ERROR: final DMG has unexpected extended attributes or ACL entries.\n' >&2
    exit 5
fi
run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" --metadata-only "$WORK_DMG_PATH" >/dev/null
if [[ "$MODE" == "distribution" ]]; then
    run_clean /usr/bin/codesign --verify --strict --verbose=2 "$WORK_DMG_PATH"
    verify_developer_signature_identity "$WORK_DMG_PATH"
    if [[ "$last_codesign_artifact_kind" != "regular" \
        || ! "$last_codesign_snapshot_sha256" =~ ^[a-f0-9]{64}$ ]]; then
        /usr/bin/printf 'ERROR: final DMG did not produce immutable Developer ID snapshot evidence.\n' >&2
        exit 5
    fi
    final_dmg_snapshot_sha256="$last_codesign_snapshot_sha256"
fi

run_clean /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$WORK_DMG_PATH" >/dev/null
mounted=true
run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" --allow-symlink Applications "$mount_dir"
if [[ ! -f "$mount_dir/LICENSE" ]]; then
    /usr/bin/printf 'ERROR: mounted DMG is missing LICENSE.\n' >&2
    exit 5
fi
run_clean /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$APP_NAME"
if [[ "$MODE" == "distribution" ]]; then
    verify_developer_signature_identity "$mount_dir/$APP_NAME"
fi
run_clean /usr/bin/hdiutil detach "$mount_dir" >/dev/null
mounted=false

# hdiutil attach records a host-specific recent-checksum cache xattr on the
# image it inspected. Remove only that known cache through an O_NOFOLLOW file
# descriptor, then bind the pathname back to the same inode. Provenance remains
# allowed and audited; no signed file bytes are changed here.
run_clean /usr/bin/python3 -I -B - "$WORK_DMG_PATH" <<'PY'
import os
import stat
import subprocess
import sys

path = sys.argv[1]
flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(2)
    result = subprocess.run(
        [
            "/usr/bin/xattr",
            "-d",
            "com.apple.diskimages.recentcksum",
            f"/dev/fd/{descriptor}",
        ],
        capture_output=True,
        check=False,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        pass_fds=(descriptor,),
    )
    if result.returncode != 0:
        names = subprocess.run(
            ["/usr/bin/xattr", f"/dev/fd/{descriptor}"],
            capture_output=True,
            check=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
            pass_fds=(descriptor,),
        ).stdout.splitlines()
        if b"com.apple.diskimages.recentcksum" in names:
            raise SystemExit(3)
    after = os.fstat(descriptor)
    entry = os.lstat(path)
    if (
        not stat.S_ISREG(entry.st_mode)
        or (before.st_dev, before.st_ino, before.st_size)
        != (after.st_dev, after.st_ino, after.st_size)
        or (after.st_dev, after.st_ino, after.st_size)
        != (entry.st_dev, entry.st_ino, entry.st_size)
    ):
        raise SystemExit(4)
finally:
    os.close(descriptor)
PY

if [[ "$MODE" == "distribution" ]]; then
    sha256="$final_dmg_snapshot_sha256"
else
    sha256="$(run_clean /usr/bin/shasum -a 256 "$WORK_DMG_PATH" | /usr/bin/awk '{print $1}')"
fi
exact_tag="${tag_at_head:-}"
source_tag_signature_verified=false
source_tag_object_id=""
source_tag_signer_principal=""
source_tag_signer_fingerprint=""
if [[ -n "$exact_tag" ]]; then
    source_tag_object_id="$tag_object_id"
fi
if [[ -n "$exact_tag" && "$git_clean" == "true" && "$tag_signature_verified" == "true" ]]; then
    source_tag_signature_verified=true
    source_tag_signer_principal="$tag_signer_principal"
    source_tag_signer_fingerprint="$tag_signer_fingerprint"
fi
run_clean /usr/bin/python3 -I -B - "$WORK_METADATA_PATH" "$artifact_name" "$VERSION" "$exact_tag" "$head_commit" \
    "$source_tag_object_id" "$source_tag_signature_verified" "$source_tag_signer_principal" "$source_tag_signer_fingerprint" \
    "$git_clean" "$actual_architectures" "$MINIMUM_SYSTEM_VERSION" "$signature_kind" \
    "$actual_codesign_team_id" "$actual_codesign_cert_sha256" \
    "$notarized" "$stapled" "$gatekeeper" "$sha256" "$developer_dir" "$swift_version" <<'PY'
import json
import os
import sys

(
    output,
    artifact,
    version,
    tag,
    commit,
    tag_object_id,
    source_tag_signature_verified,
    tag_signer_principal,
    tag_signer_fingerprint,
    clean,
    architectures,
    minimum_system_version,
    signature,
    codesign_team_id,
    codesign_cert_sha256,
    notarized,
    stapled,
    gatekeeper,
    sha256,
    developer_dir,
    swift_version,
) = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "product": "PC Health Check Mac",
    "brand": "Heznpc",
    "artifact": artifact,
    "version": version,
    "source": {
        "tag": tag or None,
        "commit": commit or None,
        "tagObjectID": tag_object_id or None,
        "clean": clean == "true",
        "tagSignatureVerified": source_tag_signature_verified == "true",
        "tagSignerPrincipal": tag_signer_principal or None,
        "tagSignerFingerprint": tag_signer_fingerprint or None,
    },
    "platform": {
        "architectures": architectures.split(),
        "minimumSystemVersion": minimum_system_version,
        "toolchain": {
            "developerDirectory": developer_dir,
            "swiftVersion": swift_version,
        },
    },
    "trust": {
        "signature": signature,
        "teamIdentifier": codesign_team_id or None,
        "certificateSHA256": codesign_cert_sha256 or None,
        "notarized": notarized == "true",
        "stapled": stapled == "true",
        "gatekeeperAssessed": gatekeeper == "true",
    },
    "audit": {
        "secretScan": True,
        "personalDataScan": True,
        "symlinkScan": True,
    },
    "sha256": sha256,
}
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(output, flags, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    stream.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    stream.flush()
    os.fsync(stream.fileno())
PY

/usr/bin/xattr -c "$WORK_METADATA_PATH"
/bin/chmod -N "$WORK_METADATA_PATH"
run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" "$WORK_METADATA_PATH"
/bin/chmod 644 "$WORK_DMG_PATH" "$WORK_METADATA_PATH"

regular_file_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    /usr/bin/stat -f '%d:%i:%z' "$path"
}
regular_file_inode_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    /usr/bin/stat -f '%d:%i' "$path"
}
staged_dmg_identity="$(regular_file_identity "$WORK_DMG_PATH")"
staged_metadata_identity="$(regular_file_identity "$WORK_METADATA_PATH")"
staged_dmg_inode_identity="$(regular_file_inode_identity "$WORK_DMG_PATH")"
staged_metadata_inode_identity="$(regular_file_inode_identity "$WORK_METADATA_PATH")"
metadata_sha256="$(run_clean /usr/bin/shasum -a 256 "$WORK_METADATA_PATH" | /usr/bin/awk '{print $1}')"

verify_staged_file_bytes() {
    local current_dmg_identity current_metadata_identity current_dmg_hash current_metadata_hash
    local current_dmg_xattrs current_metadata_xattrs current_dmg_mode current_metadata_mode
    current_dmg_identity="$(regular_file_identity "$WORK_DMG_PATH")" || {
        /usr/bin/printf 'ERROR: staged DMG is no longer a regular file.\n' >&2; return 1;
    }
    current_metadata_identity="$(regular_file_identity "$WORK_METADATA_PATH")" || {
        /usr/bin/printf 'ERROR: staged metadata is no longer a regular file.\n' >&2; return 1;
    }
    [[ "$current_dmg_identity" == "$staged_dmg_identity" \
        && "$current_metadata_identity" == "$staged_metadata_identity" ]] || {
        /usr/bin/printf 'ERROR: staged artifact inode, size, or device changed.\n' >&2; return 1;
    }
    current_dmg_hash="$(run_clean /usr/bin/shasum -a 256 "$WORK_DMG_PATH" | /usr/bin/awk '{print $1}')" || return 1
    current_metadata_hash="$(run_clean /usr/bin/shasum -a 256 "$WORK_METADATA_PATH" | /usr/bin/awk '{print $1}')" || return 1
    [[ "$current_dmg_hash" == "$sha256" && "$current_metadata_hash" == "$metadata_sha256" ]] || {
        /usr/bin/printf 'ERROR: staged artifact SHA-256 changed.\n' >&2; return 1;
    }
    current_dmg_xattrs="$(/usr/bin/xattr "$WORK_DMG_PATH")" || return 1
    current_metadata_xattrs="$(/usr/bin/xattr "$WORK_METADATA_PATH")" || return 1
    current_dmg_mode="$(/bin/ls -lde "$WORK_DMG_PATH" | /usr/bin/awk 'NR == 1 {print $1}')"
    current_metadata_mode="$(/bin/ls -lde "$WORK_METADATA_PATH" | /usr/bin/awk 'NR == 1 {print $1}')"
    [[ "$current_dmg_mode" != *+* && "$current_metadata_mode" != *+* ]] || {
        /usr/bin/printf 'ERROR: staged artifact gained an ACL.\n' >&2; return 1;
    }
    xattr_names_are_allowed "$current_dmg_xattrs" || {
        /usr/bin/printf 'ERROR: staged DMG gained a disallowed xattr.\n' >&2; return 1;
    }
    xattr_names_are_allowed "$current_metadata_xattrs" || {
        /usr/bin/printf 'ERROR: staged metadata gained a disallowed xattr.\n' >&2; return 1;
    }
    run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" --metadata-only "$WORK_DMG_PATH" >/dev/null || {
        /usr/bin/printf 'ERROR: staged DMG metadata audit failed.\n' >&2; return 1;
    }
    run_clean /usr/bin/python3 -I -B "$AUDIT_SCRIPT" "$WORK_METADATA_PATH" || {
        /usr/bin/printf 'ERROR: staged metadata content audit failed.\n' >&2; return 1;
    }
}
verify_final_staged_artifacts() {
    verify_staged_file_bytes || return 1
    if [[ "$MODE" == "distribution" ]]; then
        run_clean /usr/bin/codesign --verify --strict --verbose=2 "$WORK_DMG_PATH" || return 1
        verify_developer_signature_identity "$WORK_DMG_PATH" || return 1
        [[ "$last_codesign_artifact_kind" == "regular" \
            && "$last_codesign_snapshot_sha256" == "$sha256" ]] || return 1
        verify_staged_file_bytes || return 1
    fi
}

if ! verify_final_staged_artifacts; then
    preserve_artifact_workspace=true
    /usr/bin/printf 'ERROR: staged DMG or metadata changed after final audit.\n' >&2
    exit 5
fi
# Recheck the exact source and trusted signer after notarization, mounted-tree
# audit, metadata construction, and the final Developer ID inspection. Follow
# that potentially slow signature inspection with one last inode/hash check.
if [[ "$MODE" == "distribution" ]] && ! reverify_distribution_source; then
    /usr/bin/printf 'ERROR: source checkout changed before final artifact publication.\n' >&2
    exit 2
fi
if ! verify_staged_file_bytes; then
    preserve_artifact_workspace=true
    /usr/bin/printf 'ERROR: staged artifacts changed during final source verification.\n' >&2
    exit 5
fi

# Publish the sidecar first and the DMG last as the completion marker. Hard
# links provide a same-filesystem O_EXCL boundary and cannot replace a file or
# symlink. On a later failure, atomically move each canonical name into the
# private workspace before comparing its inode. Recovery entries are retained
# rather than unlinked, so a later pathname substitution cannot make rollback
# delete an unrelated file.
rollback_published_file() {
    local published_path="$1"
    local expected_inode_identity="$2"
    local label="$3"
    local result state rollback_path extra
    result="$(run_clean /usr/bin/python3 -I -B - \
        "$published_path" "$artifact_workspace" "$label" \
        "$expected_inode_identity" <<'PY'
import ctypes
import errno
import os
import secrets
import stat
import sys

published_path, recovery_directory, label, expected_identity = sys.argv[1:]
if not label or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in label):
    raise SystemExit(2)
source_parent = os.path.dirname(published_path)
source_name = os.path.basename(published_path)
if not source_parent or source_name in {"", ".", ".."}:
    raise SystemExit(2)

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
source_descriptor = os.open(source_parent, directory_flags)
recovery_descriptor = os.open(recovery_directory, directory_flags)
try:
    libc = ctypes.CDLL(None, use_errno=True)
    rename_exclusive = libc.renameatx_np
    rename_exclusive.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    rename_exclusive.restype = ctypes.c_int
    for _ in range(32):
        recovery_name = f".rollback-{label}-{secrets.token_hex(12)}"
        result = rename_exclusive(
            source_descriptor,
            os.fsencode(source_name),
            recovery_descriptor,
            os.fsencode(recovery_name),
            0x00000004,  # RENAME_EXCL
        )
        if result == 0:
            break
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            print("absent\t-")
            raise SystemExit(0)
        if error == errno.EEXIST:
            continue
        raise OSError(error, os.strerror(error))
    else:
        raise RuntimeError("cannot allocate an exclusive recovery name")

    metadata = os.stat(recovery_name, dir_fd=recovery_descriptor, follow_symlinks=False)
    moved_identity = (
        f"{metadata.st_dev}:{metadata.st_ino}" if stat.S_ISREG(metadata.st_mode) else ""
    )
    state = "matched" if moved_identity == expected_identity else "unexpected"
    print(f"{state}\t{os.path.join(recovery_directory, recovery_name)}")
finally:
    os.close(recovery_descriptor)
    os.close(source_descriptor)
PY
    )" || {
        preserve_artifact_workspace=true
        /usr/bin/printf 'ERROR: cannot atomically move failed published path into private recovery: %s\n' \
            "$published_path" >&2
        return 1
    }
    IFS=$'\t' read -r state rollback_path extra <<< "$result"
    if [[ "$state" == "absent" && "$rollback_path" == "-" && -z "$extra" ]]; then
        return 0
    fi
    preserve_artifact_workspace=true
    if [[ "$state" == "matched" && "$rollback_path" == "$artifact_workspace/"* && -z "$extra" ]]; then
        /usr/bin/printf 'WARNING: failed published inode retained for review: %s\n' \
            "$rollback_path" >&2
        return 0
    fi
    /usr/bin/printf 'ERROR: unexpected published inode preserved for manual recovery: %s\n' \
        "${rollback_path:-$artifact_workspace}" >&2
    return 1
}

if ! /bin/ln "$WORK_METADATA_PATH" "$METADATA_PATH"; then
    /usr/bin/printf 'ERROR: metadata destination appeared during packaging: %s\n' "$METADATA_PATH" >&2
    exit 4
fi
if [[ "$(regular_file_identity "$METADATA_PATH" 2>/dev/null || true)" != "$staged_metadata_identity" \
    || "$(run_clean /usr/bin/shasum -a 256 "$METADATA_PATH" 2>/dev/null | /usr/bin/awk '{print $1}')" != "$metadata_sha256" ]]; then
    /usr/bin/printf 'ERROR: published metadata is not the audited inode and content.\n' >&2
    rollback_published_file "$METADATA_PATH" "$staged_metadata_inode_identity" metadata || true
    exit 5
fi
if ! /bin/ln "$WORK_DMG_PATH" "$DMG_PATH"; then
    /usr/bin/printf 'ERROR: artifact destination appeared during packaging: %s\n' "$DMG_PATH" >&2
    rollback_published_file "$METADATA_PATH" "$staged_metadata_inode_identity" metadata || true
    exit 4
fi
if [[ "$(regular_file_identity "$DMG_PATH" 2>/dev/null || true)" != "$staged_dmg_identity" \
    || "$(run_clean /usr/bin/shasum -a 256 "$DMG_PATH" 2>/dev/null | /usr/bin/awk '{print $1}')" != "$sha256" \
    || "$(regular_file_identity "$METADATA_PATH" 2>/dev/null || true)" != "$staged_metadata_identity" \
    || "$(run_clean /usr/bin/shasum -a 256 "$METADATA_PATH" 2>/dev/null | /usr/bin/awk '{print $1}')" != "$metadata_sha256" ]]; then
    /usr/bin/printf 'ERROR: published artifact pair is not the audited inode pair.\n' >&2
    rollback_published_file "$DMG_PATH" "$staged_dmg_inode_identity" dmg || true
    rollback_published_file "$METADATA_PATH" "$staged_metadata_inode_identity" metadata || true
    exit 5
fi

/usr/bin/printf 'mode\t%s\n' "$MODE"
/usr/bin/printf 'dmg\t%s\n' "$DMG_PATH"
/usr/bin/printf 'metadata\t%s\n' "$METADATA_PATH"
/usr/bin/printf 'architectures\t%s\n' "$actual_architectures"
/usr/bin/printf 'minimumSystemVersion\t%s\n' "$MINIMUM_SYSTEM_VERSION"
/usr/bin/printf 'signature\t%s\n' "$signature_kind"
/usr/bin/printf 'notarized\t%s\n' "$notarized"
/usr/bin/printf 'sha256\t%s\n' "$sha256"
