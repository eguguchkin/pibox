#!/usr/bin/env bash
# ============================================================================
# PIBOX — smoke-тесты (задача 8).
#
# Проверяет инфраструктурные гарантии pibox: установку, образ, CLI,
# изоляцию каталогов, подстройку UID/GID, skel-merge, сеть, capabilities,
# лимиты ресурсов и проброс портов. Поведение самого агента (диалог
# с моделью) — вне скоупа, см. tests/ACCEPTANCE.md.
#
# Использование:
#   tests/smoke.sh [--offline] [--keep] [--rebuild] [-h]
#
# Опции:
#   --offline   пропустить проверку доступа в интернет (R14)
#   --keep      не удалять временный каталог (путь печатается в конце)
#   --rebuild   пересобрать образ, даже если он существует
#   -h, --help  эта справка
#
# Переменные окружения:
#   PIBOX_IMAGE   имя тестируемого образа (по умолчанию pibox:latest)
#   TMPDIR        каталог для временных файлов
#
# Требования: bash >= 4.4, docker >= 20.10 (запущенный демон), curl,
# realpath, grep, sed. НЕ запускать от root: entrypoint отказывается
# работать с HOST_UID=0.
#
# Выход: 0 — все проверки пройдены, 1 — есть FAIL.
# KNOWN-ISSUE не влияет на код выхода (см. docs/NOTES.md, раздел 12):
# это известные проблемы, для которых тест задаёт критерий приёмки
# будущей правки. При FAIL артефакты автоматически сохраняются.
# ============================================================================

set -euo pipefail

OFFLINE=0
KEEP=0
REBUILD=0

usage() {
    cat <<'EOF'
pibox smoke-тесты (задача 8)

Использование:
    tests/smoke.sh [--offline] [--keep] [--rebuild] [-h]

Опции:
    --offline   пропустить проверку доступа в интернет
    --keep      сохранить временный каталог (путь печатается в конце)
    --rebuild   пересобрать образ pibox, даже если он существует
    -h, --help  эта справка

Требования: bash >= 4.4, docker >= 20.10 (запущенный демон),
curl, realpath. Не запускать от root.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --offline) OFFLINE=1 ;;
        --keep)    KEEP=1 ;;
        --rebuild) REBUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'smoke: error: неизвестная опция: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# --- Счётчики и вывод --------------------------------------------------------

PASS=0; FAIL=0; SKIP=0; KNOWN=0

ok()    { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
fail()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*" >&2; }
skip()  { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$*"; }
known() { KNOWN=$((KNOWN + 1)); printf '  KNOWN %s\n' "$*"; }

group() { printf '\n==> %s\n' "$*"; }
log()   { printf '       %s\n' "$*" >&2; }
die()   { printf 'smoke: error: %s\n' "$*" >&2; exit 1; }

# --- Пути ---------------------------------------------------------------------

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pibox-smoke-XXXXXX")"
TEST_PIBOX="$TEST_ROOT/pibox"
TEST_WS="$TEST_ROOT/workspace"
BIN="$TEST_PIBOX/bin/pibox"
IMAGE="${PIBOX_IMAGE:-pibox:latest}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# --- Очистка ------------------------------------------------------------------

CLEANUP_CONTAINERS=()

cleanup() {
    local c
    for c in "${CLEANUP_CONTAINERS[@]+"${CLEANUP_CONTAINERS[@]}"}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
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
    [ $(( 16#$1 & (1 << $2) )) -ne 0 ]
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
        fail "$1 — «$3» не найдено"
    fi
}

expect_ok() { # NAME CMD...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi
}

expect_fail() { # NAME CMD... (ожидается ненулевой exit)
    local name="$1"; shift
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
    local name="$1" dir="$2"; shift 2
    if (cd "$dir" && "$BIN" "$@" >/dev/null 2>&1); then
        fail "$name — ожидалась ошибка"
    else
        ok "$name"
    fi
}

# ============================================================================
# Фаза 0: предварительные требования
# ============================================================================

group "Фаза 0: предварительные требования"

if [ "$(id -u)" -eq 0 ]; then
    die "не запускайте smoke-тесты от root: entrypoint отказывается работать с HOST_UID=0"
fi

if [ "$(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] ))" -lt 404 ]; then
    die "требуется bash >= 4.4 (найдено ${BASH_VERSION})"
fi

for tool in docker curl realpath grep sed; do
    command -v "$tool" >/dev/null 2>&1 || die "не найдена утилита: $tool"
done

if ! docker info >/dev/null 2>&1; then
    die "docker daemon не отвечает (docker info)"
fi

SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
[ -n "$SERVER_VERSION" ] || die "не удалось определить версию docker"
MAJOR="$(printf '%s' "$SERVER_VERSION" | cut -d. -f1)"
MINOR="$(printf '%s' "$SERVER_VERSION" | cut -d. -f2)"
if [ "$(( 10#${MAJOR:-0} * 100 + 10#${MINOR:-0} ))" -lt 2010 ]; then
    die "требуется docker >= 20.10 для host-gateway (найдено ${SERVER_VERSION})"
fi
ok "P0: docker ${SERVER_VERSION} (>= 20.10), bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}, uid ${HOST_UID}"

# ============================================================================
# Фаза 1: install.sh
# ============================================================================

group "Фаза 1: install.sh"

expect_ok "I1: install.sh --help" "$SRC_DIR/install.sh" --help

if "$SRC_DIR/install.sh" --dir "$TEST_PIBOX" --no-path --src "$SRC_DIR" >/dev/null 2>&1; then
    ok "I2: установка в ${TEST_PIBOX}"
else
    die "I2: install.sh завершился с ошибкой — дальнейшие тесты бессмысленны"
fi

for path in bin/pibox docker/Dockerfile docker/entrypoint.sh docker/.dockerignore \
            env-template/.pi/agent env-template/.bashrc \
            env/default/.pi/agent env/models.json .pibox_installed; do
    if [ -e "$TEST_PIBOX/$path" ]; then
        ok "I3: структура: ${path}"
    else
        fail "I3: отсутствует ${path}"
    fi
done

if [ -x "$BIN" ]; then ok "I4: bin/pibox исполняемый"; else fail "I4: bin/pibox не исполняемый"; fi

# I5: повторная установка без --force не трогает существующее
touch -t 202001010000 "$BIN"
OLD_BIN_MTIME="$(file_mtime "$BIN")"
echo "// smoke-sentinel" >> "$TEST_PIBOX/env/models.json"

if "$SRC_DIR/install.sh" --dir "$TEST_PIBOX" --no-path --src "$SRC_DIR" >/dev/null 2>&1; then
    ok "I5: повторная установка (без --force) прошла"
else
    fail "I5: повторная установка завершилась с ошибкой"
fi
expect_eq "I5: bin/pibox не перезаписан" "$OLD_BIN_MTIME" "$(file_mtime "$BIN")"
if grep -qF "smoke-sentinel" "$TEST_PIBOX/env/models.json"; then
    ok "I5: env/models.json не перезаписан"
else
    fail "I5: env/models.json перезаписан без --force"
fi

# I6: --force обновляет файлы установки, но НЕ трогает env/*
echo keepme > "$TEST_PIBOX/env/default/.smoke-sentinel"
touch -t 202001010000 "$BIN"
OLD_BIN_MTIME="$(file_mtime "$BIN")"

if "$SRC_DIR/install.sh" --dir "$TEST_PIBOX" --no-path --force --src "$SRC_DIR" >/dev/null 2>&1; then
    ok "I6: переустановка с --force прошла"
else
    fail "I6: переустановка с --force завершилась с ошибкой"
fi
if [ "$(file_mtime "$BIN")" != "$OLD_BIN_MTIME" ]; then
    ok "I6: bin/pibox обновлён (--force)"
else
    fail "I6: bin/pibox не обновлён при --force"
fi
if [ -f "$TEST_PIBOX/env/default/.smoke-sentinel" ]; then
    ok "I6: env/default не затронут --force"
else
    fail "I6: --force затронул env/default"
fi
if grep -qF "smoke-sentinel" "$TEST_PIBOX/env/models.json"; then
    fail "I6: --force не обновил env/models.json (документированное поведение — перезапись)"
else
    ok "I6: env/models.json обновлён (--force, перезапись — документирована)"
fi

# ============================================================================
# Фаза 2: Docker-образ
# ============================================================================

group "Фаза 2: Docker-образ"

NEED_BUILD=1
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [ "$REBUILD" = "1" ]; then
        log "образ ${IMAGE} существует — пересобираю (--rebuild)"
    else
        NEED_BUILD=0
        log "образ ${IMAGE} существует — сборка пропущена (--rebuild для пересборки)"
    fi
fi

if [ "$NEED_BUILD" = "1" ]; then
    log "сборка ${IMAGE} из ${TEST_PIBOX}/docker (первый раз — несколько минут)..."
    if ! docker build -t "$IMAGE" "$TEST_PIBOX/docker" >&2; then
        die "сборка образа не удалась"
    fi
fi
ok "B0: образ ${IMAGE} доступен"

expect_ok "B1: pi --version"          docker run --rm "$IMAGE" pi --version
expect_ok "B2: mise --version"        docker run --rm "$IMAGE" mise --version
expect_ok "B2: node --version"        docker run --rm "$IMAGE" node --version
expect_ok "B2: npm --version"         docker run --rm "$IMAGE" npm --version
expect_ok "B3: инструменты глобально в PATH" docker run --rm "$IMAGE" \
    bash -c 'command -v pi node npm mise gosu tini jq yq rg xxd git python3'
expect_ok "B4: тяжёлых тулчейнов в образе нет" docker run --rm "$IMAGE" \
    bash -c 'for t in gcc gdb rustc cargo cmake valgrind strace tcpdump; do command -v "$t" && exit 1; done; exit 0'
expect_ok "B5: пользователь pi (uid 1000) и /opt/skel" docker run --rm "$IMAGE" \
    bash -c '[ "$(id -u pi)" = 1000 ] && [ -f /opt/skel/.bashrc ] && [ -f /opt/skel/.profile ]'

# ============================================================================
# Фаза 3: CLI pibox (dry-run)
# ============================================================================

group "Фаза 3: CLI pibox (dry-run)"

mkdir -p "$TEST_WS"
echo "probe-content" > "$TEST_WS/probe.txt"

expect_ok "C1: pibox --help"    "$BIN" --help
capture_eq "C2: pibox --version" "pibox 0.1.0" "$BIN" --version

# C3: dry-run по умолчанию + содержимое команды
DRY=""
if DRY="$(cd "$TEST_WS" && "$BIN" --dry-run 2>/dev/null)"; then
    ok "C3: pibox --dry-run (default)"
else
    fail "C3: pibox --dry-run завершился с ошибкой"
fi
expect_contains "C4: host-gateway в команде"    "$DRY" "--add-host host.docker.internal:host-gateway"
expect_contains "C5: --cap-add SYS_PTRACE"      "$DRY" "--cap-add SYS_PTRACE"
expect_contains "C5: --cap-add NET_RAW"         "$DRY" "--cap-add NET_RAW"
expect_contains "C6: --memory (дефолт)"         "$DRY" "--memory 4g"
expect_contains "C6: --cpus (дефолт)"           "$DRY" "--cpus 2"
expect_contains "C6: --pids-limit (дефолт)"     "$DRY" "--pids-limit 512"
expect_contains "C7: mount окружения"           "$DRY" "-v $TEST_PIBOX/env/default:/home/pi"
expect_contains "C8: mount workspace"           "$DRY" "-v $TEST_WS:/home/pi/workspace"
expect_contains "C9: HOST_UID передаётся"       "$DRY" "-e HOST_UID=$HOST_UID"
expect_contains "C9: HOST_GID передаётся"       "$DRY" "-e HOST_GID=$HOST_GID"
if [ -f "$TEST_PIBOX/env/default/.pi/agent/models.json" ]; then
    ok "C3: models.json скопирован в default при первом dry-run"
else
    fail "C3: models.json не скопирован в env/default"
fi

# C10: кастомное окружение — автосоздание + models.json
DRY2=""
if DRY2="$(cd "$TEST_WS" && "$BIN" --dry-run -e smoke-env 2>/dev/null)"; then
    ok "C10: dry-run с кастомным окружением"
else
    fail "C10: dry-run -e smoke-env завершился с ошибкой"
fi
expect_contains "C10: mount кастомного env" "$DRY2" "-v $TEST_PIBOX/env/smoke-env:/home/pi"
if [ -d "$TEST_PIBOX/env/smoke-env" ]; then ok "C10: окружение создано"; else fail "C10: окружение не создано"; fi
MODELS_DST="$TEST_PIBOX/env/smoke-env/.pi/agent/models.json"
if [ -f "$MODELS_DST" ]; then
    ok "C10: models.json скопирован в окружение"
    if cmp -s "$TEST_PIBOX/env/models.json" "$MODELS_DST"; then
        ok "C10: содержимое models.json совпадает с шаблоном"
    else
        fail "C10: models.json отличается от шаблона"
    fi
else
    fail "C10: models.json отсутствует в окружении"
fi

# C11: повторный запуск не пересоздаёт окружение (mtime-тест)
touch -t 202001010000 "$MODELS_DST" 2>/dev/null || true
OLD_MODELS_MTIME="$(file_mtime "$MODELS_DST")"
if (cd "$TEST_WS" && "$BIN" --dry-run -e smoke-env >/dev/null 2>&1); then
    ok "C11: повторный dry-run прошёл"
else
    fail "C11: повторный dry-run завершился с ошибкой"
fi
expect_eq "C11: models.json не пересоздаётся" "$OLD_MODELS_MTIME" "$(file_mtime "$MODELS_DST")"

# C12: -p / -E
DRY3=""
if DRY3="$(cd "$TEST_WS" && env SMOKE_VAR=smoke-value "$BIN" --dry-run -p 28111:8080 -E SMOKE_VAR 2>/dev/null)"; then
    ok "C12: dry-run с -p и -E"
else
    fail "C12: dry-run с -p/-E завершился с ошибкой"
fi
expect_contains "C12: проброс порта в команде"  "$DRY3" "-p 28111:8080"
expect_contains "C12: проброс переменной"       "$DRY3" "-e SMOKE_VAR"

# C13: --git-safe / --resync-skel
DRY4=""
if DRY4="$(cd "$TEST_WS" && "$BIN" --dry-run --git-safe --resync-skel 2>/dev/null)"; then
    ok "C13: dry-run с --git-safe/--resync-skel"
else
    fail "C13: dry-run с флагами завершился с ошибкой"
fi
expect_contains "C13: PIBOX_GIT_SAFE=1"    "$DRY4" "PIBOX_GIT_SAFE=1"
expect_contains "C13: PIBOX_RESYNC_SKEL=1" "$DRY4" "PIBOX_RESYNC_SKEL=1"

# C14: переопределение лимитов
DRY5=""
if DRY5="$(cd "$TEST_WS" && "$BIN" --dry-run --memory 2g 2>/dev/null)"; then
    ok "C14: dry-run с кастомным --memory"
else
    fail "C14: dry-run с --memory 2g завершился с ошибкой"
fi
expect_contains "C14: лимит переопределён" "$DRY5" "--memory 2g"

# C15: env list
if capture "C15: env list" env; then :; fi
if REPLY="$("$BIN" env list 2>/dev/null)"; then
    expect_contains "C15: default в списке"   "$REPLY" "default"
    expect_contains "C15: smoke-env в списке" "$REPLY" "smoke-env"
else
    fail "C15: env list завершился с ошибкой"
fi

# C16: env create / remove / защита default
expect_ok "C16: env create" "$BIN" env create smoke-env2
if [ -d "$TEST_PIBOX/env/smoke-env2" ]; then ok "C16: каталог создан"; else fail "C16: каталог не создан"; fi
expect_ok "C16: env remove" "$BIN" env remove smoke-env2
if [ ! -d "$TEST_PIBOX/env/smoke-env2" ]; then ok "C16: каталог удалён"; else fail "C16: каталог не удалён"; fi
expect_fail "C16: env remove default запрещён" "$BIN" env remove default

# C17: изоляция workspace и PIBOX_DIR
isolation_check() { # NAME DIR NEEDLE
    local name="$1" dir="$2" needle="$3" out=""
    if out="$(cd "$dir" && "$BIN" --dry-run 2>&1 >/dev/null)"; then
        fail "$name — запуск должен быть заблокирован"
    else
        expect_contains "$name" "$out" "$needle"
    fi
}
isolation_check "C17: workspace = PIBOX_DIR"        "$TEST_PIBOX"     "PIBOX_DIR"
isolation_check "C17: workspace внутри PIBOX_DIR"   "$TEST_PIBOX/env" "PIBOX_DIR"
isolation_check "C17: PIBOX_DIR внутри workspace"   "$TEST_ROOT"      "PIBOX_DIR"

# C18: недопустимые имена окружений
cli_fails_in "C18: имя '../evil' отклоняется"  "$TEST_WS" --dry-run -e "../evil"
cli_fails_in "C18: имя с пробелом отклоняется" "$TEST_WS" --dry-run -e "bad name"

# ============================================================================
# Фаза 4: контейнер (runtime)
# ============================================================================

group "Фаза 4: контейнер (runtime)"

ENV_UID="$(mktemp -d "$TEST_ROOT/env-uid-XXXX")"
ENV_FRESH="$(mktemp -d "$TEST_ROOT/env-fresh-XXXX")"
ENV_USER="$(mktemp -d "$TEST_ROOT/env-user-XXXX")"
ENV_NOMERGE="$(mktemp -d "$TEST_ROOT/env-nomerge-XXXX")"
ENV_RESYNC="$(mktemp -d "$TEST_ROOT/env-resync-XXXX")"
ENV_CAPS="$(mktemp -d "$TEST_ROOT/env-caps-XXXX")"
ENV_E2E="$TEST_PIBOX/env/smoke-env"

# --- R1: UID/GID ---
capture_eq "R1: id -u = хостовому" "$HOST_UID" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'id -u'
capture_eq "R1: id -g = хостовому" "$HOST_GID" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'id -g'

# --- R2: владение файлами в workspace ---
expect_ok "R2: файл создаётся в workspace" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'echo from-container > /home/pi/workspace/from-container.txt'
expect_eq "R2: владелец файла = хост-пользователь (не root)" "$HOST_UID" \
    "$(file_owner "$TEST_WS/from-container.txt")"

# --- R3: HOME / USER / PATH ---
capture_eq "R3: HOME=/home/pi" "/home/pi" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'printf %s "$HOME"'
capture_eq "R3: USER=pi" "pi" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'printf %s "$USER"'
PATH_OUT="$(docker_pibox "$ENV_UID" "$TEST_WS" -- bash -c 'printf %s "$PATH"' 2>/dev/null || true)"
expect_contains "R3: PATH содержит mise-шимы" "$PATH_OUT" ".local/share/mise/shims"

# --- R4: процессная цепочка (tini = PID 1) ---
capture_eq "R4: PID 1 = tini (gosu→tini exec-цепочка)" "tini" \
    docker_pibox "$ENV_UID" "$TEST_WS" -- cat /proc/1/comm

# --- R5: skel-merge на свежем окружении ---
expect_ok "R5: первый запуск на пустом env" docker_pibox "$ENV_FRESH" "$TEST_WS" -- true
if [ -f "$ENV_FRESH/.pibox_skel_initialized" ]; then ok "R5: маркер создан"; else fail "R5: маркер не создан"; fi
if [ -f "$ENV_FRESH/.bash_logout" ]; then ok "R5: .bash_logout из skel"; else fail "R5: .bash_logout из skel отсутствует"; fi
if [ -f "$ENV_FRESH/.bashrc" ]; then ok "R5: .bashrc из skel"; else fail "R5: .bashrc из skel отсутствует"; fi
expect_eq "R5: маркер принадлежит хост-пользователю" "$HOST_UID" "$(file_owner "$ENV_FRESH/.pibox_skel_initialized")"
expect_eq "R5: .bash_logout принадлежит хост-пользователю" "$HOST_UID" "$(file_owner "$ENV_FRESH/.bash_logout")"

# --- R6: пользовательские файлы не перезаписываются (cp -n) ---
printf '%s\n' '# smoke user bashrc' > "$ENV_USER/.bashrc"
expect_ok "R6: запуск с пользовательским .bashrc" docker_pibox "$ENV_USER" "$TEST_WS" -- true
if grep -qF 'smoke user bashrc' "$ENV_USER/.bashrc"; then
    ok "R6: пользовательский .bashrc не перезаписан"
else
    fail "R6: .bashrc перезаписан skel'ом"
fi

# --- R7: повторный запуск не повторяет merge (mtime маркера) ---
expect_ok "R7: первый запуск" docker_pibox "$ENV_NOMERGE" "$TEST_WS" -- true
touch -t 202001010000 "$ENV_NOMERGE/.pibox_skel_initialized"
OLD_R7="$(file_mtime "$ENV_NOMERGE/.pibox_skel_initialized")"
expect_ok "R7: повторный запуск" docker_pibox "$ENV_NOMERGE" "$TEST_WS" -- true
expect_eq "R7: маркер не пересоздаётся (merge пропущен)" "$OLD_R7" \
    "$(file_mtime "$ENV_NOMERGE/.pibox_skel_initialized")"

# --- R8: PIBOX_RESYNC_SKEL=1 форсирует повторный merge ---
printf '%s\n' '# user bashrc' > "$ENV_RESYNC/.bashrc"
expect_ok "R8: первый запуск" docker_pibox "$ENV_RESYNC" "$TEST_WS" -- true
touch -t 202001010000 "$ENV_RESYNC/.pibox_skel_initialized"
OLD_R8="$(file_mtime "$ENV_RESYNC/.pibox_skel_initialized")"
expect_ok "R8: запуск с PIBOX_RESYNC_SKEL=1" \
    docker_pibox "$ENV_RESYNC" "$TEST_WS" -e PIBOX_RESYNC_SKEL=1 -- true
if [ "$(file_mtime "$ENV_RESYNC/.pibox_skel_initialized")" != "$OLD_R8" ]; then
    ok "R8: маркер пересоздан (resync сработал)"
else
    fail "R8: resync не сработал"
fi
if grep -qF 'user bashrc' "$ENV_RESYNC/.bashrc"; then
    ok "R8: resync не затирает пользовательские файлы (cp -n)"
else
    fail "R8: resync перезаписал пользовательский файл"
fi

# --- R9/R10: entrypoint отвергает опасные UID ---
ERR9=""
if ! ERR9="$(docker run --rm -e HOST_UID=0 -e HOST_GID=0 "$IMAGE" true 2>&1 >/dev/null)"; then
    expect_contains "R9: отказ при HOST_UID=0" "$ERR9" "refusing"
else
    fail "R9: ожидался отказ при HOST_UID=0"
fi
expect_fail "R10: отказ при нечисловом HOST_UID" \
    docker run --rm -e HOST_UID=abc -e HOST_GID=1000 "$IMAGE" true

# --- R11: git safe.directory (передача GIT_CONFIG_*) ---
capture_eq "R11: PIBOX_GIT_SAFE=1 экспортирует GIT_CONFIG_*" "1|/home/pi/workspace" \
    docker_pibox "$ENV_UID" "$TEST_WS" -e PIBOX_GIT_SAFE=1 -- \
    bash -c 'printf "%s|%s" "$GIT_CONFIG_COUNT" "$GIT_CONFIG_VALUE_0"'
if command -v git >/dev/null 2>&1; then
    git init -q "$TEST_WS/gitrepo" 2>/dev/null || true
    echo hi > "$TEST_WS/gitrepo/file.txt"
    expect_ok "R11: git status в workspace" \
        docker_pibox "$ENV_UID" "$TEST_WS" -e PIBOX_GIT_SAFE=1 -- \
        git -C /home/pi/workspace/gitrepo status
else
    skip "R11: git на хосте не найден"
fi

# --- R12/R13/R14: сеть ---
expect_ok "R12: host.docker.internal резолвится" \
    docker_pibox "$ENV_CAPS" "$TEST_WS" -- getent hosts host.docker.internal
expect_ok "R13: ping host.docker.internal (NET_RAW, file caps ping)" \
    docker_pibox "$ENV_CAPS" "$TEST_WS" -- ping -c 1 -W 3 host.docker.internal
if [ "$OFFLINE" = "1" ]; then
    skip "R14: доступ в интернет (--offline)"
else
    expect_ok "R14: доступ в интернет" \
        docker_pibox "$ENV_CAPS" "$TEST_WS" -- curl -fsS -o /dev/null --max-time 20 https://example.com
fi

# --- R15: capabilities ---
# CapBnd — bounding set (то, чем управляет --cap-add; переживает setuid).
# CapEff — эффективный набор у pi. gosu сбрасывает его при setuid —
# KNOWN-ISSUE: см. docs/NOTES.md (раздел 12) и Правку 2 к entrypoint.sh.
CAP_BND="$(docker_pibox "$ENV_CAPS" "$TEST_WS" -- \
    bash -c 'sed -n "s/^CapBnd:[[:space:]]*//p" /proc/self/status' 2>/dev/null || true)"
CAP_EFF="$(docker_pibox "$ENV_CAPS" "$TEST_WS" -- \
    bash -c 'sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status' 2>/dev/null || true)"
if has_bit "$CAP_BND" 19; then
    ok "R15: CapBnd содержит SYS_PTRACE (бит 19) — --cap-add работает"
else
    fail "R15: SYS_PTRACE нет в CapBnd («${CAP_BND}»)"
fi
if has_bit "$CAP_BND" 13; then
    ok "R15: CapBnd содержит NET_RAW (бит 13)"
else
    fail "R15: NET_RAW нет в CapBnd («${CAP_BND}»)"
fi
if has_bit "$CAP_EFF" 13; then
    ok "R15: CapEff NET_RAW у pi (capabilities эффективны)"
else
    known "R15: CapEff пуст у pi — gosu сбрасывает capabilities при setuid. Критерий приёмки правки entrypoint (Правка 2): этот тест становится зелёным. До правки: strace -p attach / tcpdump от pi не работают; ping работает (file caps)."
fi

# --- R16: ptrace (механика трассировки собственных потомков) ---
expect_ok "R16: ptrace собственного потомка (python)" \
    docker_pibox "$ENV_CAPS" "$TEST_WS" -- python3 -c '
import ctypes, os, signal, sys
libc = ctypes.CDLL(None, use_errno=True)
pid = os.fork()
if pid == 0:
    signal.pause()
    os._exit(0)
ok = libc.ptrace(16, pid, 0, 0) == 0
libc.ptrace(17, pid, 0, 0)
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
sys.exit(0 if ok else 1)
'

# --- R17: лимиты ресурсов (docker inspect) ---
LIMITS_NAME="pibox-smoke-limits"
CLEANUP_CONTAINERS+=("$LIMITS_NAME")
if docker run -d --rm --name "$LIMITS_NAME" \
    --memory 512m --cpus 1 --pids-limit 256 \
    --add-host host.docker.internal:host-gateway \
    --cap-add SYS_PTRACE --cap-add NET_RAW \
    -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID" \
    -v "$ENV_UID:/home/pi" -v "$TEST_WS:/home/pi/workspace" \
    "$IMAGE" sleep 60 >/dev/null 2>&1; then

    ok "R17: контейнер с лимитами запущен"
    expect_eq "R17: memory = 512m" "536870912" \
        "$(docker inspect -f '{{.HostConfig.Memory}}' "$LIMITS_NAME" 2>/dev/null || echo '')"
    expect_eq "R17: cpus = 1" "1000000000" \
        "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$LIMITS_NAME" 2>/dev/null || echo '')"
    expect_eq "R17: pids-limit = 256" "256" \
        "$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$LIMITS_NAME" 2>/dev/null || echo '')"
else
    fail "R17: не удалось запустить контейнер с лимитами"
fi
docker rm -f "$LIMITS_NAME" >/dev/null 2>&1 || true

# --- R18: проброс портов ---
# Внутренний порт 8080 (>1024): pi не имеет CAP_NET_BIND_SERVICE после gosu.
PORT=$(( (RANDOM % 20000) + 20000 ))
PORT_NAME="pibox-smoke-port"
CLEANUP_CONTAINERS+=("$PORT_NAME")
echo "smoke-port-ok" > "$TEST_WS/port-probe.txt"
if docker run -d --rm --name "$PORT_NAME" \
    -p "${PORT}:8080" \
    --add-host host.docker.internal:host-gateway \
    --cap-add SYS_PTRACE --cap-add NET_RAW \
    -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID" \
    -v "$ENV_UID:/home/pi" -v "$TEST_WS:/home/pi/workspace" \
    "$IMAGE" python3 -m http.server 8080 --directory /home/pi/workspace >/dev/null 2>&1; then

    ok "R18: контейнер с http.server запущен (host:${PORT} → конт:8080)"
    BODY=""
    for _ in $(seq 1 40); do
        if BODY="$(curl -fsS "http://127.0.0.1:${PORT}/port-probe.txt" 2>/dev/null)"; then
            break
        fi
        sleep 0.5
    done
    expect_eq "R18: ответ получен через проброшенный порт" "smoke-port-ok" "$BODY"
else
    fail "R18: не удалось запустить контейнер с пробросом порта"
fi
docker rm -f "$PORT_NAME" >/dev/null 2>&1 || true

# --- R19: end-to-end (окружение, созданное CLI) ---
if [ -d "$ENV_E2E" ]; then
    capture_eq "R19: файл workspace виден в контейнере" "probe-content" \
        docker_pibox "$ENV_E2E" "$TEST_WS" -- cat /home/pi/workspace/probe.txt
    expect_ok "R19: models.json из CLI-окружения доступен в контейнере" \
        docker_pibox "$ENV_E2E" "$TEST_WS" -- test -f /home/pi/.pi/agent/models.json
else
    fail "R19: окружение smoke-env не создано (см. C10)"
fi

# ============================================================================
# Итог
# ============================================================================

group "Итог"
printf '\n'
printf '  PASS: %d\n' "$PASS"
if [ "$FAIL" -gt 0 ];  then printf '  FAIL: %d\n' "$FAIL"; fi
if [ "$SKIP" -gt 0 ];  then printf '  SKIP: %d\n' "$SKIP"; fi
if [ "$KNOWN" -gt 0 ]; then printf '  KNOWN-ISSUE: %d (не влияет на результат, см. docs/NOTES.md)\n' "$KNOWN"; fi

if [ "$FAIL" -gt 0 ]; then
    KEEP=1
    printf 'Результат: FAIL — артефакты сохранены для отладки: %s\n' "$TEST_ROOT"
    exit 1
fi
printf 'Результат: PASS\n'
