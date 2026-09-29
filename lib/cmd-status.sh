# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# pibox status — контейнеры pibox: запущенные (docker ps) и остановленные.
# Контейнеры узнаются по префиксу имени pibox- (контракт именования
# docker-cmd.sh): pibox-<env> = TUI, pibox-<env>-webui = webui-режим.
# Читательская команда: docker не меняет состояние, кодом не трогаем env.

# Строка таблицы: имя контейнера → env/режим.
_status_row() {
    local name="$1" st="$2" img="$3" env mode
    name="${name#/}"
    if [[ "$name" == pibox-*-webui ]]; then
        mode="webui"
        env="${name#pibox-}"
        env="${env%-webui}"
    else
        mode="tui"
        env="${name#pibox-}"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$env" "$mode" "$st" "$img"
}

cmd_status() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестная опция для status: $arg"
            usage
            exit 1
            ;;
        esac
    done

    check_docker

    local live
    live="$(docker ps --filter 'name=pibox-' --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null)"

    if [[ -z "$live" ]]; then
        printf 'Запущенных контейнеров pibox нет\n' >&2
    else
        printf 'Запущенные контейнеры pibox:\n' >&2
        local rows
        rows="$(
            while IFS=$'\t' read -r name st img; do
                [[ -z "${name:-}" ]] && continue
                _status_row "$name" "$st" "$img"
            done <<<"$live"
        )"
        if command -v column >/dev/null 2>&1; then
            printf '%s\n' "$rows" | column -t
        else
            printf '%s\n' "$rows" | tr '\t' '  '
        fi
    fi

    local stopped n
    stopped="$(docker ps -a --filter 'name=pibox-' --filter 'status=exited' --format '{{.Names}}' 2>/dev/null)"
    if [[ -n "$stopped" ]]; then
        n="$(wc -l <<<"$stopped")"
        printf 'Остановленные: %s\n' "$n" >&2
        head -n 5 <<<"$stopped" | sed 's/^/  /'
        if [[ "$n" -gt 5 ]]; then
            printf '  …ещё %d\n' $((n - 5))
        fi
    fi
    return 0
}
