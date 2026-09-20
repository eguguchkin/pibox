# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Управление окружениями -----------------------------------------------------

# Создание окружения из template/common (слой 1), если оно не существует.
# Затем применяется слой 2 (template/user) — см. layers.sh.
create_env() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local template_dir="$PIBOX_DIR/template/common"

    if [[ ! -d "$env_dir" ]]; then
        if [[ ! -d "$template_dir" ]]; then
            die "Шаблон окружения не найден: $template_dir. Переустановите pibox: install.sh"
        fi
        log "Создаю окружение '$env_name' из шаблона..."
        mkdir -p "$env_dir"
        cp -a "$template_dir/." "$env_dir/"
    fi
    apply_user_layer "$env_name"
}

# Список доступных окружений
list_envs() {
    echo "Доступные окружения:"
    local env_dir
    for env_dir in "$PIBOX_DIR/env"/*; do
        [[ -d "$env_dir" ]] || continue
        echo "  $(basename "$env_dir")"
    done
}
