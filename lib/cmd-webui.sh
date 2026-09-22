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
# Контракты — негласные связи с другими файлами: bash не проверяет их
# автоматически, при рассогласовании ошибок не будет — только молча сломанное
# поведение. Меняешь одну сторону — синхронизируй вторую.
#
#   1. docker/webui.sh (лаунчер внутри контейнера) читает переменные,
#      которые мы передаём через -e (добавляет их docker-cmd.sh):
#      PI_WEB_PORT — на каком порту поднять сервер внутри контейнера;
#      WEBUI_HOST_PORT — какой хост-порт показать в зелёной ссылке
#      (иначе после «-p 9999:8787» ссылка будет врать про 8787).
#      Переименуешь эти имена здесь или в webui.sh — лаунчер молча
#      откатится на дефолт 8787.
#
#   2. docker-cmd.sh (build_docker_run_cmd) читает наши глобальные
#      переменные WEBUI_MODE / WEBUI_PORT / WEBUI_HOST_PORT — по ним
#      добавляет в docker run проброс порта, -e-переменные из п.1 и
#      подменяет команду контейнера на «webui». Переименуешь их здесь —
#      docker-cmd.sh увидит пустые значения и запустит обычный TUI.
#
#   3. launch_container (cmd-run.sh) выполняет запуск за нас. Договорённость
#      по именам: webui-контейнер зовётся pibox-<env>-webui (суффикс
#      добавляет launch_container), отдельно от TUI-контейнера pibox-<env>.
#      Иначе при запуске webui при работающем TUI той же среды удаление
#      старого контейнера (docker rm -f) убило бы TUI-сессию.

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

    # Хост-порт для зелёной ссылки (её печатает лаунчер webui.sh в
    # контейнере, pibox передаёт порт через -e): если юзер явно перебросил
    # на другой хост-порт (-p 9999:8787, -p 127.0.0.1:9999:8787), ссылка
    # должна показывать его. Рассматриваем только маппинги НА контейнерный
    # порт webui.
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

    launch_container
}
