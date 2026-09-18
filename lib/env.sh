# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Управление окружениями -----------------------------------------------------

# Создание окружения из шаблона env/.template, если оно не существует
create_env() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local template_dir="$PIBOX_DIR/env/.template"

    if [[ ! -d "$env_dir" ]]; then
        if [[ ! -d "$template_dir" ]]; then
            die "Шаблон окружения не найден: $template_dir. Переустановите pibox: install.sh"
        fi
        log "Создаю окружение '$env_name' из шаблона..."
        mkdir -p "$env_dir"
        cp -a "$template_dir/." "$env_dir/"
    fi
}

# Копирование models.json в окружение при первом запуске
copy_models_json() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local models_src="$PIBOX_DIR/models.json"
    local models_dst="$env_dir/.pi/agent/models.json"

    # Копируем только если источник существует и назначение отсутствует
    if [[ -f "$models_src" && ! -f "$models_dst" ]]; then
        mkdir -p "$(dirname "$models_dst")"
        cp "$models_src" "$models_dst"
        log "Скопирован models.json в окружение '$env_name'"
    fi
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
