#!/usr/bin/env bash
# ============================================================================
# PIBOX — CLI для безопасного запуска Pi Coding Agent в Docker.
#
# Подкоманды:
#   run (дефолт)   запуск агента в контейнере
#   build          сборка Docker-образа
#   env            управление окружениями (list, create, remove)
#   shell          отладочная оболочка в контейнере
#   update         обновление установки
#   doctor         диагностика окружения (аудит + --fix)
#   extensions     установка расширений из манифеста env/extensions.txt
#
# Опции запуска:
#   -e, --env NAME         окружение (по умолчанию default)
#   -p, --publish SPEC     проброс порта (повторяемая)
#   -E, --pass-env VAR     проброс переменной окружения (повторяемая)
#       --env-file FILE    файл с переменными окружения
#       --memory LIMIT     лимит памяти (напр. 4g)
#       --cpus N           лимит CPU
#       --pids-limit N     лимит процессов
#       --git-safe         git safe.directory для workspace
#       --keep             оставить контейнер после выхода (для отладки)
#       --dry-run          напечатать команду docker run и выйти
#       --name NAME        имя контейнера (по умолчанию pibox-<env>)
#   -h, --help             эта справка
#   -V, --version          версия
#
# Контракт с entrypoint.sh (задача 5):
#   Передаёт HOST_UID, HOST_GID, PIBOX_GIT_SAFE через -e
# ============================================================================

set -euo pipefail

# --- Константы ----------------------------------------------------------------

VERSION="0.1.0"
DEFAULT_ENV="default"
# Имя образа можно переопределить (smoke-тесты используют это для проверки
# поведения при отсутствии образа); по умолчанию — pibox:latest
IMAGE_NAME="${PIBOX_IMAGE:-pibox:latest}"

# Определяем PIBOX_DIR относительно расположения скрипта.
# Если скрипт лежит в каталоге bin — поднимаемся на уровень выше,
# иначе берём директорию скрипта. Имя скрипта не важно.
_src="${BASH_SOURCE[0]}"
_script_dir="$(cd -- "$(dirname -- "$_src")" && pwd)"
_pibox_default="$_script_dir"
[[ "$(basename -- "$_script_dir")" == "bin" ]] && _pibox_default="$(dirname -- "$_script_dir")"
PIBOX_DIR="${PIBOX_DIR:-$_pibox_default}"

# --- Хелперы -------------------------------------------------------------------

# \r\n: docker run -t переводит хостовый TTY в raw-режим (ONLCR отключён),
# поэтому «голый» \n даёт съехавшие отступы. В cooked-режиме лишний \r
# безвреден (терминал схлопывает \r\r\n).
err() { printf '%s\r\n' "pibox: error: $*" >&2; }
warn() { printf '%s\r\n' "pibox: warn:  $*" >&2; }
log() { printf '%s\r\n' "==> pibox: $*" >&2; }
die() {
    err "$*"
    exit 1
}

version() {
    echo "pibox ${VERSION}"
}

usage() {
    cat <<'EOF'
pibox — запуск Pi Coding Agent в изолированном Docker-контейнере

Использование:
    pibox [run] [OPTIONS] [--] [PI_ARGS...]

Подкоманды:
    run                        запуск агента (по умолчанию)
    build [--no-cache]         сборка Docker-образа
    env list|create|remove     управление окружениями
    shell [-e NAME]            отладочная оболочка в контейнере
    update                     обновление установки
    doctor [-e NAME] [--fix]   диагностика окружения (аудит + --fix)
    extensions install         установка расширений из манифеста
                               env/extensions.txt (см. ниже)

Опции extensions:
    pibox extensions install [-e NAME]
                               установить набор расширений в окружение NAME
                               (по умолчанию default). Окружение должно
                               существовать: pibox env create NAME. Ставит
                               недостающее/обновляет расхождение с манифестом;
                               уже установленное совпадающей версии пропускает.
                               При выполнении npm-установок агент НЕ запускается —
                               используется одноразовый контейнер.

Опции запуска:
    -e, --env NAME             окружение (по умолчанию default)
    -p, --publish SPEC         проброс порта (повторяемая)
    -E, --pass-env VAR         проброс переменной окружения (повторяемая)
        --env-file FILE        файл с переменными окружения
        --memory LIMIT         лимит памяти (напр. 4g)
        --cpus N               лимит CPU
        --pids-limit N         лимит процессов
        --git-safe             git safe.directory для workspace
        --keep                 оставить контейнер после выхода (для отладки)
        --dry-run              напечатать команду docker run и выйти
        --name NAME            имя контейнера (по умолчанию pibox-<env>)
    -h, --help                 эта справка
    -V, --version              версия

Примеры:
    pibox                      # запуск в default окружении
    pibox -e php8              # запуск в окружении php8
    pibox -p 8080:80           # проброс порта 8080 на 80
    pibox -- pi -p "test"      # передача аргументов pi
    pibox shell -e php8        # оболочка в окружении php8
    pibox --keep               # оставить контейнер после выхода
    pibox extensions install   # эталонный набор расширений в default

EOF
}

# --- Проверки -------------------------------------------------------------------

# Проверка, что docker установлен и работает
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"
    fi

    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon не отвечает. Проверьте статус: systemctl status docker"
    fi
}

# Проверка имени окружения
validate_env_name() {
    local env_name="$1"
    if [[ ! "$env_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        die "Недопустимое имя окружения: '$env_name'. Разрешены буквы, цифры, точки, дефисы и подчёркивания."
    fi
}

# Проверка, что workspace не совпадает с PIBOX_DIR и не вложен в него
check_workspace_isolation() {
    local ws
    ws="$(pwd)"
    local ws_real
    local pibox_real

    # Получаем абсолютные пути без symlink'ов
    ws_real="$(realpath "$ws")"
    pibox_real="$(realpath "$PIBOX_DIR")"

    # Проверяем вложенность
    if [[ "$ws_real" == "$pibox_real" || "$ws_real" == "$pibox_real"/* ]]; then
        die "Workspace ($ws) находится внутри PIBOX_DIR ($PIBOX_DIR). Это запрещено."
    fi

    if [[ "$pibox_real" == "$ws_real"/* ]]; then
        die "PIBOX_DIR ($PIBOX_DIR) находится внутри workspace ($ws). Это запрещено."
    fi
}

# --- Управление окружениями -----------------------------------------------------

# Создание окружения из шаблона env/.template, если оно не существует
create_env() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local template_dir="$PIBOX_DIR/env/.template"

    if [[ ! -d "$env_dir" ]]; then
        if [[ ! -d "$template_dir" ]]; then
            die "Шаблон окружения не найден: $template_dir. Переустановите pibox: install.sh"
        fi
        log "Создаю окружение '$env_name' из шаблона..."
        mkdir -p "$env_dir"
        cp -a "$template_dir/." "$env_dir/"
    fi
}

# Копирование models.json в окружение при первом запуске
copy_models_json() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local models_src="$PIBOX_DIR/models.json"
    local models_dst="$env_dir/.pi/agent/models.json"

    # Копируем только если источник существует и назначение отсутствует
    if [[ -f "$models_src" && ! -f "$models_dst" ]]; then
        mkdir -p "$(dirname "$models_dst")"
        cp "$models_src" "$models_dst"
        log "Скопирован models.json в окружение '$env_name'"
    fi
}

# Список доступных окружений
list_envs() {
    echo "Доступные окружения:"
    local env_dir
    for env_dir in "$PIBOX_DIR/env"/*; do
        [[ -d "$env_dir" ]] || continue
        echo "  $(basename "$env_dir")"
    done
}

# --- Манифест расширений ---------------------------------------------------------

EXTENSIONS_FILE="env/extensions.txt"

# Читает манифест расширений (строки вида npm:имя@версия).
# Заполняет глобальный массив EXT_ENTRIES; при отсутствии файла — пустой.
load_extensions_manifest() {
    local manifest="$PIBOX_DIR/$EXTENSIONS_FILE"
    EXT_ENTRIES=()
    [[ -f "$manifest" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* ]] && continue # строка-комментарий целиком
        line="${line%\#*}"               # хвостовой комментарий
        # нормализуем пробелы по краям
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        EXT_ENTRIES+=("$line")
    done <"$manifest"
}

# Разбирает запись "npm:имя@версия" -> EXT_NAME, EXT_VER.
# Возвращает 1, если запись не разобрана.
parse_ext_entry() {
    EXT_NAME=""
    EXT_VER=""
    local entry="$1"
    [[ "$entry" == npm:* ]] || return 1
    local body="${entry#npm:}"
    EXT_VER="${body##*@}"
    EXT_NAME="${body%@*}"
    [[ -n "$EXT_NAME" && -n "$EXT_VER" ]] || return 1
    local bare="${EXT_NAME#@}" # scope-пакеты (@scope/name) допустимы, @ внутри имени — нет
    [[ "$bare" != *@* ]] || return 1
}

# Читает список пакетов из settings.json окружения (jq).
# Заполняет EXT_SETTINGS_PACKAGES.
load_settings_packages() {
    local settings="$1"
    EXT_SETTINGS_PACKAGES=()
    [[ -f "$settings" ]] || return 0
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        EXT_SETTINGS_PACKAGES+=("$p")
    done < <(jq -r '.packages[]?' "$settings" 2>/dev/null)
}

# Установленная версия npm-пакета в env (пусто, если не установлен).
# $1 - каталог node_modules, $2 - имя пакета (со scope).
get_installed_ext_version() {
    local nm="$1" name="$2" pj
    pj="$nm/$name/package.json"
    [[ -f "$pj" ]] || {
        printf ''
        return
    }
    jq -r '.version // empty' "$pj" 2>/dev/null || printf ''
}

# --- Сборка команды docker run --------------------------------------------------

# Глобальный массив, в который собирается готовая команда docker run.
RUN_CMD=()

# Заполняет RUN_CMD аргументами для docker run.
# Использует переменные окружения: ENV_NAME, CONTAINER_NAME, MEMORY, CPUS,
# PIDS_LIMIT, GIT_SAFE, ENV_FILE, а также массивы
# PUBLISH_OPTS, PASS_ENV_OPTS и PI_ARGS (видны динамически из cmd_run).
build_docker_run_cmd() {
    RUN_CMD=(
        "docker" "run"
        "--name" "$CONTAINER_NAME"
        "--add-host" "host.docker.internal:host-gateway"
        "--cap-add" "SYS_PTRACE"
        "--cap-add" "NET_RAW"
    )

    # Опции ресурсов (с дефолтами)
    RUN_CMD+=("--memory" "${MEMORY:-4g}")
    RUN_CMD+=("--cpus" "${CPUS:-2}")
    RUN_CMD+=("--pids-limit" "${PIDS_LIMIT:-512}")

    # Переменные окружения для entrypoint.sh (задача 5)
    RUN_CMD+=("-e" "HOST_UID=$(id -u)")
    RUN_CMD+=("-e" "HOST_GID=$(id -g)")
    RUN_CMD+=("-e" "PIBOX_GIT_SAFE=${GIT_SAFE:-0}")

    # Монтирования
    RUN_CMD+=("-v" "$PIBOX_DIR/env/$ENV_NAME:/home/pi")
    RUN_CMD+=("-v" "$(pwd):/home/pi/workspace")
    # Персистентный кэш jiti (трансляция TS-расширений pi): иначе /tmp/jiti
    # пересоздаётся при каждом запуске и первый старт pi уходит на компиляцию.
    RUN_CMD+=("-v" "$PIBOX_DIR/env/$ENV_NAME/.cache/jiti:/tmp/jiti")

    # Проброс портов (совместимо с bash 3.2 + set -u)
    local opt
    for opt in ${PUBLISH_OPTS[@]+"${PUBLISH_OPTS[@]}"}; do
        RUN_CMD+=("-p" "$opt")
    done

    # Проброс переменных окружения
    for opt in ${PASS_ENV_OPTS[@]+"${PASS_ENV_OPTS[@]}"}; do
        RUN_CMD+=("-e" "$opt")
    done

    # Файл переменных окружения
    if [[ -n "${ENV_FILE:-}" ]]; then
        RUN_CMD+=("--env-file" "$ENV_FILE")
    fi

    # Интерактивность (только если TTY)
    if [[ -t 0 && -t 1 ]]; then
        RUN_CMD+=("-it")
    else
        RUN_CMD+=("-i")
    fi

    # Образ и команда
    RUN_CMD+=("$IMAGE_NAME")

    # Аргументы pi (после --)
    for opt in ${PI_ARGS[@]+"${PI_ARGS[@]}"}; do
        RUN_CMD+=("$opt")
    done
}

# Печатает команду в shell-escape виде (для --dry-run)
print_run_cmd() {
    local a
    printf 'DRY RUN:'
    for a in ${RUN_CMD[@]+"${RUN_CMD[@]}"}; do
        printf ' %q' "$a"
    done
    printf '\n'
}

# --- Подкоманды -----------------------------------------------------------------

# Основная команда: запуск pi в контейнере
cmd_run() {
    local -a PI_ARGS=()
    local -a PUBLISH_OPTS=()
    local -a PASS_ENV_OPTS=()

    local ENV_NAME=""
    local CONTAINER_NAME=""
    local ENV_FILE=""
    local MEMORY=""
    local CPUS=""
    local PIDS_LIMIT=""
    local GIT_SAFE=""
    local DRY_RUN="0"
    local KEEP="0"

    # Разбор аргументов для run
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --)
            shift
            PI_ARGS=("$@")
            break
            ;;
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            ENV_NAME="$2"
            shift 2
            ;;
        -p | --publish)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            PUBLISH_OPTS+=("$2")
            shift 2
            ;;
        -E | --pass-env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            PASS_ENV_OPTS+=("$2")
            shift 2
            ;;
        --env-file)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            ENV_FILE="$2"
            shift 2
            ;;
        --memory)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            MEMORY="$2"
            shift 2
            ;;
        --cpus)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            CPUS="$2"
            shift 2
            ;;
        --pids-limit)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            PIDS_LIMIT="$2"
            shift 2
            ;;
        --git-safe)
            GIT_SAFE=1
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --name)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -V | --version)
            version
            exit 0
            ;;
        *)
            err "Неизвестная опция или аргумент для run: $1"
            usage
            exit 1
            ;;
        esac
    done

    # Дефолты
    ENV_NAME="${ENV_NAME:-$DEFAULT_ENV}"
    CONTAINER_NAME="${CONTAINER_NAME:-pibox-${ENV_NAME}}"

    # Проверки
    check_docker
    validate_env_name "$ENV_NAME"
    check_workspace_isolation

    # Автосоздание окружения
    create_env "$ENV_NAME"
    copy_models_json "$ENV_NAME"

    # Проверка образа (не собираем в dry-run)
    if [[ "$DRY_RUN" != "1" ]]; then
        if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
            warn "Образ $IMAGE_NAME не найден. Собираю..."
            cmd_build
        fi
    fi

    # Сборка команды
    build_docker_run_cmd

    # Dry-run: печатаем и выходим
    if [[ "$DRY_RUN" == "1" ]]; then
        print_run_cmd
        return 0
    fi

    # Убираем возможный «хвост» от прошлого запуска (в т.ч. --keep)
    if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        warn "Найден существующий контейнер '$CONTAINER_NAME', удаляю..."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Каталог кэша jiti: создаётся от хост-юзера ДО docker run, иначе docker
    # создаст bind-mount-цель от root и pi не сможет туда писать.
    mkdir -p "$PIBOX_DIR/env/$ENV_NAME/.cache/jiti"

    log "Запуск pi в окружении '$ENV_NAME' (контейнер: $CONTAINER_NAME)..."

    # Запуск. Ловим код возврата вручную, чтобы set -e не убил скрипт
    # до обработки cleanup-логики.
    local rc=0
    "${RUN_CMD[@]}" || rc=$?

    # Постобработка: при успехе и без --keep удаляем контейнер.
    # Во всех остальных случаях оставляем и подсказываем, как посмотреть.
    if [[ $rc -eq 0 && "$KEEP" != "1" ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        log "Контейнер '$CONTAINER_NAME' удалён"
    else
        if [[ $rc -ne 0 ]]; then
            warn "Контейнер завершился с кодом $rc и оставлен для отладки"
        else
            warn "Контейнер оставлен (--keep)"
        fi
        warn "  имя:     $CONTAINER_NAME"
        warn "  логи:    docker logs $CONTAINER_NAME"
        warn "  shell:   docker exec -it $CONTAINER_NAME bash"
        warn "  удалить: docker rm -f $CONTAINER_NAME"
    fi

    return $rc
}

# Сборка Docker-образа
cmd_build() {
    local no_cache=""

    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --no-cache)
            no_cache="--no-cache"
            shift
            ;;
        *)
            err "Неизвестная опция для build: $1"
            usage
            exit 1
            ;;
        esac
    done

    check_docker

    log "Собираю образ $IMAGE_NAME..."
    docker build $no_cache -t "$IMAGE_NAME" "$PIBOX_DIR/docker"
}

# Управление окружениями
cmd_env() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
    list)
        list_envs
        ;;
    create)
        if [[ $# -lt 1 ]]; then
            die "env create требует имя окружения"
        fi
        local env_name="$1"
        validate_env_name "$env_name"
        create_env "$env_name"
        copy_models_json "$env_name"
        log "Окружение '$env_name' создано"
        ;;
    remove)
        if [[ $# -lt 1 ]]; then
            die "env remove требует имя окружения"
        fi
        local env_name="$1"
        validate_env_name "$env_name"
        if [[ "$env_name" == "default" ]]; then
            die "Нельзя удалить default окружение"
        fi
        local env_dir="$PIBOX_DIR/env/$env_name"
        if [[ -d "$env_dir" ]]; then
            rm -rf "$env_dir"
            log "Окружение '$env_name' удалено"
        else
            warn "Окружение '$env_name' не существует"
        fi
        ;;
    *)
        die "Неизвестная подкоманда env: $subcmd"
        ;;
    esac
}

# Отладочная оболочка в контейнере
cmd_shell() {
    local env_name="$DEFAULT_ENV"

    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            env_name="$2"
            shift 2
            ;;
        *)
            die "Неизвестная опция для shell: $1"
            ;;
        esac
    done

    validate_env_name "$env_name"
    create_env "$env_name"
    copy_models_json "$env_name"
    check_workspace_isolation

    check_docker

    # Персистентный кэш jiti — как в build_docker_run_cmd; mkdir от хост-юзера.
    mkdir -p "$PIBOX_DIR/env/$env_name/.cache/jiti"

    log "Запуск оболочки в окружении '$env_name'..."
    docker run --rm -it \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v "$PIBOX_DIR/env/$env_name:/home/pi" \
        -v "$(pwd):/home/pi/workspace" \
        -v "$PIBOX_DIR/env/$env_name/.cache/jiti:/tmp/jiti" \
        "$IMAGE_NAME" bash
}

# Установка расширений из манифеста env/extensions.txt.
#
# Каждый пакет ставится отдельным запуском pi внутри одноразового контейнера
# (смонтирован только env; workspace не нужен — npm-установки ни от него
# не зависят, а монтирование произвольного cwd в фоновую операцию — лишний риск).
# pi сам кладёт файлы под хост-пользователя? Нет: контейнер работает от pi
# (uid=HOST_UID через entrypoint), поэтому файлы в bind-mount сразу с
# владельцем хост-юзера — chown не нужен.
#
# Пропускает уже установленное совпадающей версии; для остальных вызывает
# pi install npm:имя@версия. settings.json окружения дополняется записями

# --- живая визуализация установки (в стиле docker build) ---------------------
#
# В TTY: постоянная область экрана — зелёная строка статуса «▸ [n/N] pkg (Xs)»
# с секундомером и под ней серое скользящее окно из N последних строк вывода
# команды. По завершении пакета строка «✓ pkg (Xs)» фиксируется (уходит в
# скроллбэк), окно очищается для следующего пакета. Вне TTY — простой вывод.
# Полный журнал команды пишется в $tmpdir/full.log (показывается при ошибке).
#
# Портируемость (macOS): без flock, без mapfile, без GNU date -r. Конкурентный
# рендер устранён архитектурно: рисует ТОЛЬКО фоновый таймер; читатель вывода
# лишь дописывает строки в файл окна (одиночный O_APPEND-write атомарен).
_EXT_WIN_LINES="${PIBOX_EXT_WINDOW:-10}"
_EXT_TICK="${PIBOX_EXT_TICK:-0.5}"

_ext_strip_ansi() {
    # убрать ANSI-коды и CR, чтобы строки окна имели предсказуемую длину
    tr -d '\r' | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g'
}

_ext_render() {
    # $1 — строка статуса (plain), $2 — цвет (32/33/31), $3 — файл окна.
    # Печатает область «статус + окно» от текущей позиции курсора и ВОЗВРАЩАЕТ
    # курсор на строку статуса — следующий рендер/commit/erase начинает
    # оттуда же, никаких пустых строк-заполнителей не нужно. Пока строк
    # меньше _EXT_WIN_LINES, окно растёт вниз от статуса; лишние строки
    # вытесняются сверху (скролл). Хвост ниже окна стирается \033[J.
    # Вызывается только из фонового таймера — блокировка не нужна.
    local status="$1" color="$2" winfile="$3"
    local nshown k
    [[ -t 2 ]] || return 0
    printf '\033[%sm%s\033[0m\033[K\n' "$color" "$status"
    # последние N непустых строк окна (без mapfile — совместимо с bash 3.2)
    nshown=$(grep -c . "$winfile" 2>/dev/null) || nshown=0
    ((nshown > _EXT_WIN_LINES)) && nshown=$_EXT_WIN_LINES
    for ((k = nshown; k > 0; k--)); do
        printf '\033[90m  │ %s\033[0m\033[K\n' "$(tail -n "$k" "$winfile" 2>/dev/null | head -n 1)"
    done
    # вернуться на строку статуса (курсор после последнего \n — на строке
    # ниже окна, значит вверх nshown+1), колонку — в начало строки
    printf '\033[%dA\r' "$((nshown + 1))"
}

_ext_timer_loop() {
    # фоновый секундомер-рендерер: 2 раза в секунду перерисовывает статус и окно,
    # пока существует файл-флаг $1. Единственный, кто рисует во время установки.
    local running="$1" statusfile="$2" startfile="$3" winfile="$4"
    local status start now elapsed line
    while [[ -f "$running" ]]; do
        status="$(cat "$statusfile" 2>/dev/null)"
        start="$(cat "$startfile" 2>/dev/null)"
        now="$(date +%s)"
        if [[ "$start" =~ ^[0-9]+$ ]]; then elapsed=$((now - start)); else elapsed=0; fi
        line="▸ ${status} (${elapsed}s)"
        # жёлтый в процессе установки — зелёным строка станет в _ext_commit
        _ext_render "$line" 33 "$winfile" >&2
        sleep "$_EXT_TICK"
    done
}

_ext_commit() {
    # зафиксировать итог пакета: курсор стоит на строке статуса (так оставляет
    # _ext_render) — стереть живую область вниз (\033[J), затем напечатать
    # строку «✓/✗ …» навсегда в скроллбэк. Курсор оказывается в начале
    # следующей строки — следующий пункт добавится ниже, предыдущие не
    # затираются.
    local line="$1" color="$2"
    [[ -t 2 ]] || return 0
    printf '\033[J'
    printf '\033[%dm%s\033[0m\n' "$color" "$line"
}

_ext_erase_region() {
    # стереть живую область (окно+статус) от строки статуса вниз
    [[ -t 2 ]] || return 0
    printf '\033[J'
}

_ext_on_interrupt() {
    # обработка Ctrl+C во время установки: остановить таймер, стереть живую
    # область, вернуть курсор, выйти с кодом 130 (как принято для SIGINT).
    # Курсор в момент прерывания стоит на строке статуса — \033[J стирает
    # область вниз.
    local running="$1" tpid="$2"
    rm -f "$running" 2>/dev/null
    if [[ -n "$tpid" ]]; then
        # таймер уже мог умереть от того же SIGINT — ошибки игнорируем:
        # ловушка работает при set -e, ненулевой статус убил бы её до exit 130
        kill "$tpid" 2>/dev/null || true
        wait "$tpid" 2>/dev/null || true
    fi
    if [[ -t 2 ]]; then
        printf '\033[J\033[?25h' >&2
    fi
    err "прервано пользователем — незавершённые пакеты можно доустановить повторным запуском"
    exit 130
}

_ext_show_cursor() {
    [[ -t 2 ]] || return 0
    printf '\033[?25h' >&2
}
# из манифеста (без дублей) — это включает загрузку расширений в pi.
cmd_extensions() {
    local subcmd="${1:-}"
    [[ "$subcmd" == "install" ]] || {
        err "использование: pibox extensions install [-e ИМЯ]"
        exit 1
    }
    shift

    local env_name="$DEFAULT_ENV"
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            env_name="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестная опция для extensions install: $1"
            usage
            exit 1
            ;;
        esac
    done

    validate_env_name "$env_name"

    local env_dir="$PIBOX_DIR/env/$env_name"
    if [[ ! -d "$env_dir" ]]; then
        die "окружение '$env_name' не найдено — создайте: pibox env create $env_name"
    fi

    load_extensions_manifest
    if [[ ${#EXT_ENTRIES[@]} -eq 0 ]]; then
        die "манифест пуст или отсутствует: $PIBOX_DIR/$EXTENSIONS_FILE"
    fi

    check_docker
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        die "образ $IMAGE_NAME не найден — соберите: pibox build"
    fi

    local nm="$env_dir/.pi/agent/npm/node_modules"
    local total=${#EXT_ENTRIES[@]}
    local installed=0 skipped=0 failed=0 idx=0
    local entry have
    local -a need_install=() need_settings=()

    # Фаза планирования — молча: решаем, что ставить. Ничего не печатаем,
    # чтобы пользователь видел прогресс шаг за шагом, а не список заранее.
    # actions[] параллелен EXT_ENTRIES: "skip" | "install" (пусто = не разобрали).
    log "Расширения окружения '$env_name' ($total в манифесте)..."
    local -a actions=()
    for entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
        idx=$((idx + 1))
        if ! parse_ext_entry "$entry"; then
            warn "[$idx/$total] не могу разобрать запись манифеста: $entry"
            failed=$((failed + 1))
            continue
        fi
        have="$(get_installed_ext_version "$nm" "$EXT_NAME")"
        if [[ "$have" == "$EXT_VER" ]]; then
            actions+=("skip")
            skipped=$((skipped + 1))
        else
            actions+=("install")
            need_install+=("$entry")
        fi
        need_settings+=("$entry")
    done

    # Установка: по одному пакету за запуск pi. Чужая ошибка не рушит остаток;
    # ошибка одного пакета не должна блокировать остальные (npm-дерево общее,
    # но установки pi идемпотентны — безопасно перезапускать).
    if [[ ${#need_install[@]} -eq 0 ]]; then
        # всё уже установлено — зелёные строки по числу расширений манифеста
        local a_idx=0 e
        for e in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
            a_idx=$((a_idx + 1))
            parse_ext_entry "$e" || continue # warn уже выведен при планировании
            if [[ -t 2 ]]; then
                printf '\033[32m✓ [%d/%d] %s@%s — уже установлен\033[0m\n' \
                    "$a_idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
            else
                printf '✓ [%d/%d] %s@%s — уже установлен\n' \
                    "$a_idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
            fi
        done
    else
        local tty_render=0
        [[ -t 2 ]] && tty_render=1
        local tmpdir winfile statusfile startfile running fulllog tpid
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pibox-ext.XXXXXX")"
        winfile="$tmpdir/window"
        statusfile="$tmpdir/status"
        startfile="$tmpdir/start"
        running="$tmpdir/running"
        fulllog="$tmpdir/full.log"
        : >"$winfile"
        : >"$fulllog"

        local cur=0 ok_line ok_color elapsed now
        local START_TS entry_act
        local idx=0 # сброс: idx уже использован в фазе планирования
        local a_idx=0
        if [[ $tty_render -eq 1 ]]; then
            printf '\033[?25l' >&2 # скрыть курсор на всю установку — один раз
        fi
        trap '_ext_on_interrupt "$running" "${tpid:-}"' INT TERM
        for entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
            idx=$((idx + 1))
            parse_ext_entry "$entry" || continue # warn уже выведен при планировании
            entry_act=""
            if [[ $a_idx -lt ${#actions[@]} ]]; then
                entry_act="${actions[$a_idx]}"
            fi
            a_idx=$((a_idx + 1))
            if [[ "$entry_act" == "skip" ]]; then
                # пропуск печатается на месте, в порядке манифеста; живой
                # области в этот момент нет — предыдущий пакет уже зафиксирован
                if [[ $tty_render -eq 1 ]]; then
                    printf '\033[32m  [%d/%d] %s@%s — уже установлен\033[0m\n' \
                        "$idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
                else
                    printf '  [%d/%d] %s@%s — уже установлен\n' \
                        "$idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
                fi
                continue
            fi
            cur=$((cur + 1))
            have="$(get_installed_ext_version "$nm" "$EXT_NAME")"
            START_TS="$(date +%s)"
            if [[ -n "$have" ]]; then
                printf '%s' "[$idx/$total] $EXT_NAME@$EXT_VER (обновляю, было $have)" >"$statusfile"
            else
                printf '%s' "[$idx/$total] $EXT_NAME@$EXT_VER" >"$statusfile"
            fi
            printf '%s' "$START_TS" >"$startfile"
            : >"$winfile"
            if [[ $tty_render -eq 1 ]]; then
                : >"$running"
                _ext_timer_loop "$running" "$statusfile" "$startfile" "$winfile" &
                tpid=$!
            else
                printf '  pi install %s\n' "$entry" >&2
            fi
            # if-обёртка гасит errexit/pipefail от docker-провала. Читатель НЕ
            # рисует — только пишет в full.log и в окно; рисует один таймер.
            # Атомарность дописывания: одиночный printf со встроенными \n.
            if docker run --rm \
                -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
                -v "$env_dir:/home/pi" \
                "$IMAGE_NAME" pi install "$entry" 2>&1 | while IFS= read -r line; do
                printf '%s\n' "$line" >>"$fulllog"
                _ext_strip_ansi <<<"$line" | sed 's/^/  │ /' >>"$winfile"
            done; then
                installed=$((installed + 1))
                ok_color=32
                ok_line="✓ $EXT_NAME@$EXT_VER"
            else
                failed=$((failed + 1))
                ok_color=31
                ok_line="✗ $EXT_NAME@$EXT_VER — ошибка (полный лог: $fulllog)"
                if [[ $tty_render -ne 1 ]]; then
                    warn "не удалось установить: $entry (продолжаю остальными)"
                fi
            fi
            now="$(date +%s)"
            elapsed=$((now - START_TS))
            ok_line="$ok_line (${elapsed}s)"
            if [[ $tty_render -eq 1 ]]; then
                rm -f "$running"
                wait "$tpid" 2>/dev/null || true
                # стереть живую область, затем ✓/✗ фиксируется навсегда;
                # следующий пункт добавится строкой ниже
                _ext_commit "$ok_line" "$ok_color" >&2
            else
                printf '  %s\n' "$ok_line" >&2
            fi
        done
        if [[ $tty_render -eq 1 ]]; then
            _ext_show_cursor
            trap - INT TERM
        fi
        if [[ $failed -gt 0 && $tty_render -eq 1 ]]; then
            # живая область уже стёрта в _ext_commit; курсор ниже ✓-строк
            printf '\033[90m── последние строки журнала ──\033[0m\n' >&2
            tail -n 20 "$fulllog" | _ext_strip_ansi >&2
        fi
        rm -rf "$tmpdir"
    fi

    # settings.json: добавляем только отсутствующие записи (порядок сохраняем).
    local settings="$env_dir/.pi/agent/settings.json"
    mkdir -p "$(dirname "$settings")"
    [[ -f "$settings" ]] || printf '{"packages":[]}\n' >"$settings"
    load_settings_packages "$settings"
    local -a missing=()
    local want known
    for want in ${need_settings[@]+"${need_settings[@]}"}; do
        parse_ext_entry "$want" || continue
        # в settings.json источник без версии (pi хранит "npm:имя")
        local short="npm:$EXT_NAME"
        known=""
        local sp
        for sp in ${EXT_SETTINGS_PACKAGES[@]+"${EXT_SETTINGS_PACKAGES[@]}"}; do
            if [[ "$sp" == "$short" || "$sp" == "$want" ]]; then
                known=1
                break
            fi
        done
        [[ -n "$known" ]] || missing+=("$short")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        mkdir -p "$(dirname "$settings")"
        local m
        for m in ${missing[@]+"${missing[@]}"}; do
            if jq --arg p "$m" '.packages = ((.packages // []) + [$p] | unique)' "$settings" >"$settings.tmp" &&
                mv "$settings.tmp" "$settings"; then
                :
            else
                rm -f "$settings.tmp"
                warn "не удалось дополнить settings.json ($m) — добавьте вручную: \"packages\" += \"$m\""
                failed=$((failed + 1))
            fi
        done
    fi

    printf '\n' >&2
    log "Готово: новых: $installed, уже стояли: $skipped, проблем: $failed"
    if [[ $failed -gt 0 ]]; then
        die "есть ошибки установки — повторите: pibox extensions install -e $env_name"
    fi
    log "Расширения подключатся при следующем запуске pi в окружении '$env_name'"
}

# Обновление установки (заглушка)
cmd_update() {
    log "Обновление pibox..."
    warn "Команда update ещё не реализована (см. задачу 7)"
}

# Диагностика окружения: docker, образ, каркас env, дубли расширений, кэш,
# сверка расширений с манифестом.
#
# Всё делается на хосте: env-каталог — это bind-mount, его файлы видны напрямую,
# а arch хоста = arch контейнера, libc контейнера всегда glibc (Ubuntu-образ).
# Поэтому правило «что мёртвое» выводится статически:
#   рабочий вариант  — linux-<arch хоста>-gnu
#   мусор            — *-musl, *-darwin*, *-win32*, linux-<чужая arch>-*
# Мусорный платформенный пакет удаляется (--fix) только при живом gnu-твине;
# без твина пакет сообщается как подозрительный и не трогается.
#
# Коды выхода: 0 — ошибок нет (предупреждения допустимы), 1 — есть ошибки.
cmd_doctor() {
    local env_name="$DEFAULT_ENV"
    local fix="0"

    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            env_name="$2"
            shift 2
            ;;
        --fix)
            fix="1"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестная опция для doctor: $1"
            usage
            exit 1
            ;;
        esac
    done

    validate_env_name "$env_name"

    local errors=0 warnings=0
    d_ok() { printf '  [OK]   %s\n' "$*"; }
    d_info() { printf '  [..]   %s\n' "$*"; }
    d_warn() {
        printf '  [WARN] %s\n' "$*"
        warnings=$((warnings + 1))
    }
    d_err() {
        printf '  [FAIL] %s\n' "$*"
        errors=$((errors + 1))
    }

    # KB -> человекочитаемый размер
    human_kb() {
        if [[ "$1" -ge 1024 ]]; then printf '%d МБ' "$(($1 / 1024))"; else printf '%d КБ' "$1"; fi
    }

    local doctor_mode="окружение: $env_name"
    [[ "$fix" == "1" ]] && doctor_mode="$doctor_mode, режим --fix"
    log "Диагностика pibox ($doctor_mode)..."

    # D1: docker
    local server_version
    server_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    if [[ -z "$server_version" ]]; then
        d_err "docker не найден или daemon не отвечает"
        printf '\nПродолжение диагностики невозможно без docker.\n'
        return 1
    fi
    d_ok "docker ${server_version}"

    # D2: образ
    local image_ok=0
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        d_ok "образ ${IMAGE_NAME} найден"
    else
        image_ok=1
        d_err "образ ${IMAGE_NAME} не найден — соберите: pibox build"
    fi

    # D3: состав образа — pi на месте, тяжёлые тулчейны не протекли.
    # Важно: /home/pi — персистентный bind-mount, туда пользователь осознанно
    # ставит тулчейны через mise; они НЕ часть образа. Поэтому ищем только
    # то, что реально лежит в образе: резолвим путь бинарника и игнорируем /home.
    if [[ "$image_ok" == "0" ]]; then
        if docker run --rm "$IMAGE_NAME" bash -c \
            'command -v pi >/dev/null 2>&1 || exit 1; for t in gcc gdb rustc cargo cmake valgrind strace tcpdump; do p="$(command -v "$t" 2>/dev/null)" || continue; case "$(readlink -f "$p")" in /home/*) continue ;; esac; exit 1; done' \
            >/dev/null 2>&1; then
            d_ok "образ: pi на месте, тяжёлых тулчейнов нет"
        else
            d_warn "в образе протек тулчейн или пропал pi — пересоберите: pibox build --no-cache"
        fi
    fi

    # D4: окружение
    local env_ok=0
    local env_dir="$PIBOX_DIR/env/$env_name"
    if [[ -d "$env_dir" ]]; then
        d_ok "окружение '$env_name': $env_dir"
    else
        env_ok=1
        local available="" ed
        for ed in "$PIBOX_DIR/env"/*; do
            [[ -d "$ed" ]] || continue
            available+="$(basename "$ed") "
        done
        d_err "окружение '$env_name' не найдено — создастся автоматически при 'pibox run -e $env_name'"
        d_info "доступные окружения: ${available:-()пусто)}"
    fi

    # D5: каркас окружения — то, что есть в источниках, должно быть и в окружении.
    # Источник зависит от файла: models.json живёт в корне репо (в шаблон не
    # копируется, раскладывается по окружениям при первом запуске), остальное —
    # в env/.template.
    local template_dir="$PIBOX_DIR/env/.template"
    if [[ "$env_ok" == "0" ]]; then
        if [[ -d "$template_dir" ]]; then
            local rel src e_path
            for rel in .pi/agent/AGENTS.md .pi/agent/models.json .pi/agent/skills; do
                if [[ "$rel" == ".pi/agent/models.json" ]]; then
                    src="$PIBOX_DIR/models.json"
                else
                    src="$template_dir/$rel"
                fi
                e_path="$env_dir/$rel"
                [[ -e "$src" ]] || continue
                if [[ -e "$e_path" ]]; then
                    d_ok "$rel"
                elif [[ "$fix" == "1" ]]; then
                    mkdir -p "$(dirname "$e_path")"
                    if cp -a "$src" "$e_path"; then
                        d_ok "$rel — восстановлен (--fix)"
                    else
                        d_err "$rel — не удалось восстановить"
                    fi
                else
                    d_err "$rel отсутствует — восстановление: pibox doctor -e $env_name --fix"
                fi
            done
        else
            d_err "шаблон окружения не найден: $template_dir — переустановите pibox: install.sh"
        fi
    fi

    # D6: платформенные дубли расширений (статический аудит)
    local nm="$env_dir/.pi/agent/npm/node_modules"
    if [[ -d "$nm" ]]; then
        local host_arch good_arch junk_arch1 junk_arch2
        host_arch="$(uname -m)"
        case "$host_arch" in
        x86_64 | amd64)
            good_arch="x64"
            junk_arch1="arm64"
            junk_arch2="aarch64"
            ;;
        aarch64 | arm64)
            good_arch="arm64"
            junk_arch1="x64"
            junk_arch2="x86"
            ;;
        *)
            good_arch=""
            junk_arch1=""
            junk_arch2=""
            ;;
        esac
        local -a junk_patterns=(-name '*-musl' -o -name '*-darwin*' -o -name '*-win32*')
        if [[ -n "$junk_arch1" ]]; then
            junk_patterns+=("-o" "-name" "*-linux-${junk_arch1}*" "-o" "-name" "*-linux-${junk_arch2}*")
        fi

        local junk_dirs=()
        local d
        while IFS= read -r d; do
            junk_dirs+=("$d")
        done < <(find "$nm" -maxdepth 6 -type d \( "${junk_patterns[@]}" \) 2>/dev/null)

        local junk_total_kb=0
        local rel_twin d_kb size
        if [[ ${#junk_dirs[@]} -eq 0 ]]; then
            d_ok "расширения: платформенных дублей нет"
        else
            for d in ${junk_dirs[@]+"${junk_dirs[@]}"}; do
                # твин: рабочий вариант того же пакета
                case "$d" in
                *-musl) rel_twin="${d%-musl}-gnu" ;;
                *-linux-x64*) rel_twin="${d/-linux-x64/-linux-arm64}" ;;
                *-linux-x86*) rel_twin="${d/-linux-x86/-linux-arm64}" ;;
                *-linux-arm64*) rel_twin="${d/-linux-arm64/-linux-x64}" ;;
                *-linux-aarch64*) rel_twin="${d/-linux-aarch64/-linux-x64}" ;;
                *) rel_twin="" ;; # darwin/win32 мертвы на linux всегда
                esac
                d_kb="$(du -sk "$d" 2>/dev/null | cut -f1)"
                d_kb="${d_kb:-0}"
                size="$(human_kb "$d_kb")"
                if [[ -z "$rel_twin" || -d "$rel_twin" ]]; then
                    junk_total_kb=$((junk_total_kb + d_kb))
                    if [[ "$fix" == "1" ]]; then
                        if rm -rf "$d"; then
                            d_ok "дубль удалён (--fix): ${d#"$nm"/} ($size)"
                        else
                            d_err "не удалось удалить дубль: $d"
                        fi
                    else
                        d_warn "дубль: ${d#"$nm"/} ($size) — чистка: pibox doctor -e $env_name --fix"
                    fi
                else
                    d_warn "платформенный пакет без рабочего твина (не удаляю, разберитесь вручную): ${d#"$nm"/}"
                fi
            done
        fi

        # Известный случай: x64-артефакты внутри основного пакета @llamaindex/liteparse
        # при установленном платформенном пакете (файлы .node/.so чужой архитектуры).
        if [[ -n "$good_arch" ]] && command -v file >/dev/null 2>&1 &&
            [[ -d "$nm/@llamaindex/liteparse" ]] &&
            [[ -d "$nm/@llamaindex/liteparse-linux-$good_arch-gnu" ]]; then
            local f farch dead fk
            while IFS= read -r f; do
                farch="$(file -b "$f" 2>/dev/null || true)"
                dead=0
                case "$farch" in
                *x86-64*) [[ "$good_arch" != "arm64" ]] || dead=1 ;;
                *aarch64* | *ARM*) [[ "$good_arch" != "x64" ]] || dead=1 ;;
                *) continue ;; # не ELF или не определился — не трогаем
                esac
                [[ "$dead" == "1" ]] || continue
                fk="$(du -sk "$f" 2>/dev/null | cut -f1)"
                fk="${fk:-0}"
                junk_total_kb=$((junk_total_kb + fk))
                if [[ "$fix" == "1" ]]; then
                    if rm -f "$f"; then
                        d_ok "чужой-arch артефакт удалён (--fix): ${f#"$nm"/} ($(human_kb "$fk"))"
                    else
                        d_err "не удалось удалить: $f"
                    fi
                else
                    d_warn "чужой-arch артефакт: ${f#"$nm"/} ($(human_kb "$fk")) — чистка: pibox doctor -e $env_name --fix"
                fi
            done < <(find "$nm/@llamaindex/liteparse" -maxdepth 1 -type f \( -name '*.node' -o -name '*.so' \) 2>/dev/null)
        fi

        if [[ "$junk_total_kb" -gt 0 ]]; then
            d_info "итого мусора в расширениях: $(human_kb "$junk_total_kb")"
        fi
    else
        d_info "расширения не установлены ($nm отсутствует)"
    fi

    # D7: npm-кэш (персистентен в env, раздувается — см. PROJECT.md)
    local cache_dir="$env_dir/.npm/_cacache"
    if [[ -d "$cache_dir" ]]; then
        local ck
        ck="$(du -sk "$cache_dir" 2>/dev/null | cut -f1)"
        ck="${ck:-0}"
        local cname="pibox-$env_name"
        if [[ "$ck" -ge $((300 * 1024)) ]]; then
            if [[ "$fix" == "1" ]] &&
                docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname" &&
                docker exec "$cname" npm cache clean --force >/dev/null 2>&1; then
                d_ok "npm-кэш очищен в контейнере ($cname)"
            else
                d_warn "npm-кэш раздут: ~$(human_kb "$ck") — чистка (при запущенном контейнере): docker exec $cname npm cache clean --force"
            fi
        else
            d_ok "npm-кэш: ~$(human_kb "$ck")"
        fi
    fi

    # D8: контейнер окружения
    local cname="pibox-$env_name"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        d_ok "контейнер $cname запущен"
    else
        d_info "контейнер $cname не запущен (это нормально; запуск: pibox run -e $env_name)"
    fi

    # D9: расширения — сверка окружения с манифестом env/extensions.txt
    # (нужен jq; без него проверка пропускается). Три вида расхождений:
    #   отсутствует пакет (WARN)  — установка: pibox extensions install
    #   версия не совпадает (WARN) — обновление той же командой
    #   пакет вне манифеста (INFO) — установлен вручную, pibox его не трогает
    # Расхождения с манифестом — не ошибки: свежее окружение без расширений —
    # нормальное состояние (doctor не должен падать с кодом 1).
    if ! command -v jq >/dev/null 2>&1; then
        d_info "jq не найден — сверка расширений с манифестом пропущена"
    else
        load_extensions_manifest
        if [[ ${#EXT_ENTRIES[@]} -eq 0 ]]; then
            d_info "манифест расширений пуст или отсутствует: $EXTENSIONS_FILE"
        elif [[ "$env_ok" == "1" ]]; then
            : # окружения нет — D4 уже сообщил, сверять не с чем
        else
            local m_entry m_have m_tot=0 m_miss=0 m_drift=0 manifest_err=0
            local -a manifest_names=() manifest_vers=()
            for m_entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
                if parse_ext_entry "$m_entry"; then
                    manifest_names+=("$EXT_NAME")
                    manifest_vers+=("$EXT_VER")
                else
                    d_err "манифест: не удалось разобрать запись: $m_entry"
                    manifest_err=1
                fi
            done
            if [[ "$manifest_err" == "0" ]]; then
                local nm9="$env_dir/.pi/agent/npm/node_modules" i9 count9=${#manifest_names[@]}
                # установки pi добавляют запись и в settings.json; но пакет
                # может быть осознанно установлен без загрузки (напр. конфликт
                # memory-расширений — см. шапку манифеста), поэтому settings
                # проверяем только для пакетов, отсутствующих в node_modules:
                # их нет нигде — чинится одной командой extensions install.
                load_settings_packages "$env_dir/.pi/agent/settings.json"
                local -a set_missing=()
                for ((i9 = 0; i9 < count9; i9++)); do
                    m_tot=$((m_tot + 1))
                    m_have="$(get_installed_ext_version "$nm9" "${manifest_names[$i9]}")"
                    if [[ -z "$m_have" ]]; then
                        m_miss=$((m_miss + 1))
                        local short9="npm:${manifest_names[$i9]}" found9=0 sp9
                        for sp9 in ${EXT_SETTINGS_PACKAGES[@]+"${EXT_SETTINGS_PACKAGES[@]}"}; do
                            [[ "$sp9" == "$short9" || "$sp9" == "npm:${manifest_names[$i9]}@${manifest_vers[$i9]}" ]] && found9=1 && break
                        done
                        [[ "$found9" == "1" ]] || set_missing+=("$short9")
                    elif [[ "$m_have" != "${manifest_vers[$i9]}" ]]; then
                        m_drift=$((m_drift + 1))
                        d_warn "версия не совпадает: ${manifest_names[$i9]} — установлено ${m_have:-нет}, в манифесте ${manifest_vers[$i9]}"
                    fi
                done
                if [[ "$m_miss" -gt 0 ]]; then
                    d_warn "расширения: отсутствуют $m_miss из $m_tot (манифест $EXTENSIONS_FILE) — установка: pibox extensions install -e $env_name"
                elif [[ "$m_drift" -eq 0 ]]; then
                    d_ok "расширения: все $m_tot из манифеста установлены"
                else
                    d_warn "расширения: версии расходятся с манифестом в $m_drift пакетах — обновление: pibox extensions install -e $env_name"
                fi

                # Замыкание зависимостей: рекурсивно собираем deps (+optionalDeps)
                # всех пакетов из манифеста по установленным package.json.
                # needed_req — обязательные deps (их отсутствие = сломанная установка),
                # needed_any — включая optional (не обязаны быть на диске, но
                # не дают считать сам пакет «лишним»).
                local -A pkg_deps=() pkg_opt=() # имя -> "dep1 dep2 ..."
                local pj9 rd9
                while IFS= read -r pj9; do
                    rd9="${pj9#"$nm9"/}"
                    rd9="${rd9%/package.json}"
                    pkg_deps["$rd9"]="$(jq -r '[.dependencies // {} | keys[]] | join(" ")' "$pj9" 2>/dev/null)"
                    pkg_opt["$rd9"]="$(jq -r '[.optionalDependencies // {} | keys[]] | join(" ")' "$pj9" 2>/dev/null)"
                done < <(find "$nm9" -mindepth 2 -maxdepth 3 -name package.json 2>/dev/null)

                local -A needed_req=() seen9=()
                local -a queue9=()
                local q9 dep9
                for m9 in ${manifest_names[@]+"${manifest_names[@]}"}; do queue9+=("$m9"); done
                while [[ ${#queue9[@]} -gt 0 ]]; do
                    q9="${queue9[-1]}"
                    queue9=("${queue9[@]:1}")
                    [[ -n "${seen9[$q9]+x}" ]] && continue
                    seen9["$q9"]=1
                    for dep9 in ${pkg_deps["$q9"]:-} ${pkg_opt["$q9"]:-}; do
                        [[ -z "$dep9" ]] && continue
                        [[ -n "${seen9[$dep9]+x}" ]] || queue9+=("$dep9")
                    done
                    for dep9 in ${pkg_deps["$q9"]:-}; do
                        [[ -z "$dep9" ]] && continue
                        needed_req["$dep9"]=1
                    done
                done

                # Сверка: установленное вне замыкания — «лишнее» (ручная
                # установка); обязательная зависимость, которой нет на диске —
                # сломанная установка.
                local -a extra_pkgs=() dep_missing=()
                for rd9 in "${!pkg_deps[@]}"; do
                    [[ -z "${seen9[$rd9]+x}" ]] && extra_pkgs+=("$rd9")
                done
                for rd9 in "${!needed_req[@]}"; do
                    [[ ! -f "$nm9/$rd9/package.json" ]] && dep_missing+=("$rd9")
                done
                if [[ ${#extra_pkgs[@]} -gt 0 ]]; then
                    d_info "вне манифеста и не зависимости (${#extra_pkgs[@]}): ${extra_pkgs[*]}"
                fi
                if [[ ${#dep_missing[@]} -gt 0 ]]; then
                    d_warn "сломанные зависимости (${#dep_missing[@]}): ${dep_missing[*]} — переустановка: pibox extensions install -e $env_name"
                fi

                # отсутствующие в node_modules и в settings.json (см. выше)
                if [[ ${#set_missing[@]} -gt 0 ]]; then
                    d_warn "в settings.json нет ${#set_missing[@]} пакетов (${set_missing[*]}) — чинит pibox extensions install -e $env_name"
                fi
            fi
        fi
    fi

    # Итог
    printf '\n'
    if [[ "$errors" -eq 0 && "$warnings" -eq 0 ]]; then
        printf 'Итог: всё в порядке\n'
    else
        printf 'Итог: ошибок: %d, предупреждений: %d\n' "$errors" "$warnings"
    fi
    [[ "$errors" -eq 0 ]]
}

# --- Основной блок --------------------------------------------------------------

main() {
    # Если первый аргумент не опция, то это подкоманда
    local SUBCOMMAND
    if [[ $# -gt 0 && "$1" != -* ]]; then
        SUBCOMMAND="$1"
        shift
    else
        SUBCOMMAND="run"
    fi

    # Вызов соответствующей подкоманды
    case "$SUBCOMMAND" in
    run)
        cmd_run "$@"
        ;;
    build)
        cmd_build "$@"
        ;;
    env)
        cmd_env "$@"
        ;;
    shell)
        cmd_shell "$@"
        ;;
    update)
        cmd_update "$@"
        ;;
    doctor)
        cmd_doctor "$@"
        ;;
    extensions)
        cmd_extensions "$@"
        ;;
    *)
        err "Неизвестная подкоманда: $SUBCOMMAND"
        usage
        exit 1
        ;;
    esac
}

# Точка входа
trap : INT # SIGINT не должен убивать скрипт до выполнения локальных ловушек
main "$@"
