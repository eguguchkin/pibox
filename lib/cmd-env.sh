# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
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

    # Персистентный кэш jiti — как в build_docker_run_cmd; mkdir от хост-юзера.
    mkdir -p "$PIBOX_DIR/env/$env_name/.cache/jiti"

    # Проект — в подкаталог по имени (workspace_path из common.sh), cwd — туда же.
    local ws_path
    ws_path="$(workspace_path)"
    mkdir -p "$PIBOX_DIR/env/$env_name/workspace/$(workspace_name)"

    log "Запуск оболочки в окружении '$env_name'..."
    docker run --rm -it \
        --cap-add SYS_PTRACE --cap-add NET_RAW \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e PIBOX_GIT_SAFE="${PIBOX_GIT_SAFE:-0}" \
        -v "$PIBOX_DIR/env/$env_name:/home/pi" \
        -v "$(pwd):${ws_path}" \
        -w "$ws_path" \
        -v "$PIBOX_DIR/env/$env_name/.cache/jiti:/tmp/jiti" \
        "$IMAGE_NAME" bash
}

# Установка расширений из манифеста env/extensions.txt.
#
# Каждый пакет ставится отдельным запуском pi внутри одноразового контейнера
# (смонтирован только env; workspace не нужен — npm-установки ни от него
# не зависят, а монтирование произвольного cwd в фоновую операцию — лишний риск).
# pi сам кладёт файлы под хост-пользователя? Нет: контейнер работает от pi
# (uid=HOST_UID через entrypoint), поэтому файлы в bind-mount сразу с
# владельцем хост-юзера — chown не нужен.
#
# Пропускает уже установленное совпадающей версии; для остальных вызывает
# pi install npm:имя@версия. settings.json окружения дополняется записями

# --- живая визуализация установки (в стиле docker build) ---------------------
