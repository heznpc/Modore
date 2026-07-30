#!/bin/bash -p
# 로컬 상태 디렉터리 이름과 이전 이름에서의 일회성 이동.
#
# 제품명이 Modore로 바뀌기 전에 만들어진 영수증, 승인 기록, 저장공간 이력,
# 사용자 설정은 옛 이름의 디렉터리에 남아 있다. 새 이름으로 그냥 바꾸면 그
# 기록이 고아가 되므로, 진입점들이 상태 경로를 정하기 전에 한 번 이동한다.
#
# 이동은 같은 볼륨 안에서의 rename이고 삭제는 하지 않는다. 목적지가 이미
# 있으면 아무것도 건드리지 않아, 두 디렉터리를 병합하려 시도하지 않는다.

SUPPORT_DIR_NAME="Modore"
LEGACY_SUPPORT_DIR_NAME="PC Health Check"

migrate_support_directory_if_needed() {
    local support_root="$1"
    local legacy="$support_root/$LEGACY_SUPPORT_DIR_NAME"
    local current="$support_root/$SUPPORT_DIR_NAME"
    local owner

    [[ -n "$support_root" && "$support_root" == /* ]] || return 0
    [[ -d "$support_root" && ! -L "$support_root" ]] || return 0
    # 심볼릭 링크는 지원 디렉터리 밖으로 이동을 유도할 수 있으므로 거부한다.
    [[ -d "$legacy" && ! -L "$legacy" ]] || return 0
    # 새 이름이 이미 있으면 그쪽이 정답이다. 병합은 판단이 필요한 일이라 하지 않는다.
    [[ ! -e "$current" && ! -L "$current" ]] || return 0

    owner="$(/usr/bin/stat -f '%u' "$legacy" 2>/dev/null)" || return 0
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 0

    # 실패해도 호출자를 막지 않는다. 검사나 정리가 이름 이동 때문에 중단되는 것이
    # 더 나쁘다. 실패 시 옛 디렉터리는 그대로 남는다.
    /bin/mv "$legacy" "$current" 2>/dev/null || return 1
    return 0
}
