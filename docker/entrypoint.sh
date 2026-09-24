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
#   3. npm prefix → $HOME/.local (персистентность глобальных npm-пакетов)
#   4. Опционально: git safe.directory для workspace
#   5. Экспорт окружения (HOME, USER, PATH с mise-шимами)
#   6. Передача управления: exec gosu pi:pi tini -- "$@"
#
# Контракт с docker/Dockerfile — негласные связи; меняя одну сторону,
# согласуй вторую (рассинхрон не даёт ошибок, только ломает запуск):
#   - ENTRYPOINT ["/entrypoint.sh"], CMD ["pi"]: этот скрипт — точка входа,
#     "$@" в конце = команда из CMD;
#   - /opt/skel — эталонный home, собранный в образе: заглушки dot-файлов,
#     .pibox-слои, прочие dot-файлы; entrypoint разворачивает его в /home/pi;
#   - gosu, tini — в /usr/bin/ (пути захардкожены в вызовах ниже);
#   - ENV HOME=/home/pi и PATH с mise-шимами заданы в Dockerfile, но
#     переэкспортируются здесь — после подстановки реального UID.
#
# Контракт с pibox CLI (раньше был файл run.sh, теперь bin/pibox +
# lib/docker-cmd.sh): переменные, которые CLI передаёт через docker run -e
# и этот скрипт читает при старте:
#   - HOST_UID, HOST_GID — UID/GID хост-пользователя (под них подгоняется
#     юзер pi; отсутствуют/пустые → дефолт 1000);
#   - PIBOX_GIT_SAFE=1 — опциональный флаг: включить git safe.directory
#     для workspace.
# ============================================================================

set -euo pipefail

# --- Константы ---------------------------------------------------------------

readonly PI_USER="pi"
readonly PI_GROUP="pi"
readonly PI_HOME="/home/pi"
readonly SKEL_DIR="/opt/skel"

# --- Хелперы -----------------------------------------------------------------

# \r\n: docker run -t переводит хостовый TTY в raw-режим (ONLCR отключён),
# поэтому «голый» \n даёт съехавшие отступы. В cooked-режиме лишний \r
# безвреден (терминал схлопывает \r\r\n).
log() { printf '%s\r\n' "==> pibox: $*" >&2; }
warn() { printf '%s\r\n' "pibox: warn:  $*" >&2; }
err() { printf '%s\r\n' "pibox: error: $*" >&2; }
die() {
    err "$*"
    exit 1
}

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
#
# ДОГОВОР О ВЛАДЕЛЬЦЕ ФАЙЛОВ: весь /home/pi — bind-mount хоста, поэтому
# ВСЕ файлы в нём считаются принадлежащими хост-юзеру (HOST_UID:HOST_GID).
# pi всегда работает уже с финальными UID/GID (gosu после usermod), так что
# созданные им файлы имеют правильного владельца по построению.
# Рекурсивный chown home на каждом старте НЕ делаем: это обход десятков
# тысяч файлов ради пустого результата. Владелец чинится ТОЛЬКО у файлов,
# скопированных из skel (см. ensure_dotfiles).
# Если env-каталог переносился между машинами с разным UID хоста — разовый
# `chown -R` на хосте (вне контейнера).

adjust_uid_gid() {
    local cur_uid cur_gid

    cur_uid="$(id -u "$PI_USER")"
    cur_gid="$(id -g "$PI_USER")"

    # 2a. GID (меняем первым — usermod может завязываться на группу)
    if [ "$cur_gid" != "$HOST_GID" ]; then
        log "adjusting GID of '${PI_GROUP}': ${cur_gid} -> ${HOST_GID}"
        groupmod -o -g "$HOST_GID" "$PI_GROUP"
    fi

    # 2b. UID
    if [ "$cur_uid" != "$HOST_UID" ]; then
        log "adjusting UID of '${PI_USER}': ${cur_uid} -> ${HOST_UID}"
        usermod -o -u "$HOST_UID" "$PI_USER"
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
            local backup
            backup="${user}.bak.$(date +%Y%m%d-%H%M%S)"
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
            [ -f "${SKEL_DIR}/${f}.pibox" ] &&
                grep -q "PIBOX_SKELETON" "${SKEL_DIR}/${f}" 2>/dev/null &&
                ensure_layered_file "$f"
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
            # Владельца root чиним ТОЛЬКО у только что скопированного и
            # ТОЛЬКО здесь (первый запуск env): других root-owned файлов
            # entrypoint не создаёт, остальное — собственность хост-юзера.
            # -xdev: workspace — отдельный bind-mount, entrypoint там
            # ничего не создаёт, обходить его не нужно.
            find "$PI_HOME" -xdev -user 0 \
                -exec chown -h "${HOST_UID}:${HOST_GID}" {} + 2>/dev/null || true
        else
            warn "skel directory ${SKEL_DIR} not found, skipping merge"
        fi
        touch "$marker"
        chown "${HOST_UID}:${HOST_GID}" "$marker"
    fi

    # 3. Гарантия: сам каталог /home/pi принадлежит целевому UID:GID
    chown "${HOST_UID}:${HOST_GID}" "$PI_HOME"
}

# --- 4. npm prefix --------------------------------------------------------------
# По умолчанию npm ставит глобальные пакеты в /usr/local (внутри образа —
# не персистентно, гибнет при перезапуске). Принудительно направляем prefix
# в $HOME (bind-mount, персистентно) при каждом запуске.
# npm config set обновляет точечно: registry, _authToken (npm login) и прочие
# пользовательские ключи ~/.npmrc не затрагиваются (проверено; комментарии
# в файле npm перепишет в key=value — файл машиночитаемый, это ок).
# ВАЖНО: запуск под gosu pi — файл должен принадлежать pi, иначе npm login
# не сможет его перезаписать (EACCES).
ensure_npm_prefix() {
    mkdir -p "$PI_HOME/.local"
    chown "${HOST_UID}:${HOST_GID}" "$PI_HOME/.local"
    if ! gosu "${PI_USER}:${PI_GROUP}" npm config set prefix ${PI_HOME}/.local \
        --userconfig "${PI_HOME}/.npmrc" >/dev/null 2>&1; then
        warn "npm: не удалось установить prefix=/home/pi/.local " \
            "(npm install -g будет неперсистентным)"
    fi
}

# --- 4a. Шимы SDK для расширений -----------------------------------------------
# Pi + SDK (@earendil-works/pi-coding-agent, pi-tui, pi-ai) живут в
# /usr/local/lib/node_modules (в образе), а расширения — в персистентном
# ~/.pi/agent/npm/node_modules (bind-mount). Раннеры расширений (напр.
# субагенты) резолвят SDK вверх по дереву от себя — в npm-дерево окружения,
# куда SDK не попадает. Лечится шим-пакетами: package.json + index.js с
# одним реэкспортом настоящего SDK из /usr/local.
# npm при pi install/pi remove пересчитывает дерево и ВЫЧИЩАЕТ чужие пакеты —
# поэтому шимы восстанавливаем при каждом старте (идемпотентно; живой
# настоящий пакет на месте шима не трогаем).
ensure_sdk_shims() {
    local sdk="/usr/local/lib/node_modules/@earendil-works/pi-coding-agent"
    [ -d "$sdk" ] || return 0 # SDK нет в образе (нестандартная сборка) — неча шимить
    local real_shim_dir="$PI_HOME/.pi/agent/npm/node_modules/@earendil-works"
    local shim name dep
    for name in pi-coding-agent pi-tui pi-ai; do
        # pi-coding-agent — верхнеуровневый SDK; pi-tui/pi-ai — вложенные
        # зависимости внутри него (npm дедупнул их в его node_modules)
        if [ "$name" = "pi-coding-agent" ]; then
            dep="$sdk"
        else
            dep="$sdk/node_modules/@earendil-works/$name"
        fi
        [ -d "$dep" ] || continue # нет в этом SDK — шим не нужен
        shim="$real_shim_dir/$name"
        # Живой настоящий пакет уже стоит (не наш шим) — не трогаем.
        if [ -f "$shim/package.json" ] && ! grep -q '"pibox-shim"' "$shim/package.json" 2>/dev/null; then
            continue
        fi
        mkdir -p "$shim"
        cat >"$shim/package.json" <<EOF
{
  "name": "@earendil-works/$name",
  "version": "0.0.0-pibox-shim",
  "description": "pibox shim: re-exports the real SDK from /usr/local (restored by entrypoint)",
  "type": "module",
  "pibox-shim": true
}
EOF
        cat >"$shim/index.js" <<EOF
export * from "$dep/dist/index.js";
EOF
        chown -R "${HOST_UID}:${HOST_GID}" "$shim"
    done
}

# --- 5. Git safe.directory (опционально) --------------------------------------

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

# --- 6. Подготовка окружения для exec -----------------------------------------

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

    # Дефолты расширений: задаём, только если не передано извне
    # (pibox -E FACELIFT_MAX_PREVIEW_LINES=... или --env-file).
    # pi-facelift: максимум строк предпросмотра в выводе инструментов.
    export FACELIFT_MAX_PREVIEW_LINES="${FACELIFT_MAX_PREVIEW_LINES:-24}"
}

# --- 7. Передача управления ----------------------------------------------------

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
    ensure_npm_prefix
    ensure_sdk_shims
    setup_git_safe
    prepare_env
    exec_command "$@"
}

main "$@"
