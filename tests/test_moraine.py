#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""moraine 계약 테스트: 영수증·트러스트 스토어 판독, 상관 판정, 읽기 전용 경계.

명령 실행기를 주입해 실제 시스템 상태에 의존하지 않는다. 픽스처는 이 맥에서
실측한 INNORIX 사례(2026-08-19)의 형태를 그대로 옮긴 것이다.
"""
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

import pytest

import moraine


# ---------------------------------------------------------------------------
# 픽스처: 실측 출력 형태를 재현하는 가짜 실행기
# ---------------------------------------------------------------------------

INNORIX_PKGS = ["com.innorix.innorixexagent.ca.pkg",
                "com.innorix.innorixexagent.innorixes.pkg"]
APPLE_PKG = "com.apple.pkg.CLTools_Executables"
LIVE_PKG = "com.example.stillhere.pkg"

ADMIN_DUMP = """Number of trusted certs = 1
Cert 0: INNORIX.CA
   Number of trust settings : 0
"""

USER_DUMP = """Number of trusted certs = 1
Cert 0: AirFRONT
   Number of trust settings : 2
   Trust Setting 0:
      Policy OID            : EAP
      Allowed Error         : CSSMERR_TP_CERT_EXPIRED
      Result Type           : kSecTrustSettingsResultTrustAsRoot
   Trust Setting 1:
      Policy OID            : Apple X509 Basic
      Allowed Error         : CSSMERR_TP_CERT_EXPIRED
      Result Type           : kSecTrustSettingsResultTrustAsRoot
"""

PEM = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"

# LibreSSL(시스템 openssl)의 슬래시 구분 DN 형식.
INNORIX_FIELDS = ("subject= /C=KR/O=INNORIX/CN=INNORIX.CA\n"
                  "issuer= /C=KR/O=INNORIX/CN=INNORIX.CA\n"
                  "notBefore=Jul 10 09:06:37 2018 GMT\n"
                  "notAfter=Jul  7 09:06:37 2028 GMT\n"
                  "serial=01\n")
AIRFRONT_FIELDS = ("subject= /C=KR/O=AirFRONT/CN=AirFRONT\n"
                   "issuer= /C=KR/O=AirFRONT/CN=AirFRONT\n"
                   "notBefore=Jun  3 00:00:00 2020 GMT\n"
                   "notAfter=May 10 00:00:00 2120 GMT\n"
                   "serial=02\n")
CERT_TEXT = "        Public-Key: (2048 bit)\n            CA:TRUE, pathlen:0\n"

# 2026-08-19 기준 고정 시각. 만료 판정이 실행 날짜에 흔들리지 않게 한다.
NOW = 1786000000.0


def _plist(pkgid, location, install_time):
    return plistlib.dumps({
        "pkgid": pkgid, "pkg-version": "1.0", "volume": "/",
        "install-location": location, "install-time": install_time,
    }).decode("utf-8")


class FakeSystem:
    """주입되는 명령 실행기. 호출 이력을 남겨 읽기 전용 경계를 검증한다."""

    def __init__(self, *, files_on_disk=(), pkgs=None, admin=ADMIN_DUMP, user=USER_DUMP):
        self.files_on_disk = set(files_on_disk)
        self.pkgs = INNORIX_PKGS + [APPLE_PKG] if pkgs is None else pkgs
        self.admin = admin
        self.user = user
        self.calls = []

    def __call__(self, args, stdin_text=None):
        self.calls.append(list(args))
        if args[:2] == [moraine.PKGUTIL, "--pkgs"]:
            return 0, "\n".join(self.pkgs) + "\n"
        if args[1:2] == ["--pkg-info-plist"]:
            pkgid = args[2]
            location = "tmp/INNORIX-EX/register" if "innorix" in pkgid else "usr"
            return 0, _plist(pkgid, location, 1777610110)
        if args[1:2] == ["--files"]:
            pkgid = args[2]
            return 0, "payload-a\npayload-b\n" if pkgid != LIVE_PKG else "live-a\n"
        if args[1:2] == ["dump-trust-settings"]:
            return (0, self.admin) if "-d" in args else (0, self.user)
        if args[1:2] == ["find-certificate"]:
            return 0, PEM
        if args[1:2] == ["x509"]:
            if "-text" in args:
                return 0, CERT_TEXT
            return 0, AIRFRONT_FIELDS if self._airfront_turn() else INNORIX_FIELDS
        return 127, ""

    def _airfront_turn(self):
        # find-certificate 는 이름으로 조회되므로 직전 호출의 이름으로 구분한다.
        for call in reversed(self.calls):
            if call[1:2] == ["find-certificate"]:
                return "AirFRONT" in call
        return False


@pytest.fixture
def system(monkeypatch, tmp_path):
    fake = FakeSystem()
    # 파일 존재 판정만 실제 파일시스템을 쓴다. 아무것도 만들지 않으면 payload가
    # 전부 사라진 상태 = INNORIX 사례가 재현된다.
    monkeypatch.setattr(moraine.Path, "exists", lambda self: str(self) in fake.files_on_disk)
    return fake


# ---------------------------------------------------------------------------
# 트러스트 설정 판독 — 0개 설정이 "무제한 신뢰"라는 점
# ---------------------------------------------------------------------------

def test_zero_trust_settings_is_unconditional_not_unconfigured():
    """macOS 규약상 사용 제약이 빈 배열이면 '모든 정책에 대해 루트로 신뢰'다.
    '설정 안 됨'으로 읽으면 정확히 반대 결론이 나오므로 명시적으로 고정한다."""
    roots = moraine.parse_trust_settings(ADMIN_DUMP, "admin")
    assert len(roots) == 1
    assert roots[0]["name"] == "INNORIX.CA"
    assert roots[0]["settings_count"] == 0
    assert roots[0]["unconditional"] is True
    assert roots[0]["trusted_as_root"] is True


def test_explicit_policy_settings_are_not_unconditional():
    roots = moraine.parse_trust_settings(USER_DUMP, "user")
    assert roots[0]["unconditional"] is False
    assert roots[0]["trusted_as_root"] is True
    assert roots[0]["policies"] == ["EAP", "Apple X509 Basic"]


def test_empty_dump_yields_no_roots():
    assert moraine.parse_trust_settings("Number of trusted certs = 0\n", "admin") == []


# ---------------------------------------------------------------------------
# 인증서 판독 — 두 openssl 출력 형식 모두
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("dn", [
    "subject= /C=KR/O=INNORIX/CN=INNORIX.CA",       # LibreSSL (시스템 openssl)
    "subject=C=KR, O=INNORIX, CN=INNORIX.CA",       # OpenSSL 3
])
def test_dn_parsing_tolerates_both_openssl_formats(dn):
    parsed = moraine.parse_dn(dn)
    assert parsed["O"] == "INNORIX"
    assert parsed["CN"] == "INNORIX.CA"
    assert parsed["C"] == "KR"


def test_certificate_shape_is_read_from_openssl(system):
    described = moraine.describe_certificate(PEM, system, NOW)
    assert described["organization"] == "INNORIX"
    assert described["self_signed"] is True
    assert described["is_ca"] is True
    assert described["key_bits"] == 2048
    assert described["not_before"] == "2018-07-10"
    assert described["not_after"] == "2028-07-07"
    assert described["expired"] is False
    assert described["days_left"] > 0


def test_expired_certificate_is_flagged(system):
    far_future = NOW + 86400 * 365 * 20
    assert moraine.describe_certificate(PEM, system, far_future)["expired"] is True


# ---------------------------------------------------------------------------
# 영수증 판독
# ---------------------------------------------------------------------------

def test_receipt_with_no_surviving_payload_is_vanished(system):
    receipts, status = moraine.collect_receipts(system)
    assert status["status"] == "ok"
    innorix = [r for r in receipts if r["vendor"] == "com.innorix"]
    assert len(innorix) == 2
    assert all(r["state"] == "vanished" for r in innorix)
    # Computed, not literal: `installed_on` renders through `localtime` on
    # purpose (a receipt is a fact about this machine, so the operator's
    # wall clock is the honest display -- certificates, which are UTC
    # facts, go through `gmtime` in the same module). A literal here is a
    # fact about the timezone of whoever wrote the test: "13:35" was true
    # on a KST machine and false on the UTC CI runner.
    expected = time.strftime("%Y-%m-%d %H:%M", time.localtime(1777610110))
    assert all(r["installed_on"] == expected for r in innorix)


def test_receipt_with_surviving_payload_is_present(system):
    system.files_on_disk = {"/tmp/INNORIX-EX/register/payload-a",
                            "/tmp/INNORIX-EX/register/payload-b"}
    receipts, _ = moraine.collect_receipts(system)
    innorix = [r for r in receipts if r["vendor"] == "com.innorix"]
    assert all(r["state"] == "present" for r in innorix)


def test_partial_payload_is_its_own_state(system):
    system.files_on_disk = {"/tmp/INNORIX-EX/register/payload-a"}
    receipts, _ = moraine.collect_receipts(system)
    assert {r["state"] for r in receipts if r["vendor"] == "com.innorix"} == {"partial"}


def test_apple_packages_are_marked_and_sorted_last(system):
    receipts, _ = moraine.collect_receipts(system)
    apple = [r for r in receipts if r["pkgid"] == APPLE_PKG]
    assert apple and apple[0]["apple"] is True
    vendors = moraine.summarize_vendors(receipts)
    assert vendors[-1]["vendor"] == "com.apple"


def test_vendor_namespace_comes_from_the_reverse_dns_id():
    assert moraine._vendor_of_pkgid("com.innorix.innorixexagent.ca.pkg") == "com.innorix"
    assert moraine._vendor_of_pkgid("standalone") == "standalone"


def test_file_sampling_is_reported_never_silent(system):
    receipts, _ = moraine.collect_receipts(system, sample_cap=1)
    sampled = [r for r in receipts if r["sampled"]]
    assert sampled, "2-file packages must be marked sampled at cap 1"
    assert all(r["files_checked"] == 1 and r["files_total"] == 2 for r in sampled)


def test_unavailable_pkgutil_degrades_instead_of_raising():
    receipts, status = moraine.collect_receipts(lambda args, stdin=None: (127, ""))
    assert receipts == []
    assert status["status"] == "unavailable"


# ---------------------------------------------------------------------------
# 상관 판정 — 어느 한쪽만으로는 못 내는 결론
# ---------------------------------------------------------------------------

def test_trusted_root_whose_installer_payload_is_gone_is_orphaned(system):
    report = moraine.build_moraine(system, now_ts=NOW)
    innorix = [r for r in report["trust_roots"]["items"] if r["name"] == "INNORIX.CA"][0]
    assert innorix["verdict"] == "orphaned"
    assert innorix["attribution"] == "attributed"
    assert sorted(innorix["owner_packages"]) == sorted(INNORIX_PKGS)
    assert innorix["unconditional"] is True
    assert innorix["evidence"] == "preview"


def test_the_same_root_is_only_attributed_while_its_owner_survives(system):
    system.files_on_disk = {"/tmp/INNORIX-EX/register/payload-a",
                            "/tmp/INNORIX-EX/register/payload-b"}
    report = moraine.build_moraine(system, now_ts=NOW)
    innorix = [r for r in report["trust_roots"]["items"] if r["name"] == "INNORIX.CA"][0]
    assert innorix["verdict"] == "attributed"
    assert report["trust_roots"]["orphaned"] == 0


def test_a_root_with_no_receipt_is_unattributed_not_accused(system):
    report = moraine.build_moraine(system, now_ts=NOW)
    airfront = [r for r in report["trust_roots"]["items"] if r["name"] == "AirFRONT"][0]
    assert airfront["verdict"] == "unattributed"
    assert airfront["owner_packages"] == []
    # MDM 프로파일·기업 와이파이·수동 임포트는 영수증이 없는 게 정상이다.
    assert "unattributed" in moraine._VERDICT_LABEL[airfront["verdict"]]


def test_worst_first_ordering_puts_orphaned_unconditional_roots_on_top(system):
    report = moraine.build_moraine(system, now_ts=NOW)
    assert [r["name"] for r in report["trust_roots"]["items"]] == ["INNORIX.CA", "AirFRONT"]


def test_fully_removed_vendors_are_named(system):
    report = moraine.build_moraine(system, now_ts=NOW)
    assert report["removed_vendors"] == ["com.innorix"]


def test_counts_agree_with_the_item_lists(system):
    report = moraine.build_moraine(system, now_ts=NOW)
    roots = report["trust_roots"]
    assert roots["total"] == len(roots["items"])
    assert roots["orphaned"] == sum(1 for r in roots["items"] if r["verdict"] == "orphaned")
    assert roots["unconditional"] == sum(1 for r in roots["items"] if r["unconditional"])


# ---------------------------------------------------------------------------
# 읽기 전용 경계
# ---------------------------------------------------------------------------

def test_only_read_only_commands_are_ever_run(system):
    moraine.build_moraine(system, now_ts=NOW)
    allowed_first = {moraine.PKGUTIL, moraine.SECURITY, moraine.OPENSSL}
    for call in system.calls:
        assert call[0] in allowed_first, call
        joined = " ".join(call)
        for forbidden in ("delete", "remove", "forget", "add-trusted-cert",
                          "import", "unload", "rm ", "--forget"):
            assert forbidden not in joined, call


def test_the_module_never_writes_or_deletes():
    source = Path(moraine.__file__).read_text(encoding="utf-8")
    for forbidden in ("write_text", "open(", "unlink", "rmtree", "shutil",
                      "mkdir", "os.remove", "NamedTemporary"):
        assert forbidden not in source, f"moraine must not use {forbidden}"


def test_report_says_plainly_that_nothing_was_deleted(system):
    text = moraine.render_report(moraine.build_moraine(system, now_ts=NOW), 10)
    assert "Nothing here is deleted" in text
    assert "human decision" in text


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def test_cli_rejects_nonpositive_limits():
    assert moraine.main(["--limit", "0"]) == 2


@pytest.mark.skipif(sys.platform != "darwin", reason="moraine reads macOS-only sources")
def test_cli_json_runs_against_the_real_machine():
    proc = subprocess.run([sys.executable, "-I", "-B", str(Path(moraine.__file__)), "--json"],
                          capture_output=True, text=True, timeout=300)
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["evidence"] == "preview"
    assert payload["receipts"]["total"] >= 0
    assert set(payload["trust_roots"]) >= {"total", "orphaned", "unattributed", "items"}
