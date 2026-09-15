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
IMAGE_NAME="pibox:latest"

# Определяем PIBOX_DIR относительно расположения скрипта.
# Если скрипт лежит в каталоге bin — поднимаемся на уровень выше,
# иначе берём директорию скрипта. Имя скрипта не важно.
_src="${BASH_SOURCE[0]}"
_script_dir="$(cd -- "$(dirname -- "$_src")" && pwd)"
_pibox_default="$_script_dir"
[[ "$(basename -- "$_script_dir")" == "bin" ]] && _pibox_default="$(dirname -- "$_script_dir")"
PIBOX_DIR="${PIBOX_DIR:-$_pibox_default}"

# --- Хелперы -------------------------------------------------------------------

err() { echo "pibox: error: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
log() { echo "==> pibox: $*" >&2; }
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
    local ws="$(pwd)"
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

    log "Запуск оболочки в окружении '$env_name'..."
    docker run --rm -it \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v "$PIBOX_DIR/env/$env_name:/home/pi" \
        -v "$(pwd):/home/pi/workspace" \
        "$IMAGE_NAME" bash
}

# Обновление установки (заглушка)
cmd_update() {
    log "Обновление pibox..."
    warn "Команда update ещё не реализована (см. задачу 7)"
}

# Диагностика окружения: docker, образ, каркас env, дубли расширений, кэш.
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

    # D3: состав образа — pi на месте, тяжёлые тулчейны не протекли
    if [[ "$image_ok" == "0" ]]; then
        if docker run --rm "$IMAGE_NAME" bash -c \
            'command -v pi >/dev/null 2>&1 || exit 1; for t in gcc gdb rustc cargo cmake valgrind strace tcpdump; do command -v "$t" >/dev/null 2>&1 && exit 1; done' \
            >/dev/null 2>&1; then
            d_ok "образ: pi на месте, тяжёлых тулчейнов нет"
        else
            d_warn "образ не прошёл проверку состава (pi/тулчейны) — пересоберите: pibox build --no-cache"
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
    *)
        err "Неизвестная подкоманда: $SUBCOMMAND"
        usage
        exit 1
        ;;
    esac
}

# Точка входа
main "$@"
