#!/bin/bash -p
# Modore - Login Item 승인형 조치 (macOS).
#
# cleanup.sh는 파일/디렉터리 경로를 대상으로 스테이징-휴지통-매니페스트
# 정합성 검사를 하도록 설계되어 있다. 로그인 항목은 경로가 아니라 System
# Events가 관리하는 이름 하나뿐이라 그 기계장치가 통째로 맞지 않는다. 그래서
# 토큰 발급·전달·1회성 소비(무엇을 승인했는지와 무관한 부분)는
# modules/approval_token.sh를 cleanup.sh와 함께 쓰고, 파일 대상 전용 로직
# (매니페스트 크기·inode 비교, 휴지통 이동, 스테이징)은 옮기지 않았다.
#
# Preview는 읽기 전용: 이름이 현재 로그인 항목 목록에 실제로 있는지 확인한
# 뒤에만 토큰을 발급한다. Execute는 --owner-approved와 유효한 승인 토큰을
# 요구하고, 삭제 직전 대상이 여전히 목록에 있는지 다시 확인하며, 삭제 후
# 실제로 사라졌는지 사후 확인한 뒤에만 성공을 보고한다 -- osascript의 종료
# 코드 0은 "명령을 보냈다"는 뜻이지 "항목이 사라졌다"는 뜻이 아니다.
#
# 이름은 System Events 로그인 항목 목록의 유일 키가 아니다(같은 이름이
# 여럿일 수 있음). 이는 System Events 자체의 한계이며, 이 스크립트가 새로
# 만드는 모호함이 아니다 -- 기존 인벤토리(scanner_helper.jxa.js)도 이름만을
# 식별자로 다룬다.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

# Sealed app runs pin this script to /dev/fd/N, where a sibling-relative
# source resolves to the nonexistent /dev/fd/modules/... and bash CONTINUES
# past the failed source -- leaving SUPPORT_DIR_NAME unset and killing the
# script later under set -u. The app passes the module itself as a second
# pinned descriptor via this env var (scanner.sh's existing pattern); the
# dirname fallback keeps direct/dev-mode invocations working unchanged.
# shellcheck disable=SC1090  # target is env-selected; see scanner.sh
source "${PCH_PINNED_SUPPORT_DIR_MODULE:-$(/usr/bin/dirname "${BASH_SOURCE[0]}")/modules/support_dir.sh}"
# shellcheck disable=SC1090  # target is env-selected; see scanner.sh
source "${PCH_PINNED_APPROVAL_TOKEN_MODULE:-$(/usr/bin/dirname "${BASH_SOURCE[0]}")/modules/approval_token.sh}"

PROTOCOL_VERSION="1"
APPROVAL_TTL_SECONDS=900
HOME_ROOT="${HOME:-}"
OPERATION=""
NAME=""
OWNER_APPROVED="false"
APPROVAL_TOKEN=""
APPROVAL_TOKEN_FILE=""
APPROVAL_DIR=""

OSASCRIPT_BIN="/usr/bin/osascript"
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    OSASCRIPT_BIN="${PCH_TEST_OSASCRIPT_BIN:-$OSASCRIPT_BIN}"
fi

emit() {
    /usr/bin/printf '%s\t%s\n' "$1" "${2:-}"
}

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  login_items.sh --preview <name>' \
        '  login_items.sh --execute <name> --owner-approved --approval-token-file <path>'
}

fail_usage() {
    /usr/bin/printf 'ERROR: %s\n' "$1" >&2
    usage >&2
    exit 64
}

applescript_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    /usr/bin/printf '%s' "$value"
}

current_login_item_names() {
    "$OSASCRIPT_BIN" -e 'tell application "System Events" to get the name of every login item' 2>/dev/null
}

login_item_exists() {
    local target="$1" names entry
    names="$(current_login_item_names)" || return 1
    IFS=',' read -ra parts <<< "$names"
    # A Mac with zero login items yields an empty array, and macOS's bash 3.2
    # treats "${parts[@]}" on an empty array as unbound under set -u.
    [[ "${#parts[@]}" -gt 0 ]] || return 1
    for entry in "${parts[@]}"; do
        entry="$(/usr/bin/printf '%s' "$entry" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ "$entry" == "$target" ]] && return 0
    done
    return 1
}

cmd_preview() {
    local target="$1"
    if ! login_item_exists "$target"; then
        emit "status" "not_found"
        emit "name" "$target"
        return 1
    fi
    prepare_private_directory "$APPROVAL_DIR" || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    local token created_epoch temporary destination
    token="$(new_approval_token)" || { emit "status" "blocked"; emit "name" "$target"; return 1; }
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || { emit "status" "blocked"; emit "name" "$target"; return 1; }
    created_epoch="$(/bin/date '+%s')" || { emit "status" "blocked"; emit "name" "$target"; return 1; }
    temporary="$(/usr/bin/mktemp "$APPROVAL_DIR/.preview.XXXXXX")" || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    {
        /usr/bin/printf 'version\t%s\n' "$PROTOCOL_VERSION"
        /usr/bin/printf 'name\t%s\n' "$target"
        /usr/bin/printf 'createdEpoch\t%s\n' "$created_epoch"
    } > "$temporary" || {
        /bin/rm -f "$temporary"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    /bin/chmod 600 "$temporary" 2>/dev/null || true
    destination="$APPROVAL_DIR/$token.tsv"
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        /bin/rm -f "$temporary"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    /bin/mv "$temporary" "$destination" || {
        /bin/rm -f "$temporary"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    emit "status" "ready"
    emit "name" "$target"
    emit "approvalToken" "$token"
    return 0
}

cmd_execute() {
    local target="$1"
    [[ "$OWNER_APPROVED" == "true" ]] || fail_usage "실행에는 --owner-approved가 필요합니다."
    [[ -n "$APPROVAL_TOKEN_FILE" ]] || fail_usage "실행에는 미리보기에서 받은 --approval-token-file이 필요합니다."
    read_approval_token_file "$APPROVAL_TOKEN_FILE" || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }

    prepare_private_directory "$APPROVAL_DIR" || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    local source executing
    source="$APPROVAL_DIR/$APPROVAL_TOKEN.tsv"
    executing="$APPROVAL_DIR/.executing-$APPROVAL_TOKEN-$$.tsv"
    [[ -f "$source" && ! -L "$source" && ! -e "$executing" && ! -L "$executing" ]] || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    # mv makes token consumption single-use: a second execute attempt with the
    # same token finds no source file left to move.
    /bin/mv "$source" "$executing" || {
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }

    local created_epoch stored_name now age
    created_epoch="$(/usr/bin/awk -F '\t' '$1 == "createdEpoch" {print $2; count++} END {if (count != 1) exit 1}' "$executing")" || {
        /bin/rm -f "$executing"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    [[ "$created_epoch" =~ ^[0-9]+$ ]] || {
        /bin/rm -f "$executing"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    stored_name="$(/usr/bin/awk -F '\t' '$1 == "name" {print substr($0, length($1) + 2); count++} END {if (count != 1) exit 1}' "$executing")" || {
        /bin/rm -f "$executing"
        emit "status" "blocked"
        emit "name" "$target"
        return 1
    }
    /bin/rm -f "$executing"

    now="$(/bin/date '+%s')" || { emit "status" "blocked"; emit "name" "$target"; return 1; }
    age=$((now - created_epoch))
    if [[ "$age" -lt 0 || "$age" -gt "$APPROVAL_TTL_SECONDS" ]]; then
        emit "status" "expired"
        emit "name" "$target"
        return 1
    fi
    if [[ "$stored_name" != "$target" ]]; then
        emit "status" "mismatch"
        emit "name" "$target"
        return 1
    fi

    if ! login_item_exists "$target"; then
        # Removed some other way (System Settings, the app itself) between
        # preview and execute. The desired end state already holds.
        emit "status" "already_gone"
        emit "name" "$target"
        return 0
    fi

    local escaped
    escaped="$(applescript_escape "$target")"
    "$OSASCRIPT_BIN" -e "tell application \"System Events\" to delete login item \"$escaped\"" >/dev/null 2>&1

    # A clean osascript exit only means the command was accepted, not that
    # the item is actually gone. Re-read the real list before reporting ok.
    if login_item_exists "$target"; then
        emit "status" "failed"
        emit "name" "$target"
        return 1
    fi
    emit "status" "ok"
    emit "name" "$target"
    return 0
}

[[ "$#" -ge 1 ]] || fail_usage "명령이 필요합니다."
case "$1" in
    --preview)
        OPERATION="preview"
        shift
        [[ "$#" -ge 1 ]] || fail_usage "--preview에는 로그인 항목 이름이 필요합니다."
        NAME="$1"
        shift
        ;;
    --execute)
        OPERATION="execute"
        shift
        [[ "$#" -ge 1 ]] || fail_usage "--execute에는 로그인 항목 이름이 필요합니다."
        NAME="$1"
        shift
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                --owner-approved) OWNER_APPROVED="true" ;;
                --approval-token-file)
                    [[ "$#" -ge 2 ]] || fail_usage "--approval-token-file 값이 필요합니다."
                    shift
                    APPROVAL_TOKEN_FILE="$1"
                    ;;
                *) fail_usage "알 수 없는 옵션: $1" ;;
            esac
            shift
        done
        ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "알 수 없는 명령: $1" ;;
esac

case "$NAME" in
    *$'\t'*|*$'\n'*|*$'\r'*)
        fail_usage "로그인 항목 이름에 사용할 수 없는 문자가 포함되어 있습니다."
        ;;
esac
[[ -n "$NAME" ]] || fail_usage "로그인 항목 이름이 비어 있습니다."

migrate_support_directory_if_needed "$HOME_ROOT/Library/Application Support" || true
APPROVAL_DIR="$HOME_ROOT/Library/Application Support/$SUPPORT_DIR_NAME/login-item-approvals"

case "$OPERATION" in
    preview) cmd_preview "$NAME"; exit $? ;;
    execute) cmd_execute "$NAME"; exit $? ;;
esac
