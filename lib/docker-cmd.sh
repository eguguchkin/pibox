# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
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
    # Проект — в подкаталог по имени каталога (workspace_path из common.sh),
    # рабочий каталог контейнера — туда же (перекрывает WORKDIR из Dockerfile)
    local ws_path
    ws_path="$(workspace_path)"
    RUN_CMD+=("-v" "$(pwd):${ws_path}")
    RUN_CMD+=("-w" "$ws_path")
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
