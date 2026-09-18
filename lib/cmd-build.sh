# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
cmd_build() {
    local no_cache=""

    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --no-cache)
            no_cache="--no-cache"
            shift
            ;;
        *)
            err "Неизвестная опция для build: $1"
            usage
            exit 1
            ;;
        esac
    done

    check_docker

    log "Собираю образ $IMAGE_NAME..."
    docker build $no_cache -t "$IMAGE_NAME" "$PIBOX_DIR/docker"
}

# Управление окружениями
