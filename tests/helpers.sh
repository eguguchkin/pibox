# shellcheck shell=bash
# ============================================================================
# PIBOX — хелперы smoke-тестов. Подгружается из smoke.sh, не запускать напрямую.
# Счётчики/вывод, expect_*-проверки, docker_pibox, isolation_check, очистка.
# ============================================================================
# --- Счётчики и вывод --------------------------------------------------------

PASS=0
FAIL=0
SKIP=0
KNOWN=0

ok() {
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$*"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$*" >&2
}
skip() {
    SKIP=$((SKIP + 1))
    printf '  SKIP  %s\n' "$*"
}
known() {
    KNOWN=$((KNOWN + 1))
    printf '  KNOWN %s\n' "$*"
}

group() { printf '\n==> %s\n' "$*"; }
log() { printf '       %s\n' "$*" >&2; }
die() {
    printf 'smoke: error: %s\n' "$*" >&2
    exit 1
}

# --- Пути ---------------------------------------------------------------------

# SRC_DIR и TEST_WS используются в smoke.sh (общее пространство имён после source)
# shellcheck disable=SC2034
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pibox-smoke-XXXXXX")" && pwd)"
TEST_PIBOX="$TEST_ROOT/pibox"
# shellcheck disable=SC2034
TEST_WS="$TEST_ROOT/workspace"
BIN="$TEST_PIBOX/bin/pibox"
IMAGE="${PIBOX_IMAGE:-pibox:latest}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# --- Очистка ------------------------------------------------------------------

CLEANUP_CONTAINERS=()

cleanup() {
    # [bash3.2] Явная проверка длины вместо "${arr[@]+"${arr[@]}"}" с внешними
    # кавычками: на bash 3.2 внешние кавычки могут схлопнуть массив в один
    # «склеенный» элемент, и docker rm -f получит мусорное имя.
    if [ ${#CLEANUP_CONTAINERS[@]} -gt 0 ]; then
        local c
        for c in "${CLEANUP_CONTAINERS[@]}"; do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    if [ "$KEEP" = "1" ]; then
        printf '\nsmoke: временный каталог сохранён: %s\n' "$TEST_ROOT" >&2
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

# --- Портативные хелперы (GNU stat / BSD stat) ---------------------------------

file_mtime() { # file_mtime PATH -> epoch
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

file_owner() { # file_owner PATH -> uid
    stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || echo -1
}

has_bit() { # has_bit HEXVALUE BITNUM
    [ -n "$1" ] || return 1
    [ $((0x$1 & (2 ** $2))) -ne 0 ]
}

# --- Хелперы проверок ----------------------------------------------------------

expect_eq() { # NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        fail "$1 — ожидалось «$2», получено «$3»"
    fi
}

expect_contains() { # NAME HAYSTACK NEEDLE (поиск подстроки, grep -F)
    if printf '%s' "$2" | grep -qF -- "$3"; then
        ok "$1"
    else
        fail "$1 — «$3» не найдено в «$2»"
    fi
}

expect_ok() { # NAME CMD...
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi
}

expect_fail() { # NAME CMD... (ожидается ненулевой exit)
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$name — ожидался ненулевой код выхода"
    else
        ok "$name"
    fi
}

capture_eq() { # NAME EXPECTED CMD... — вывод команды должен совпасть
    local name="$1" expected="$2" actual=""
    shift 2
    if ! actual="$("$@" 2>/dev/null)"; then
        fail "$name — команда завершилась с ошибкой"
        return 1
    fi
    expect_eq "$name" "$expected" "$actual"
}

# --- Docker-хелпер: реплика docker run, который собирает CLI --------------------
# docker_pibox ENV_DIR WS_DIR [DOCKER_OPTS...] -- CMD [ARGS...]

docker_pibox() {
    local env_dir="$1" ws_dir="$2"
    shift 2
    local -a extra=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        extra+=("$1")
        shift
    done
    [ "${1:-}" = "--" ] || die "docker_pibox: ожидается разделитель --"
    shift

    docker run --rm \
        --add-host host.docker.internal:host-gateway \
        --cap-add SYS_PTRACE \
        --cap-add NET_RAW \
        -e "HOST_UID=$HOST_UID" \
        -e "HOST_GID=$HOST_GID" \
        -v "$env_dir:/home/pi" \
        -v "$ws_dir:/home/pi/workspace" \
        ${extra[@]+"${extra[@]}"} \
        "$IMAGE" "$@"
}

# CLI-хелпер: запуск pibox в указанном каталоге, ожидается ошибка
cli_fails_in() { # NAME DIR ARGS...
    local name="$1" dir="$2"
    shift 2
    if (cd "$dir" && "$BIN" "$@" >/dev/null 2>&1); then
        fail "$name — ожидалась ошибка"
    else
        ok "$name"
    fi
}
