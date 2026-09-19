# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
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

    # Точка монтирования проекта (подкаталог по имени): тоже создаём заранее,
    # иначе docker сделает /home/pi/workspace/<имя> от root внутри env-маунта.
    mkdir -p "$PIBOX_DIR/env/$ENV_NAME/workspace/$(workspace_name)"

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
