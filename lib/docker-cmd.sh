# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Сборка команды docker run --------------------------------------------------

# Глобальный массив, в который собирается готовая команда docker run.
RUN_CMD=()

# Глобальный флаг режима `pibox webui` (1 = включён) и параметры порта.
# Двусторонний контракт с lib/cmd-webui.sh: ТАМ cmd_webui выставляет эти
# переменные ДО вызова launch_container; ЗДЕСЬ (build_docker_run_cmd) по ним
# добавляется проброс webui-порта, -e PI_WEB_PORT/WEBUI_HOST_PORT для
# лаунчера внутри контейнера (см. его контракт в docker/webui.sh) и команда
# контейнера «webui». Переименуешь переменную в одном из двух файлов —
# вторая молча увидит пустую и запустит обычный TUI без порта.
WEBUI_MODE=0
WEBUI_PORT=8787
WEBUI_HOST_PORT=""

# Заполняет RUN_CMD аргументами для docker run.
# Переменные берутся динамически: функция вызывается из launch_container
# (cmd-run.sh), а bash даёт ей видеть локальные переменные вызывающей
# функции (динамическая область видимости): ENV_NAME, CONTAINER_NAME,
# MEMORY, CPUS, PIDS_LIMIT, GIT_SAFE, ENV_FILE, массивы PUBLISH_OPTS,
# PASS_ENV_OPTS, PI_ARGS; глобальные IMAGE_NAME, WEBUI_MODE/PORT/HOST_PORT.
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

    # Переменные окружения для entrypoint.sh: он подставляет UID/GID
    # хост-пользователя и включает git safe.directory по флагу
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

    # Режим pibox webui: сервер внутри слушает PI_WEB_PORT (лаунчер webui.sh);
    # WEBUI_HOST_PORT — для зелёной ссылки. Авто -p добавляем, только если
    # юзер не пробросил свой маппинг на контейнерный порт webui.
    if [[ "$WEBUI_MODE" == "1" ]]; then
        local hp="${WEBUI_HOST_PORT:-$WEBUI_PORT}"
        local mapped=""
        for opt in ${PUBLISH_OPTS[@]+"${PUBLISH_OPTS[@]}"}; do
            # формат [host_ip:]host_port:container_port[/proto] или bare-порт
            local cport="${opt##*:}"
            cport="${cport%/*}"
            [[ "$cport" == "$WEBUI_PORT" ]] && mapped=1
        done
        [[ -n "$mapped" ]] || RUN_CMD+=("-p" "${hp}:${WEBUI_PORT}")
        RUN_CMD+=("-e" "PI_WEB_PORT=${WEBUI_PORT}")
        RUN_CMD+=("-e" "WEBUI_HOST_PORT=${hp}")
        # -it добавлен ниже по TTY-проверке: логи сервера и агента идут в этот
        # же терминал; Ctrl+C останавливает контейнер.
    fi

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

    if [[ "$WEBUI_MODE" == "1" ]]; then
        # Лаунчер вместо дефолтного pi: зелёная ссылка + exec pi-web-ui
        RUN_CMD+=("webui")
    else
        # Аргументы pi (после --)
        for opt in ${PI_ARGS[@]+"${PI_ARGS[@]}"}; do
            RUN_CMD+=("$opt")
        done
    fi
}

# Печатает команду в shell-escape виде (для --dry-run)
print_run_cmd() {
    local a
    printf 'DRY RUN:'
    for a in ${RUN_CMD[@]+"${RUN_CMD[@]}"}; do
        printf ' %q' "$a"
    done
    printf '\n'
    # webui: показать ссылку, которую лаунчер напечатает в контейнере
    if [[ "${WEBUI_MODE:-0}" == "1" ]]; then
        printf 'DRY RUN: лаунчер напечатает ссылку: http://localhost:%s\n' \
            "${WEBUI_HOST_PORT:-$WEBUI_PORT}"
    fi
}
