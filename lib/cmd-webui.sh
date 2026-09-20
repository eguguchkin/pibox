# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Подкоманда webui ------------------------------------------------------------

# pibox webui — запуск агента с браузерным UI (pi-web-ui, вшит в образ).
#
# Отличия от run:
#   - автоматически пробрасывается порт webui (8787:8787, настраивается);
#   - командой контейнера становится лаунчер `webui` (/usr/local/bin/webui):
#     печатает зелёную ссылку и exec'ит pi-web-ui в foreground — в консоль
#     идут логи сервера и агента, Ctrl+C останавливает контейнер;
#   - сессии/модели те же, что у TUI (~/.pi/agent в env), данные UI — ~/.pi-web.
#
# Контракты:
#   - webui.sh + Dockerfile: лаунчер, PI_WEB_PORT/WEBUI_HOST_PORT;
#   - docker-cmd.sh: WEBUI_MODE / WEBUI_PORT / WEBUI_HOST_PORT;
#   - launch_container (cmd-run.sh): общее ядро запуска + старт/остановка
#     фонового «ждуна» автооткрытия браузера (webui_wait_and_open).

cmd_webui() {
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
    local PORT=""
    local AUTO_OPEN="1"
    local WEBUI_OPEN_URL=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --)
            shift
            # В webui-режиме аргументы pi не передаются (команда контейнера —
            # лаунчер webui); допускаем «--» только с пустым хвостом, чтобы
            # явный `pibox webui -- что-то` не молчал, а объяснял.
            if [[ $# -gt 0 ]]; then
                die "pibox webui не принимает аргументы pi после '--': $*. Передайте их обычному запуску 'pibox -- …'"
            fi
            break
            ;;
        -e | --env | -p | --publish | -E | --pass-env | --env-file | \
            --memory | --cpus | --pids-limit | --name)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            case "$1" in
            -e | --env) ENV_NAME="$2" ;;
            -p | --publish) PUBLISH_OPTS+=("$2") ;;
            -E | --pass-env) PASS_ENV_OPTS+=("$2") ;;
            --env-file) ENV_FILE="$2" ;;
            --memory) MEMORY="$2" ;;
            --cpus) CPUS="$2" ;;
            --pids-limit) PIDS_LIMIT="$2" ;;
            --name) CONTAINER_NAME="$2" ;;
            esac
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            PORT="$2"
            shift 2
            ;;
        --no-open)
            AUTO_OPEN=0
            shift
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
            err "Неизвестная опция или аргумент для webui: $1"
            usage
            exit 1
            ;;
        esac
    done

    # Режим для docker-cmd.sh: проброс порта + команда контейнера `webui`.
    # Дефолт контейнерного порта — 8787 (совпадает с дефолтом pi-web-ui);
    # --port меняет ОБА конца маппинга (host:container). Своё -p остаётся
    # доступным для остальных портов; конфликтующий маппинг не дублируем.
    WEBUI_MODE=1
    WEBUI_PORT="${PORT:-8787}"
    [[ "$WEBUI_PORT" =~ ^[0-9]+$ ]] || die "--port: '$WEBUI_PORT' — ожидается номер порта"
    ((WEBUI_PORT >= 1 && WEBUI_PORT <= 65535)) || die "--port: '$WEBUI_PORT' вне диапазона 1–65535"

    # Хост-порт для зелёной ссылки: если юзер явно перебросил на другой
    # хост-порт (-p 9999:8787, -p 127.0.0.1:9999:8787), ссылка должна
    # показывать его. Рассматриваем только маппинги НА контейнерный порт webui.
    WEBUI_HOST_PORT="$WEBUI_PORT"
    local opt
    for opt in ${PUBLISH_OPTS[@]+"${PUBLISH_OPTS[@]}"}; do
        # формат [host_ip:]host_port:container_port[/proto]
        local base="${opt%/*}"    # срезать /tcp|/udp
        local cport="${base##*:}" # контейнерный порт
        if [[ "$cport" == "$WEBUI_PORT" && "$base" == *:* ]]; then
            if [[ "$base" == *:*:* ]]; then
                # ip:host:container
                WEBUI_HOST_PORT="${base#*:}"
                WEBUI_HOST_PORT="${WEBUI_HOST_PORT%%:*}"
            else
                # host:container
                WEBUI_HOST_PORT="${base%%:*}"
            fi
        fi
    done

    # URL автооткрытия браузера: localhost хост-порта. Токен из
    # -E PI_WEB_TOKEN (форма «значение» или голое имя — тогда берём
    # значение из окружения хоста) подставляем в query, чтобы открытая
    # страница была сразу авторизована. Не URL-safe токен в ссылку не
    # подставляем — добавьте ?token= вручную.
    local webui_token=""
    for opt in ${PASS_ENV_OPTS[@]+"${PASS_ENV_OPTS[@]}"}; do
        case "$opt" in
        PI_WEB_TOKEN=*) webui_token="${opt#PI_WEB_TOKEN=}" ;;
        PI_WEB_TOKEN) webui_token="${PI_WEB_TOKEN:-}" ;;
        esac
    done
    WEBUI_OPEN_URL="http://localhost:${WEBUI_HOST_PORT}"
    if [[ -n "$webui_token" && "$webui_token" =~ ^[A-Za-z0-9._~+-]+$ ]]; then
        WEBUI_OPEN_URL="${WEBUI_OPEN_URL}/?token=${webui_token}"
    fi

    # CI/скрипты без TTY: docker run без -t всё равно печатает вывод сервера.
    # Зелёная ссылка уйдёт в stdout контейнера — доступна в логах.

    launch_container
}

# --- Автооткрытие браузера -------------------------------------------------------
#
# Страницу должен открывать браузер ХОСТА: в контейнере браузера нет, а CLI
# `pibox webui` работает на хосте. Сервер начинает отвечать через ~1–3с после
# docker run, поэтому открытие делает фоновый «ждун»: опрашивает хост-порт и
# открывает браузер по готовности. Стартует из launch_container (cmd-run.sh)
# ПОСЛЕ удаления старого контейнера (иначе проба может поймать его сокет);
# PID ждун хранится в WEBUI_OPEN_PID — launch_container убивает его после
# выхода docker run. Без TTY (CI) и при --no-open ждун не стартует.

# TCP/HTTP-проба готовности: ЛЮБОЙ HTTP-ответ — успех (curl без -f: годятся
# и 200, и 401/редирект). curl есть на macOS и почти любом Linux; запасной
# путь — /dev/tcp самого bash.
webui_port_ready() {
    local port="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/"
    else
        exec 3<>"/dev/tcp/127.0.0.1/${port}" 2>/dev/null || return 1
        exec 3>&- 3<&-
    fi
}

# Открыть URL браузером хоста (best-effort: нет open/xdg-open — тихо выходим,
# зелёная ссылка от лаунчера в консоли всё равно есть).
webui_open_browser() {
    local url="$1"
    local opener=""
    case "$(uname -s)" in
    Darwin) opener="open" ;;
    Linux) opener="xdg-open" ;;
    esac
    if [[ -z "$opener" ]] || ! command -v "$opener" >/dev/null 2>&1; then
        return 0
    fi
    "$opener" "$url" >/dev/null 2>&1 || true
}

# Ждать готовности web-ui на хост-порту и открыть браузер. Работает В ФОНЕ
# (вызов с & из launch_container). Таймаут настраивается
# PIBOX_WEBUI_OPEN_TIMEOUT (секунды, по умолчанию 30).
webui_wait_and_open() {
    local url="$1" host_port="$2"
    local timeout="${PIBOX_WEBUI_OPEN_TIMEOUT:-30}" i
    for ((i = 0; i < timeout * 2; i++)); do
        if webui_port_ready "${host_port}"; then
            sleep 0.3 # дать серверу спокойно отдать первый ответ
            webui_open_browser "${url}"
            return 0
        fi
        sleep 0.5
    done
    warn "Браузер не открыт: порт ${host_port} не ответил за ${timeout}с"
    warn "  открой вручную: ${url}"
}
