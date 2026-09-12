#!/usr/bin/env bash
# ============================================================================
# PIBOX — entrypoint контейнера.
#
# Выполняется от root при КАЖДОМ запуске, до старта агента:
#   1. Подстройка UID/GID пользователя pi под хост-пользователя
#      (файлы в workspace принадлежат хост-юзеру, а не root)
#   2. Первичная инициализация: merge /opt/skel -> /home/pi (cp -rn,
#      только недостающие файлы), маркер для идемпотентности
#   3. Опционально: git safe.directory для workspace
#   4. Экспорт окружения (HOME, USER, PATH с mise-шимами)
#   5. Передача управления: exec gosu pi:pi tini -- "$@"
#
# Контракт с Dockerfile (задача 3):
#   - ENTRYPOINT ["/entrypoint.sh"], CMD ["pi"]
#   - /opt/skel — эталонный home (фолбэк-дотфайлы)
#   - gosu, tini — в /usr/bin/
#   - ENV HOME=/home/pi, PATH с mise-шимами — переэкспортируются здесь
#
# Контракт с run.sh (задача 6):
#   - HOST_UID, HOST_GID — передаются через -e
#   - PIBOX_GIT_SAFE=1, PIBOX_RESYNC_SKEL=1 — опциональные флаги
# ============================================================================

set -euo pipefail

# --- Константы ---------------------------------------------------------------

readonly PI_USER="pi"
readonly PI_GROUP="pi"
readonly PI_HOME="/home/pi"
readonly SKEL_DIR="/opt/skel"
readonly MARKER_FILE="${PI_HOME}/.pibox_skel_initialized"
readonly WORKSPACE_DIR="${PI_HOME}/workspace"

# --- Хелперы -----------------------------------------------------------------

log()  { echo "==> pibox: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
err()  { echo "pibox: error: $*" >&2; }
die()  { err "$*"; exit 1; }

# --- 1. Чтение и валидация HOST_UID / HOST_GID -------------------------------

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Валидация: только положительные числа
if ! [[ "$HOST_UID" =~ ^[1-9][0-9]*$ ]]; then
    die "HOST_UID='${HOST_UID}' не является корректным UID (положительное число)"
fi
if ! [[ "$HOST_GID" =~ ^[1-9][0-9]*$ ]]; then
    die "HOST_GID='${HOST_GID}' не является корректным GID (положительное число)"
fi

# Отказ от root: агент не должен маппиться на root хоста
if [ "$HOST_UID" -eq 0 ] || [ "$HOST_GID" -eq 0 ]; then
    die "refusing to map container user to host root (UID/GID=0). \
Это дало бы агенту root-эквивалентные права на файлы хоста."
fi

# --- 2. Подстройка UID/GID пользователя pi -----------------------------------

adjust_uid_gid() {
    local cur_uid cur_gid

    cur_uid="$(id -u "$PI_USER")"
    cur_gid="$(id -g "$PI_USER")"

    # 2a. GID (меняем первым — usermod может завязываться на группу)
    if [ "$cur_gid" != "$HOST_GID" ]; then
        log "adjusting GID of '${PI_GROUP}': ${cur_gid} -> ${HOST_GID}"
        groupmod -o -g "$HOST_GID" "$PI_GROUP"

        # Чиним group-ownership файлов, созданных контейнером под старым GID.
        # Файлы из bind-mount уже имеют правильный GID хоста — их не трогаем.
        # find без -xdev: workspace — отдельный bind-mount внутри /home/pi.
        find "$PI_HOME" -group "$cur_gid" \
            -exec chown -h ":${HOST_GID}" {} + 2>/dev/null || true
    fi

    # 2b. UID
    if [ "$cur_uid" != "$HOST_UID" ]; then
        log "adjusting UID of '${PI_USER}': ${cur_uid} -> ${HOST_UID}"
        usermod -o -u "$HOST_UID" "$PI_USER"

        # Чиним ownership файлов, созданных контейнером под старым UID.
        # (сессии Pi, mise-тулчейны, npm-установки — всё, что pi создал ранее)
        find "$PI_HOME" -user "$cur_uid" \
            -exec chown -h "${HOST_UID}" {} + 2>/dev/null || true
    fi

    # 2c. Гарантия: сам каталог /home/pi принадлежит целевому UID:GID
    chown "${HOST_UID}:${HOST_GID}" "$PI_HOME"
}

# --- 3. Первичная инициализация (skel-merge) ----------------------------------

merge_skel() {
    # 3a. Принудительный повторный merge (флаг из run.sh)
    if [ "${PIBOX_RESYNC_SKEL:-0}" = "1" ]; then
        log "PIBOX_RESYNC_SKEL=1 — removing marker, will re-merge skel"
        rm -f "$MARKER_FILE"
    fi

    # 3b. Уже инициализировано — пропускаем
    if [ -e "$MARKER_FILE" ]; then
        return 0
    fi

    log "first run — merging ${SKEL_DIR} into ${PI_HOME}"

    # 3c. Проверка наличия skel (не фатально — env может не нуждаться)
    if [ ! -d "$SKEL_DIR" ]; then
        warn "skel directory ${SKEL_DIR} not found, skipping merge"
        touch "$MARKER_FILE"
        chown "${HOST_UID}:${HOST_GID}" "$MARKER_FILE"
        return 0
    fi

    # 3d. Копируем ТОЛЬКО недостающие файлы (cp -n = no-clobber).
    #     /. в конце — ОБЯЗАТЕЛЬНО: без него dot-файлы не копируются.
    #     cp выполняется от root → скопированные файлы принадлежат root.
    cp -rn "${SKEL_DIR}/." "${PI_HOME}/"

    # 3e. Чиним владельца ТОЛЬКО у root-owned файлов (только что скопированных).
    #     Файлы из bind-mount (env-template) уже принадлежат хост-юзеру.
    find "$PI_HOME" -user 0 \
        -exec chown -h "${HOST_UID}:${HOST_GID}" {} + 2>/dev/null || true

    # 3f. Создаём маркер (от root, затем чиним владельца)
    touch "$MARKER_FILE"
    chown "${HOST_UID}:${HOST_GID}" "$MARKER_FILE"

    log "skel merge complete, marker: ${MARKER_FILE}"
}

# --- 4. Git safe.directory (опционально) --------------------------------------

setup_git_safe() {
    if [ "${PIBOX_GIT_SAFE:-0}" = "1" ]; then
        log "git safe.directory enabled for ${WORKSPACE_DIR}"

        # Через переменные окружения git — не пишем в файлы пользователя.
        # git читает GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n.
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=safe.directory
        export GIT_CONFIG_VALUE_0="$WORKSPACE_DIR"
    fi
}

# --- 5. Подготовка окружения для exec -----------------------------------------

prepare_env() {
    # КРИТИЧНО: gosu меняет UID/GID, но НЕ переписывает env-переменные.
    # Без явного экспорта:
    #   - Pi пишет сессии в /root/.pi (не в /home/pi/.pi)
    #   - mise-шимы (~/.local/share/mise/shims) не находятся
    #   - npm prefix (~/.npmrc) не резолвится

    export HOME="$PI_HOME"
    export USER="$PI_USER"

    # PATH: user-local bin + mise shims + системные пути.
    # Дублируем ENV из Dockerfile — на случай, если что-то его очистило.
    export PATH="${PI_HOME}/.local/bin:${PI_HOME}/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# --- 6. Передача управления ----------------------------------------------------

exec_command() {
    # gosu pi:pi — смена UID/GID (exec, не fork — PID 1 сохраняется)
    # tini       — PID 1: проброс сигналов, reaping зомби
    # "$@"       — команда из CMD (дефолт: pi) или override (bash, pi -p ...)
    #
    # Процессная цепочка:
    #   PID 1: entrypoint.sh (bash)
    #     → exec gosu (PID 1, замена образа процесса)
    #       → gosu exec tini (PID 1)
    #         → tini fork → child: pi (не PID 1)
    #         → tini wait → signal forwarding, zombie reaping

    if [ "${PIBOX_DEBUG:-0}" = "1" ]; then
        log "exec: gosu ${PI_USER}:${PI_GROUP} tini -- $*"
        log "  HOME=$HOME"
        log "  USER=$USER"
        log "  PATH=$PATH"
        log "  UID=$(id -u $PI_USER) GID=$(id -g $PI_USER)"
    fi

    exec gosu "${PI_USER}:${PI_GROUP}" tini -- "$@"
}

# --- Main ----------------------------------------------------------------------

main() {
    # Проверяем, что мы root (entrypoint должен запускаться от root)
    if [ "$(id -u)" -ne 0 ]; then
        die "entrypoint must run as root (current UID: $(id -u)). \
Check Dockerfile ENTRYPOINT."
    fi

    # Проверяем, что пользователь pi существует
    if ! id "$PI_USER" >/dev/null 2>&1; then
        die "user '${PI_USER}' not found. Image is corrupted or misconfigured."
    fi

    adjust_uid_gid
    merge_skel
    setup_git_safe
    prepare_env
    exec_command "$@"
}

main "$@"
