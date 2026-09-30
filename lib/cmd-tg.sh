# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Подкоманда tg --------------------------------------------------------------

# pibox tg — запуск контейнера в режиме Telegram-моста (без TTY/TUI).
#
# Отличия от run:
# - командой контейнера становится `pi-telegram-bridge run` (/usr/local/bin,
#   вшит в образ): RPC-демон pi + автоподключение расширения
#   @llblab/pi-telegram — задания и отчёты через бота; Ctrl+C останавливает;
# - аргументы pi не принимаются (их задаёт сам мост: --mode rpc --continue);
# - порты не публикуются (мост ходит наружу к api.telegram.org);
# - имя контейнера pibox-<env>-tg — отдельно от TUI и webui (pi рассчитан
#   на параллельные сессии, docker rm -f чужого контейнера недопустим).
#
# Контракты — негласные связи с другими файлами; bash не проверяет их
# автоматически, при рассогласовании — только молча сломанное поведение.
# Меняешь одну сторону — синхронизируй вторую.
# 1. build_docker_run_cmd (docker-cmd.sh) читает наш локальный TG_MODE через
#    динамическую область видимости: TG_MODE=1 подменяет команду контейнера
#    на «pi-telegram-bridge run». Переименуешь переменную здесь — там её
#    не увидят и запустится обычный TUI.
# 2. docker/entrypoint.sh пропускает фоновый автостарт моста, когда команда
#    контейнера — «pi-telegram-bridge» (иначе два демона дерутся за
#    singleton-lock). Связь по первому аргументу CMD.
# 3. launch_container (cmd-run.sh) знает суффикс имени «-tg» и штатность
#    остановки по SIGTERM/SIGINT (143/130).
cmd_tg() {
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

    if ! parse_common_run_opts tg "$@"; then
        # В tg-режиме аргументы pi не передаются (их задаёт мост).
        # «--» допускаем только с пустым хвостом, чтобы явный
        # `pibox tg -- что-то` не молчал, а объяснял.
        if [[ ${#COMMON_TAIL[@]} -gt 0 ]]; then
            die "pibox tg не принимает аргументы pi после '--': ${COMMON_TAIL[*]}. Рабочий каталог моста задаётся -E PIBOX_BRIDGE_DIR=/путь"
        fi
    fi

    # Режим tg — локальный, launch_container/build_docker_run_cmd видят его
    # через динамическую область видимости (тот же контракт, что WEBUI_MODE).
    local TG_MODE=1

    launch_container
}
