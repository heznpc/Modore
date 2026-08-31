#!/usr/bin/python3
"""Run one local command with a hard wall-clock deadline.

The child inherits stdio so sensitive search input is never copied into argv,
temporary files, or an in-memory output buffer.  A new process group lets the
deadline stop helpers spawned by the command as well as the direct child.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


class _ForwardedSignal(Exception):
    def __init__(self, signum: int) -> None:
        self.signum = signum


def _usage() -> int:
    print("Usage: bounded_exec.py TIMEOUT_SECONDS -- /absolute/command [args ...]", file=sys.stderr)
    return 64


def _stop_process_group(process: subprocess.Popen[bytes], first_signal: int) -> None:
    def group_exists() -> bool:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    if not group_exists():
        process.poll()
        return
    try:
        os.killpg(process.pid, first_signal)
    except ProcessLookupError:
        process.poll()
        return

    deadline = time.monotonic() + 0.5
    while group_exists() and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.05)
    if group_exists():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        return _usage()
    try:
        timeout_seconds = int(argv[1], 10)
    except ValueError:
        return _usage()
    command = argv[3:]
    if not 1 <= timeout_seconds <= 300 or not os.path.isabs(command[0]):
        return _usage()

    process: subprocess.Popen[bytes] | None = None
    pending_signal = 0
    terminating = False
    handled_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    prior_handlers = {signum: signal.getsignal(signum) for signum in handled_signals}

    def forward_signal(signum: int, _frame: object) -> None:
        nonlocal pending_signal
        if terminating:
            return
        pending_signal = signum
        if process is not None:
            raise _ForwardedSignal(signum)

    for signum in handled_signals:
        signal.signal(signum, forward_signal)

    try:
        try:
            try:
                process = subprocess.Popen(command, start_new_session=True)
            except FileNotFoundError:
                print("ERROR: bounded command was not found.", file=sys.stderr)
                return 127
            except OSError as error:
                print(
                    "ERROR: bounded command could not start: "
                    f"{error.strerror or 'unknown error'}.",
                    file=sys.stderr,
                )
                return 126

            if pending_signal:
                raise _ForwardedSignal(pending_signal)
            try:
                return_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                terminating = True
                _stop_process_group(process, signal.SIGTERM)
                print(
                    f"ERROR: Modore command timed out after {timeout_seconds} seconds.",
                    file=sys.stderr,
                )
                return 124
        except _ForwardedSignal as forwarded:
            terminating = True
            if process is not None:
                _stop_process_group(process, forwarded.signum)
            return 128 + forwarded.signum

        if return_code < 0:
            return 128 + (-return_code)
        return return_code
    finally:
        for signum, prior_handler in prior_handlers.items():
            signal.signal(signum, prior_handler)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
