#!/bin/bash -p
# Modore - 승인 토큰 발급/소비 (cleanup.sh, login_items.sh 공용).
#
# 두 스크립트 모두 같은 모양의 위험한 조치를 한다: 미리보기가 무작위 토큰을
# 발급하고, 실행이 그 토큰을 소유자 승인과 함께 요구한다. 무엇을 승인했는지
# (파일 경로 vs 로그인 항목 이름)는 스크립트마다 다르므로 매니페스트 내용은
# 각자 만들지만, 토큰 자체의 발급·전달·1회성 소비·크기 검증은 완전히
# 동일했다 -- login_items.sh가 이 파일이 존재하기 전 자기만의 복사본을 만든
# 뒤, 정확히 이 계층에서 실제 버그 두 개(BSD 전용 stat 호출, 봉인 실행 시
# 소스 실패)를 독립적으로 만들었다. 그 중복이 낸 진짜 비용이 이 파일이
# 존재하는 이유다.

new_approval_token() {
    /usr/bin/openssl rand -hex 32 2>/dev/null
}

prepare_private_directory() {
    local directory="$1"
    local canonical
    /bin/mkdir -p "$directory" || return 1
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    canonical="$(cd -P "$directory" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$canonical" == "$directory" ]] || return 1
    /bin/chmod 700 "$directory" 2>/dev/null || return 1
}

approval_token_file_size() {
    local source="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%z' "$source" 2>/dev/null
    else
        /usr/bin/stat -L -c '%s' "$source" 2>/dev/null
    fi
}

# $source must be a /dev/fd/N path -- both callers only ever hand this a
# pinned file descriptor (@pch-pinned:approval_token from the app, or a real
# fd in tests), never a plain filesystem path, so the raw token never has to
# touch argv or disk under its own name.
read_approval_token_file() {
    local source="$1"
    local size token
    [[ "$source" =~ ^/dev/fd/[0-9]+$ && -f "$source" ]] || return 1
    size="$(approval_token_file_size "$source")" || return 1
    [[ "$size" == "64" ]] || return 1
    token="$(/bin/dd if="$source" bs=64 count=1 2>/dev/null)" || return 1
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    APPROVAL_TOKEN="$token"
    return 0
}
