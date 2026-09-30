# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Сборка команды docker run --------------------------------------------------

# Глобальный массив, в который собирается готовая команда docker run.
RUN_CMD=()

# Режимы webui и tg (WEBUI_MODE/WEBUI_PORT/WEBUI_HOST_PORT, TG_MODE) — НЕ
# глобальные переменные. Каждый вход (cmd_run, cmd_webui, cmd-tg) объявляет
# их локально, а launch_container и build_docker_run_cmd видят их через
# динамическую область видимости — тот же контракт, что для ENV_NAME/
# MEMORY/PI_ARGS. cmd_run объявляет WEBUI_MODE=0, TG_MODE=0 (обычный TUI);
# cmd_webui — WEBUI_MODE=1 и порты; cmd-tg — TG_MODE=1. Состояние не
# остаётся между вызовами. По этим переменным здесь добавляется проброс
# webui-порта, -e PI_WEB_PORT/WEBUI_HOST_PORT для лаунчера внутри контейнера
# (см. его контракт в docker/webui.sh) или команда контейнера «webui» /
# «pi-telegram-bridge run».

# Заполняет RUN_CMD аргументами для docker run.
# Переменные берутся динамически: функция вызывается из launch_container
# (cmd-run.sh), а bash даёт ей видеть локальные переменные вызывающей
# функции (динамическая область видимости): ENV_NAME, CONTAINER_NAME,
# MEMORY, CPUS, PIDS_LIMIT, GIT_SAFE, ENV_FILE, массивы PUBLISH_OPTS,
# PASS_ENV_OPTS, PI_ARGS; WEBUI_MODE/PORT/HOST_PORT — локальные точки входа
# (cmd_run/cmd_webui); глобальный IMAGE_NAME.
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
    if [[ "${WEBUI_MODE:-0}" == "1" ]]; then
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

    # tg: SOCKS5-прокси для Telegram (хост-переменная → контейнер).
    # llblab ходит в Telegram мимо HTTP(S)_PROXY (сырой https.request),
    # прокси понимает только наш preload внутри pi-telegram-bridge.
    if [[ "${TG_MODE:-0}" == "1" && -n "${PIBOX_TELEGRAM_PROXY:-}" ]]; then
        RUN_CMD+=("-e" "PIBOX_TELEGRAM_PROXY=${PIBOX_TELEGRAM_PROXY}")
    fi

    # Образ и команда
    RUN_CMD+=("$IMAGE_NAME")

    if [[ "${WEBUI_MODE:-0}" == "1" ]]; then
        # Лаунчер вместо дефолтного pi: зелёная ссылка + exec pi-web-ui
        RUN_CMD+=("webui")
    elif [[ "${TG_MODE:-0}" == "1" ]]; then
        # Мост Telegram вместо дефолтного pi: RPC-демон + /telegram-connect
        # (foreground; TERM/INT = остановка). Аргументы pi не пробрасываются —
        # их задаёт сам мост (--mode rpc --continue).
        RUN_CMD+=("pi-telegram-bridge" "run")
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
