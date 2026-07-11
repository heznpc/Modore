#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PC 건강검진 - macOS 스캐너 헬퍼 (v0.3)

역할: scanner.sh가 수집한 raw 데이터를 파싱하여 raw_facts.json 생성,
      이후 rule_engine.py를 실행해 최종 scan_result.json 생성.

환경변수 (scanner.sh가 export):
  PCH_SCANNED_AT, PCH_COMPUTER_NAME, PCH_USER_NAME, PCH_OS_VERSION
  PCH_TMP_DIR, PCH_OUTPUT, PCH_CONFIG_PATH, PCH_WHITELIST_PATH
  PCH_RAW_PATH (선택), PCH_RULES_DIR (선택), PCH_NO_VT (true/false)
"""

import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional


# ------------------------------------------------------------
# 공용 헬퍼
# ------------------------------------------------------------
_MACOS_SYSTEM_PATH_PREFIXES = ("/System/", "/usr/lib", "/usr/sbin", "/usr/libexec", "/usr/bin")


def _should_skip_vt(path: str) -> bool:
    """OS 소유 경로는 VT 쿼리에서 제외 (쿼터 절약)."""
    if not path:
        return True
    return path.startswith(_MACOS_SYSTEM_PATH_PREFIXES)


def _sha256_stream(path: Path, chunk: int = 1 << 20) -> str:
    """큰 파일도 안전하게 해시. 1MB 단위 스트리밍."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def _read_plist(path: Path) -> dict:
    """PlistBuddy 3번 호출 대신 stdlib plistlib로 한 번에 파싱. XML/binary 모두 지원."""
    try:
        with open(path, "rb") as f:
            return plistlib.load(f) or {}
    except Exception as e:
        _debug_log(f"_read_plist({path})", e)
        return {}


def _read_tmp(name: str) -> str:
    """scanner.sh가 TMP_DIR에 떨어뜨린 텍스트 파일 읽기. 없으면 빈 문자열."""
    try:
        return (TMP_DIR / name).read_text(encoding="utf-8", errors="ignore")
    except FileNotFoundError:
        return ""

# rule_engine을 같은 폴더에서 import
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from _jsonutil import dump_json, load_json  # noqa: E402
from rule_engine import RuleEngine, apply_rules_to_raw  # noqa: E402


# ============================================================
# 환경변수
# ============================================================
# TODO(2nd-pass-audit-2026-05-21): PCH_* 경로 env에 sanity check 없음 — 잘못된
# 값(예: 쓰기 불가 경로, 디렉터리 vs 파일)이 와도 후속 파일 IO에서야 실패함.
# 사용자 의도와 실제 동작이 silent하게 어긋날 수 있음. 다음 sweep에서 명시적
# validate + 의미 있는 메시지로 fail-fast 추가 검토.
TMP_DIR = Path(os.environ.get("PCH_TMP_DIR", "/tmp"))
OUTPUT = Path(os.environ.get("PCH_OUTPUT", "scan_result.json"))
RAW_PATH = Path(os.environ.get("PCH_RAW_PATH", OUTPUT.parent / "raw_facts.json"))
CONFIG_PATH = Path(os.environ.get("PCH_CONFIG_PATH", "data/config.json"))
WHITELIST_PATH = Path(os.environ.get("PCH_WHITELIST_PATH", "data/whitelist.json"))
RULES_DIR = Path(os.environ.get("PCH_RULES_DIR", SCRIPT_DIR.parent / "rules"))
NO_VT = os.environ.get("PCH_NO_VT", "false").lower() == "true"
# PCH_DEBUG=1 이면 silent fallback(except Exception: pass) 지점에서 traceback을
# stderr로 흘림. 일반 사용자 출력에는 영향이 없고, 사용자 PC에서 silent fail이
# 의심될 때 디버깅 가능.
PCH_DEBUG = os.environ.get("PCH_DEBUG", "").lower() in ("1", "true", "yes")

SCANNED_AT = os.environ.get("PCH_SCANNED_AT", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
COMPUTER_NAME = os.environ.get("PCH_COMPUTER_NAME", "unknown")
USER_NAME = os.environ.get("PCH_USER_NAME", "unknown")
OS_VERSION = os.environ.get("PCH_OS_VERSION", "macOS")


def _debug_log(where: str, exc: BaseException) -> None:
    """PCH_DEBUG=1 일 때만 stderr로 traceback 1줄 로깅. 그 외 noop."""
    if PCH_DEBUG:
        import traceback
        print(f"[PCH_DEBUG] {where}: {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)


config = load_json(CONFIG_PATH, default={}) or {}


# ============================================================
# VT 모듈 - scanner_helper 내장 (경량 버전, Windows의 vt-lookup.ps1 동등)
# ============================================================
class VtLookup:
    def __init__(self, cfg, cache_dir):
        # 얕은 복사로 caller의 config dict와 분리. 이후 env 키 주입이 caller의
        # 원본 객체를 mutate하지 않도록 — 향후 누가 config를 disk로 다시 쓸 경우
        # VT_API_KEY가 평문으로 누출되는 것을 방지.
        self.cfg = dict((cfg or {}).get("virustotal") or {})
        # 환경변수 키는 config.json의 apiKey를 대체하지만 네트워크 조회 동의까지
        # 암묵적으로 만들지는 않는다. enabled=true는 로컬 config에 명시돼야 한다.
        env_key = os.environ.get("VT_API_KEY")
        if env_key:
            self.cfg["apiKey"] = env_key
        self.enabled = bool(self.cfg.get("enabled")) and bool(self.cfg.get("apiKey")) and not NO_VT
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.cache_path = self.cache_dir / "vt-cache.json"
        self.cache_hours = int(self.cfg.get("cacheHours") or 48)
        self.max_calls = int(self.cfg.get("maxCallsPerScan") or 100)
        self.rate_limit_sec = 16
        self.last_call = 0
        self.calls = 0
        self.cache = {}
        if self.cache_path.exists():
            try:
                self.cache = json.loads(self.cache_path.read_text(encoding="utf-8"))
            except Exception as e:
                _debug_log("VtLookup.cache_load", e)

    def _cached(self, key):
        entry = self.cache.get(key)
        if not entry:
            return None
        try:
            cached_at = datetime.fromisoformat(entry["cachedAt"])
        except Exception as e:
            _debug_log("VtLookup._cached.parse", e)
            return None
        age = (datetime.now() - cached_at).total_seconds() / 3600
        if age > self.cache_hours:
            del self.cache[key]
            return None
        return entry["result"]

    def _set(self, key, result):
        self.cache[key] = {"cachedAt": datetime.now().isoformat(), "result": result}

    def _request(self, url):
        if not self.enabled or self.calls >= self.max_calls:
            return None
        since = time.time() - self.last_call
        if since < self.rate_limit_sec:
            time.sleep(self.rate_limit_sec - since)
        req = urllib.request.Request(url, headers={
            "x-apikey": self.cfg["apiKey"],
            "accept": "application/json",
        })
        self.last_call = time.time()
        self.calls += 1
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return {"ok": True, "data": json.loads(resp.read())["data"]}
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return {"ok": True, "notFound": True}
            _debug_log(f"VtLookup._request.http_{e.code}", e)
            return {"error": f"http_{e.code}"}
        except Exception as e:
            _debug_log("VtLookup._request.network", e)
            return {"error": f"api: {e}"}

    def file(self, path):
        if not self.enabled or not Path(path).exists():
            return None
        try:
            h = _sha256_stream(Path(path))
        except Exception as e:
            _debug_log(f"VtLookup.file.sha256({path})", e)
            return None
        key = f"file:{h}"
        cached = self._cached(key)
        if cached is not None:
            return cached
        r = self._request(f"https://www.virustotal.com/api/v3/files/{h}")
        if not r:
            return None
        if "error" in r:
            return {"status": r["error"], "hash": h}
        if r.get("notFound"):
            result = {"status": "unknown", "hash": h}
            self._set(key, result)
            return result
        attrs = r["data"]["attributes"]
        stats = attrs["last_analysis_stats"]
        result = {
            "status": "ok",
            "hash": h,
            "malicious": int(stats.get("malicious", 0)),
            "suspicious": int(stats.get("suspicious", 0)),
            "harmless": int(stats.get("harmless", 0)),
            "undetected": int(stats.get("undetected", 0)),
            "totalEngines": sum(int(stats.get(k, 0)) for k in ("malicious", "suspicious", "harmless", "undetected")),
        }
        self._set(key, result)
        return result

    def ip(self, ip_addr):
        if not self.enabled:
            return None
        key = f"ip:{ip_addr}"
        cached = self._cached(key)
        if cached is not None:
            return cached
        r = self._request(f"https://www.virustotal.com/api/v3/ip_addresses/{ip_addr}")
        if not r:
            return None
        if "error" in r:
            return {"status": r["error"], "ip": ip_addr}
        if r.get("notFound"):
            result = {"status": "unknown", "ip": ip_addr}
            self._set(key, result)
            return result
        attrs = r["data"]["attributes"]
        stats = attrs["last_analysis_stats"]
        result = {
            "status": "ok",
            "ip": ip_addr,
            "malicious": int(stats.get("malicious", 0)),
            "suspicious": int(stats.get("suspicious", 0)),
            "country": attrs.get("country"),
            "asnOwner": attrs.get("as_owner"),
        }
        self._set(key, result)
        return result

    def save(self):
        if self.cache:
            dump_json(self.cache_path, self.cache)


def is_local_ip(ip):
    if not ip:
        return True
    if ip.startswith(("127.", "10.", "192.168.", "::1", "fe80", "0.0.0.0")):
        return True
    if ip.startswith("172."):
        try:
            octet = int(ip.split(".")[1])
            if 16 <= octet <= 31:
                return True
        except Exception as e:
            _debug_log(f"is_local_ip.172_octet({ip})", e)
    return False


def main() -> int:
    # ============================================================
    # raw_facts 구조 (판정 없음)
    # ============================================================
    raw = OrderedDict([
        ("schemaVersion", "1.0"),
        ("scannedAt", SCANNED_AT),
        ("computerName", COMPUTER_NAME),
        ("userName", USER_NAME),
        ("osVersion", OS_VERSION),
        ("platform", "macos"),
        ("scannerVersion", "0.3"),
        ("findings", []),
        ("sections", OrderedDict()),
    ])

    vt = VtLookup(config, Path.home() / "Library" / "Caches" / "PC건강검진")
    if vt.enabled:
        print("  VirusTotal 조회 활성화")


    # ============================================================
    # 1. CPU 상위 프로세스
    # ============================================================
    def _codesign_info(path: str) -> Optional[dict]:
        """codesign -dv 결과를 dict로. 실패 시 None."""
        try:
            cs = subprocess.run(
                ["codesign", "-dv", path],
                capture_output=True, text=True, timeout=5
            )
        except Exception as e:
            _debug_log(f"_codesign_info({path})", e)
            return None
        verified = ("Signature=adhoc" not in cs.stderr) and ("not signed" not in cs.stderr) and (cs.returncode == 0)
        publisher = ""
        m = re.search(r"Authority=([^\n]+)", cs.stderr)
        if m:
            publisher = m.group(1).strip()
        return {"verified": verified, "publisher": publisher, "rawStatus": "Signed" if verified else "NotSigned"}


    # pid → full path 맵을 한 번에 구축 (N+1 제거)
    _pid_path_map: Dict[str, str] = {}
    try:
        pp = subprocess.run(["ps", "-Ao", "pid=,comm="], capture_output=True, text=True, timeout=5)
        for row in pp.stdout.splitlines():
            parts = row.strip().split(None, 1)
            if len(parts) == 2:
                _pid_path_map[parts[0]] = parts[1]
    except Exception as e:
        _debug_log("ps_pid_path_map", e)

    cpu_list = []
    for line in _read_tmp("ps.txt").strip().split("\n"):
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        pid_, user, pcpu, pmem, rss, comm = parts
        try:
            pcpu = float(pcpu)
            rss_mb = round(int(rss) / 1024, 1)
        except ValueError:
            continue
        full_path = _pid_path_map.get(pid_, comm)
        name = Path(full_path).name or comm
        exists = bool(full_path) and Path(full_path).exists()

        vt_result = None
        if vt.enabled and exists and not _should_skip_vt(full_path):
            vt_result = vt.file(full_path)

        sig = _codesign_info(full_path) if exists else None

        cpu_list.append(OrderedDict([
            ("name", name),
            ("pid_", int(pid_)),
            ("cpu", pcpu),
            ("memoryMB", rss_mb),
            ("path", full_path),
            ("sig", sig),
            ("vt", vt_result),
        ]))

    cpu_list.sort(key=lambda x: x["cpu"], reverse=True)
    raw["sections"]["cpu"] = cpu_list[:15]


    # ============================================================
    # 2. GPU (macOS 제한적)
    # ============================================================
    raw["sections"]["gpu"] = []


    # ============================================================
    # 3. 외부 네트워크 연결
    # ============================================================
    net_list = []
    net_txt = _read_tmp("net.txt")
    unique_ips = set()
    connections_raw = []
    for line in net_txt.split("\n"):
        if "->" not in line or "ESTABLISHED" not in line:
            continue
        parts = line.split()
        if len(parts) < 9:
            continue
        command = parts[0]
        pid_ = parts[1]
        m = re.search(r"->([\d.]+|\[?[0-9a-fA-F:]+\]?):(\d+)", line)
        if not m:
            continue
        remote_ip = m.group(1).strip("[]")
        remote_port = int(m.group(2))
        if is_local_ip(remote_ip):
            continue
        connections_raw.append({"command": command, "pid": pid_, "ip": remote_ip, "port": remote_port})
        unique_ips.add(remote_ip)

    ip_vt_cache = {ip: vt.ip(ip) for ip in unique_ips} if vt.enabled else {}

    seen = set()
    for c in connections_raw:
        key = (c["command"], c["ip"], c["port"])
        if key in seen:
            continue
        seen.add(key)
        net_list.append(OrderedDict([
            ("process", c["command"]),
            ("pid_", int(c["pid"])),
            ("remoteAddress", c["ip"]),
            ("remotePort", c["port"]),
            ("path", ""),
            ("vtIp", ip_vt_cache.get(c["ip"])),
        ]))
    raw["sections"]["network"] = net_list


    # ============================================================
    # 4. LISTEN 포트
    # ============================================================
    port_list = []
    listen_txt = _read_tmp("listen.txt")
    seen_ports = set()
    for line in listen_txt.split("\n"):
        if "LISTEN" not in line:
            continue
        parts = line.split()
        if len(parts) < 9:
            continue
        command = parts[0]
        pid_ = parts[1]
        m = re.search(r":(\d+)\s*\(LISTEN\)", line)
        if not m:
            continue
        port = int(m.group(1))
        if port in seen_ports:
            continue
        seen_ports.add(port)
        port_list.append(OrderedDict([
            ("port", port),
            ("name", command),
            ("process", command),
            ("pid_", int(pid_)),
            ("path", ""),
        ]))
    raw["sections"]["listeningPorts"] = sorted(port_list, key=lambda p: p["port"])


    # ============================================================
    # 5. 자동 실행 (launchd + LaunchAgents/Daemons plist)
    # ============================================================
    startup_list = []
    autoruns_list = []

    for plist_path in _read_tmp("plists.txt").strip().split("\n"):
        if not plist_path:
            continue
        p = Path(plist_path)
        if not p.exists():
            continue
        pl = _read_plist(p)
        label = str(pl.get("Label") or "").strip()
        prog = ""
        prog_args = pl.get("ProgramArguments")
        if isinstance(prog_args, list) and prog_args:
            prog = str(prog_args[0]).strip()
        if not prog:
            prog = str(pl.get("Program") or "").strip()
        if not prog:
            continue

        name = label or p.stem

        # 서명 검증 (실행파일 존재할 때만)
        prog_exists = Path(prog).exists()
        sig_info = _codesign_info(prog) if prog_exists else None
        verified = bool(sig_info and sig_info.get("verified"))
        signer = (sig_info or {}).get("publisher", "")

        # VT (서명 없을 때만, OS 소유 경로 스킵)
        vt_result = None
        if vt.enabled and prog_exists and not verified and not _should_skip_vt(prog):
            vt_result = vt.file(prog)

        # 기본 startup (레거시 섹션)
        startup_list.append(OrderedDict([
            ("location", str(p.parent)),
            ("name", name),
            ("command", prog),
            ("launchString", prog),
        ]))

        # 풍부 autorun 섹션
        category = ("User LaunchAgent" if str(p).startswith(str(Path.home()))
                    else ("System LaunchDaemon" if "Daemons" in str(p) else "LaunchAgent"))
        autoruns_list.append(OrderedDict([
            ("category", category),
            ("entry", name),
            ("image", prog),
            ("signer", signer),
            ("verified", verified),
            ("launchString", prog),
            ("sha256", (vt_result or {}).get("hash", "")),
            ("vt", vt_result),
        ]))

    # 로그인 항목
    loginitems_txt = _read_tmp("loginitems.txt").strip()
    if loginitems_txt:
        for item in loginitems_txt.split(", "):
            if not item.strip():
                continue
            autoruns_list.append(OrderedDict([
                ("category", "Login Item"),
                ("entry", item.strip()),
                ("image", ""),
                ("signer", ""),
                ("verified", False),
                ("launchString", ""),
                ("sha256", ""),
                ("vt", None),
            ]))

    raw["sections"]["startup"] = startup_list
    raw["sections"]["autoruns"] = autoruns_list


    # ============================================================
    # 6. 예약 작업 (macOS는 launchd 통합)
    # ============================================================
    raw["sections"]["scheduledTasks"] = []


    # ============================================================
    # 7. 보안 상태 (Gatekeeper, SIP, XProtect)
    # ============================================================
    security_txt = _read_tmp("security.txt")
    security = {}
    for line in security_txt.split("\n"):
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        security[k.strip()] = v.strip()

    raw["sections"]["macosSecurity"] = OrderedDict([
        ("gatekeeper", security.get("GATEKEEPER", "").lower()),
        ("sip", security.get("SIP", "").lower()),
        ("xprotectVersion", security.get("XPROTECT_VERSION", "")),
    ])
    # defender 섹션도 통일성 위해 (Windows와 같은 키 이름)
    raw["sections"]["defender"] = {}


    # ============================================================
    # 8. 최근 설치 앱 - /Applications 기반
    # ============================================================
    recent = []
    thirty_days_ago = time.time() - 30 * 86400
    apps_dir = Path("/Applications")
    if apps_dir.exists():
        for app in apps_dir.iterdir():
            if app.suffix != ".app":
                continue
            try:
                ctime = app.stat().st_ctime
                if ctime < thirty_days_ago:
                    continue
                install_date = datetime.fromtimestamp(ctime).strftime("%Y-%m-%d")
                info_plist = app / "Contents" / "Info.plist"
                publisher = ""
                if info_plist.exists():
                    publisher = str(_read_plist(info_plist).get("CFBundleIdentifier") or "")
                recent.append(OrderedDict([
                    ("installDate", install_date),
                    ("name", app.stem),
                    ("publisher", publisher),
                ]))
            except Exception as e:
                _debug_log(f"recentInstalls({app})", e)
                continue
    recent.sort(key=lambda x: x["installDate"], reverse=True)
    raw["sections"]["recentInstalls"] = recent


    # ============================================================
    # 시스템 부하
    # ============================================================
    load_txt = _read_tmp("load.txt")
    load = {}
    for line in load_txt.split("\n"):
        if "=" in line:
            k, v = line.split("=", 1)
            load[k.strip()] = v.strip()

    raw["sections"]["systemLoad"] = OrderedDict([
        ("cpuPercent", float(load.get("CPU_PCT") or 0)),
        ("memoryPercent", float(load.get("MEM_PCT") or 0)),
        ("totalMemoryGB", float(load.get("MEM_TOTAL_GB") or 0)),
    ])

    raw["sections"]["virustotal"] = OrderedDict([
        ("enabled", vt.enabled),
        ("callsThisScan", vt.calls),
        ("cacheHours", vt.cache_hours if vt.enabled else 0),
    ])
    raw["sections"]["sysinternals"] = OrderedDict([
        ("sigcheckEnabled", False),
        ("autorunscEnabled", False),
        ("note", "macOS는 codesign + launchctl 사용"),
    ])


    # ============================================================
    # raw_facts 저장 + 규칙 엔진 적용
    # ============================================================
    vt.save()

    dump_json(RAW_PATH, raw)

    # 규칙 엔진 실행
    engine = RuleEngine.from_dir(RULES_DIR, WHITELIST_PATH if WHITELIST_PATH.exists() else None)
    result = apply_rules_to_raw(engine, raw)

    dump_json(OUTPUT, result)

    print(f"  - 위험: {result['summary']['dangerCount']} 건")
    print(f"  - 확인: {result['summary']['warningCount']} 건")
    if vt.enabled:
        print(f"  - VT 조회: {vt.calls} 건")

    return 0


if __name__ == "__main__":
    sys.exit(main())
