# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Слои шаблона ----------------------------------------------------------------
#
# Двухслойный шаблон (см. template/README.md):
#   template/common — слой 1: продукт, начальное состояние env (create_env)
#   template/user   — слой 2: личные инварианты, применяются при каждом запуске
#
# Семантика слоя 2:
#   - копируются ТОЛЬКО пути, существующие в template/user (ничего не удаляется,
#     отсутствующие в user файлы в env не трогаются);
#   - файл из user с тем же путём перекрывает common (с предупреждением);
#   - память (memory/) в слое не участвует — она живёт в env;
#   - opt-out: PIBOX_NO_USER_LAYER=1.

# Применить слой 2 (template/user) к окружению.
# $1 — имя окружения. Идемпотентно; лог — одна строка.
apply_user_layer() {
    local env_name="$1"
    local user_dir="$PIBOX_DIR/template/user"
    local env_dir="$PIBOX_DIR/env/$env_name"

    [[ "${PIBOX_NO_USER_LAYER:-0}" == "1" ]] && return 0
    [[ -d "$user_dir" && -d "$env_dir" ]] || return 0

    local count=0 overlap=0
    local src dst rel
    while IFS= read -r src; do
        rel="${src#"$user_dir"/}"
        dst="$env_dir/$rel"
        mkdir -p "$(dirname "$dst")"
        if [[ -f "$dst" ]]; then
            if cmp -s "$src" "$dst"; then continue; fi
            if [[ -f "$PIBOX_DIR/template/common/$rel" ]]; then
                overlap=$((overlap + 1))
            fi
        fi
        cp "$src" "$dst"
        count=$((count + 1))
    done < <(find "$user_dir" -type f ! -path '*/.git/*' 2>/dev/null)

    if [[ "$count" -gt 0 ]]; then
        local msg="слой user: применено $count файл(ов)"
        [[ "$overlap" -gt 0 ]] && msg="$msg (перекрывает common: $overlap)"
        log "$msg"
    fi
}

# Относительные пути (env-внутренние) всех файлов слоя 2.
# Заполняет массив LAYER_USER_PATHS.
layer_user_paths() {
    local user_dir="$PIBOX_DIR/template/user"
    LAYER_USER_PATHS=()
    [[ -d "$user_dir" ]] || return 0
    local src
    while IFS= read -r src; do
        LAYER_USER_PATHS+=("${src#"$user_dir"/}")
    done < <(find "$user_dir" -type f ! -path '*/.git/*' 2>/dev/null)
}

# Дрейф между env и слоем 2: файлы слоя, отличающиеся от env-версии.
# Заполняет массив LAYER_DRIFT_PATHS (относительные пути).
layers_drift() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    layer_user_paths
    LAYER_DRIFT_PATHS=()
    local rel
    for rel in ${LAYER_USER_PATHS[@]+"${LAYER_USER_PATHS[@]}"}; do
        if [[ ! -f "$env_dir/$rel" ]] || ! cmp -s "$PIBOX_DIR/template/user/$rel" "$env_dir/$rel"; then
            LAYER_DRIFT_PATHS+=("$rel")
        fi
    done
}

# pibox user push — применить слой 2 к окружению (то же, что делает старт).
user_push() {
    local env_name="$1"
    apply_user_layer "$env_name"
    log "Готово: template/user применён к '$env_name'"
}

# pibox user pull [PATH…] [-n] — сохранить файлы env в template/user.
#   без PATH: все файлы слоя с дрейфом;
#   PATH:     конкретные файлы (env-внутренние пути, напр. .pi/agent/USER.md),
#             могут быть новыми для слоя — тогда добавляются в него.
user_pull() {
    local env_name="$1"
    shift
    local dry_run=0
    local -a paths=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -n | --dry-run)
            dry_run=1
            shift
            ;;
        *)
            paths+=("$1")
            shift
            ;;
        esac
    done

    local env_dir="$PIBOX_DIR/env/$env_name"
    local user_dir="$PIBOX_DIR/template/user"
    if [[ ! -d "$env_dir" ]]; then
        die "Окружение '$env_name' не найдено: $env_dir"
    fi

    if [[ ${#paths[@]} -eq 0 ]]; then
        layers_drift "$env_name"
        paths=(${LAYER_DRIFT_PATHS[@]+"${LAYER_DRIFT_PATHS[@]}"})
        if [[ ${#paths[@]} -eq 0 ]]; then
            log "Дрейфа нет: env и template/user совпадают"
            return 0
        fi
    fi

    local rel dst src acted=0
    for rel in "${paths[@]}"; do
        # нормализация: без ведущего слеша, без выхода за env
        rel="${rel#/}"
        case "$rel" in
        ../* | */../*) die "Недопустимый путь: $rel" ;;
        esac
        src="$env_dir/$rel"
        dst="$user_dir/$rel"
        if [[ ! -f "$src" ]]; then
            warn "нет в env, пропускаю: $rel"
            continue
        fi
        if [[ "$dry_run" == "1" ]]; then
            if [[ ! -f "$dst" ]]; then
                printf '  [новый] %s\n' "$rel"
            else
                diff -u "$dst" "$src" | sed "s|${dst}|template/user/$rel|" || true
            fi
        else
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            printf '  [pull] %s\n' "$rel"
            acted=$((acted + 1))
        fi
    done
    if [[ "$dry_run" == "1" ]]; then
        log "dry-run: показан diff, ничего не записано"
    else
        log "Готово: $acted файл(ов) из '$env_name' сохранено в template/user"
    fi
}
