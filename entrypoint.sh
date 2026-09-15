#!/usr/bin/env bash
# ============================================================================
# PIBOX — entrypoint контейнера.
#
# Выполняется от root при КАЖДОМ запуске, до старта агента:
#   1. Подстройка UID/GID пользователя pi под хост-пользователя
#      (файлы в workspace принадлежат хост-юзеру, а не root)
#   2. Слоёные dot-файлы:
#      ~/.<f> = заглушка с маркером PIBOX_SKELETON_V1
#      ~/.<f>.pibox = сток pibox (обновляется при каждом запуске)
#      ~/.<f>.user = пользовательский слой (миграция из старого .<f>)
#      Прочие skel-файлы — одноразовый cp -rn (как раньше).
#   3. Опционально: git safe.directory для workspace
#   4. Экспорт окружения (HOME, USER, PATH с mise-шимами)
#   5. Передача управления: exec gosu pi:pi tini -- "$@"
#
# Контракт с Dockerfile (задача 3):
#   - ENTRYPOINT ["/entrypoint.sh"], CMD ["pi"]
#   - /opt/skel — эталонный home: заглушки + .pibox-слои + прочие dot-файлы
#   - gosu, tini — в /usr/bin/
#   - ENV HOME=/home/pi, PATH с mise-шимами — переэкспортируются здесь
#
# Контракт с run.sh (задача 6):
#   - HOST_UID, HOST_GID — передаются через -e
#   - PIBOX_GIT_SAFE=1 — опциональный флаг
# ============================================================================

set -euo pipefail

# --- Константы ---------------------------------------------------------------

readonly PI_USER="pi"
readonly PI_GROUP="pi"
readonly PI_HOME="/home/pi"
readonly SKEL_DIR="/opt/skel"

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

# --- 3. Слоёные dot-файлы -----------------
# Единственный источник правды — skel (собирается в Dockerfile):
#   .<f> = заглушка с маркером, .<f>.pibox = сток. Entrypoint только
#   синхронизирует их в home и мигрирует наследие в .<f>.user.

# Один файл: сток/заглушка → из skel, миграция наследия в .<f>.
# $1 — имя файла в skel и хоуме (например .bashrc)
ensure_layered_file() {
    local f="$1"
    local cur="${PI_HOME}/${f}"
    local pibox="${cur}.pibox"
    local user="${cur}.user"

    # 1. Сток pibox — обновляем всегда (этот слой принадлежит pibox)
    if [ -f "${SKEL_DIR}/${f}.pibox" ]; then
        cp -f "${SKEL_DIR}/${f}.pibox" "$pibox"
        chown "${HOST_UID}:${HOST_GID}" "$pibox"
    fi

    # 2. Заглушка: absent или чужой файл (без маркера) → миграция, затем установка из skel
    if [ -f "$cur" ] && ! grep -q "PIBOX_SKELETON" "$cur" 2>/dev/null; then
        # Наследие/пользовательский файл → миграция в .user
        if [ -e "$user" ]; then
            local backup="${user}.bak.$(date +%Y%m%d-%H%M%S)"
            mv "$cur" "$backup"
            warn "${f}: существует и ${f}.user — старый файл сохранён как $(basename "$backup")"
        else
            mv "$cur" "$user"
            log "${f}: существующий файл мигрирован в ${f}.user"
        fi
    fi
    # Заглушка принадлежит pibox — сверяем со skel (cmp: если совпадает —
    # не переписываем, идемпотентность и стабильный mtime)
    if [ ! -f "$cur" ] || ! cmp -s "$cur" "${SKEL_DIR}/${f}"; then
        cp -f "${SKEL_DIR}/${f}" "$cur"
        chown "${HOST_UID}:${HOST_GID}" "$cur"
        log "${f}: заглушка синхронизирована со skel (слои: ${f}.pibox + ${f}.user)"
    fi
}

ensure_dotfiles() {
    # 1. Слоёные файлы (обновление стока + миграция + заглушки).
    # Вход — только если в skel есть ЗАГЛУШКА с маркером (гарантия Dockerfile):
    # это защищает от сюрреалистичного случая, когда skel-файл без маркера
    # превратил бы синхронизацию в бесконечную миграцию.
    if [ -d "$SKEL_DIR" ]; then
        local f
        for f in .bashrc .profile; do
            [ -f "${SKEL_DIR}/${f}.pibox" ] \
                && grep -q "PIBOX_SKELETON" "${SKEL_DIR}/${f}" 2>/dev/null \
                && ensure_layered_file "$f"
        done
    fi

    # 2. Прочие skel-файлы — одноразовый no-clobber merge (как раньше):
    #    .gitconfig, .tmux.conf, .pi/agent/* и т.п. одно-инстансные, слои не нужны.
    local marker="${PI_HOME}/.pibox_other_skel_done"
    if [ ! -e "$marker" ]; then
        if [ -d "$SKEL_DIR" ]; then
            log "first run — merging ${SKEL_DIR} into ${PI_HOME} (no-clobber)"
            cp -rn "${SKEL_DIR}/." "${PI_HOME}/" 2>/dev/null || true
            # заглушки/слои могли только что создаться — не затираем,
            # cp -rn их не тронет (уже существуют)
        else
            warn "skel directory ${SKEL_DIR} not found, skipping merge"
        fi
        touch "$marker"
        chown "${HOST_UID}:${HOST_GID}" "$marker"
    fi

    # 3. Чиним владельца root-owned файлов (только что скопированных)
    find "$PI_HOME" -user 0 \
        -exec chown -h "${HOST_UID}:${HOST_GID}" {} + 2>/dev/null || true

    # 4. Гарантия: сам каталог /home/pi принадлежит целевому UID:GID
    chown "${HOST_UID}:${HOST_GID}" "$PI_HOME"
}


# --- 4. Git safe.directory (опционально) --------------------------------------

setup_git_safe() {
    if [ "${PIBOX_GIT_SAFE:-0}" = "1" ]; then
        log "git safe.directory=* enabled"

        # Через переменные окружения git — не пишем в файлы пользователя.
        # git читает GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n.
        # '*' отключает проверку владельца для всех репозиториев.
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=safe.directory
        export GIT_CONFIG_VALUE_0="*"
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
    ensure_dotfiles
    setup_git_safe
    prepare_env
    exec_command "$@"
}

main "$@"
