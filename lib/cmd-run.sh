# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Подкоманды -----------------------------------------------------------------

# Основная команда: запуск pi в контейнере
cmd_run() {
    local -a PI_ARGS=()
    local -a PUBLISH_OPTS=()
    local -a PASS_ENV_OPTS=()
    local -a COMMON_TAIL=()

    local ENV_NAME=""
    local CONTAINER_NAME=""
    local ENV_FILE=""
    local MEMORY=""
    local CPUS=""
    local PIDS_LIMIT=""
    local GIT_SAFE=""
    local DRY_RUN="0"
    local KEEP="0"
    # Режимы webui/tg: run = обычный TUI. launch_container и build_docker_run_cmd
    # читают эти локальные через динамическую область видимости (docker-cmd.sh).
    local WEBUI_MODE=0
    local WEBUI_PORT=8787
    local WEBUI_HOST_PORT=""
    local TG_MODE=0

    if ! parse_common_run_opts run "$@"; then
        # `--`: хвост (включая флаги) уходит в pi
        PI_ARGS=(${COMMON_TAIL[@]+"${COMMON_TAIL[@]}"})
    fi

    launch_container
}

# Общий разбор опций run и webui (общий поднабор).
# Заполняет локальные вызывающей функции через динамическую область
# видимости (тот же контракт, что у launch_container): ENV_NAME,
# CONTAINER_NAME, ENV_FILE, MEMORY, CPUS, PIDS_LIMIT, GIT_SAFE, DRY_RUN,
# KEEP, PUBLISH_OPTS, PASS_ENV_OPTS, COMMON_TAIL; для webui — ещё PORT.
# $1 — имя подкоманды для сообщений об ошибках (run|webui); --port валиден
# только для webui, в run это «неизвестная опция».
# Возврат: 0 = разобрано до конца; 1 = встретилось `--`, хвост (включая
# флаги) — в COMMON_TAIL.
parse_common_run_opts() {
    local context="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --)
            shift
            COMMON_TAIL=("$@")
            return 1
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
        --name)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --port)
            if [[ "$context" != "webui" ]]; then
                err "Неизвестная опция или аргумент для $context: $1"
                usage
                exit 1
            fi
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            PORT="$2"
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
        -h | --help)
            usage
            exit 0
            ;;
        -V | --version)
            version
            exit 0
            ;;
        *)
            err "Неизвестная опция или аргумент для $context: $1"
            usage
            exit 1
            ;;
        esac
    done
    return 0
}

# Общее ядро запуска контейнера: cmd_run и cmd_webui (lib/cmd-webui.sh).
# Видит локальные переменные вызывающей функции (динамическая область
# видимости bash): ENV_NAME, CONTAINER_NAME, ENV_FILE, MEMORY, CPUS,
# PIDS_LIMIT, GIT_SAFE, DRY_RUN, KEEP, PI_ARGS, PUBLISH_OPTS, PASS_ENV_OPTS,
# а также WEBUI_MODE/WEBUI_PORT/WEBUI_HOST_PORT — локальные точки входа
# (cmd_run / cmd_webui); 1 = режим pibox webui.
launch_container() {
    # Дефолты
    ENV_NAME="${ENV_NAME:-$DEFAULT_ENV}"
    if [[ -z "$CONTAINER_NAME" ]]; then
        CONTAINER_NAME="pibox-${ENV_NAME}"
        # webui/tg — в отдельных контейнерах: иначе `pibox webui`/`pibox tg`
        # при запущенном TUI-экземпляре делает docker rm -f и убивает его
        # (exit 137). pi рассчитан на параллельные сессии (общий
        # ~/.pi/agent/sessions).
        [[ "${WEBUI_MODE:-0}" == "1" ]] && CONTAINER_NAME+="-webui"
        [[ "${TG_MODE:-0}" == "1" ]] && CONTAINER_NAME+="-tg"
    fi

    # Проверки
    check_docker
    validate_env_name "$ENV_NAME"
    check_workspace_isolation

    # Автосоздание окружения + слои (common при создании, user — всегда)
    create_env "$ENV_NAME"

    # Проверка образа (не собираем в dry-run)
    if [[ "$DRY_RUN" != "1" ]]; then
        if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
            warn "Образ $IMAGE_NAME не найден — запускаю сборку (pibox build)..."
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

    # Фантомные пустые точки монтирования от прошлых проектов — до запуска.
    cleanup_workspace_mounts "$ENV_NAME"

    # Точка монтирования проекта (подкаталог по имени): тоже создаём заранее,
    # иначе docker сделает /home/pi/workspace/<имя> от root внутри env-маунта.
    mkdir -p "$PIBOX_DIR/env/$ENV_NAME/workspace/$(workspace_name)"

    if [[ "${WEBUI_MODE:-0}" == "1" ]]; then
        log "Запуск web-ui (pi-web-ui) в окружении '$ENV_NAME' (контейнер: $CONTAINER_NAME)..."
    elif [[ "${TG_MODE:-0}" == "1" ]]; then
        log "Запуск Telegram-моста в окружении '$ENV_NAME' (контейнер: $CONTAINER_NAME)..."
    else
        log "Запуск pi в окружении '$ENV_NAME' (контейнер: $CONTAINER_NAME)..."
    fi

    # Запуск. Ловим код возврата вручную, чтобы set -e не убил скрипт
    # до обработки cleanup-логики.
    local rc=0
    "${RUN_CMD[@]}" || rc=$?
    # Постобработка: при успехе и без --keep удаляем контейнер.
    # В webui/tg-режимах Ctrl+C (SIGINT→130 / SIGTERM→143) — ШТАТНАЯ остановка
    # сервера/моста, а не сбой: чистим тихо, без «оставлен для отладки».
    local interrupted=0
    if [[ ("${WEBUI_MODE:-0}" == "1" || "${TG_MODE:-0}" == "1") && ($rc -eq 130 || $rc -eq 143) ]]; then
        interrupted=1
    fi
    if [[ ($rc -eq 0 || $interrupted -eq 1) && "$KEEP" != "1" ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        # Свежая пустая точка монтирования этого проекта — тоже в мусор
        # (проект на хосте никуда не делся, каталог пересоздастся при нужде).
        cleanup_workspace_mounts "$ENV_NAME"
        if [[ $interrupted -eq 1 ]]; then
            if [[ "${TG_MODE:-0}" == "1" ]]; then
                log "Telegram-мост остановлен (Ctrl+C), контейнер '$CONTAINER_NAME' удалён"
            else
                log "web-ui остановлен (Ctrl+C), контейнер '$CONTAINER_NAME' удалён"
            fi
        else
            log "Контейнер '$CONTAINER_NAME' удалён"
        fi
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

    # Хинт о дрейфе слоёв: если агент что-то поменял в файлах слоя 2 —
    # подсказать, как забрать это в template/user (обратная синхронизация).
    layers_drift "$ENV_NAME"
    if [[ ${#LAYER_DRIFT_PATHS[@]} -gt 0 ]]; then
        local drift_list="${LAYER_DRIFT_PATHS[*]}"
        [[ ${#LAYER_DRIFT_PATHS[@]} -gt 3 ]] && drift_list="${LAYER_DRIFT_PATHS[0]}, ${LAYER_DRIFT_PATHS[1]}, … (всего ${#LAYER_DRIFT_PATHS[@]})"
        log "Изменено в env относительно template/user: $drift_list"
        log "Сохранить в свой слой: pibox user pull -e $ENV_NAME"
    fi

    return "${rc:-0}"
}
