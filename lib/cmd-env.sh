# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)

# Управление окружениями: env list | env create NAME | env remove NAME |
# env upgrade NAME. remove для default запрещён; create/remove/upgrade
# валидируют имя через validate_env_name (common.sh).

# env upgrade: доводит продуктовый каркас окружения до актуального
# template/common (после обновления pibox старый env остаётся со старым каркасом).
# Для каждого файла common: отсутствует → копируем; отличается → перезаписываем
# (шаблон побеждает — та же семантика, что у apply_user_layer); идентичен → skip.
# Файлы, перекрытые слоем user, пропускаем — их источник template/user.
# Файлы, которых нет в common (состояние агента: сессии, npm, models.json), не трогаем.
# -n/--dry-run — только показать, что изменится.
upgrade_env() {
    local env_name="$1"
    local dry_run="${2:-0}"
    local env_dir="$PIBOX_DIR/env/$env_name"
    local template_dir="$PIBOX_DIR/template/common"
    local user_dir="$PIBOX_DIR/template/user"
    [[ -d "$env_dir" ]] || die "Окружение '$env_name' не найдено"
    [[ -d "$template_dir" ]] || die "Шаблон не найден: $template_dir — переустановите pibox: install.sh"

    local rel src dst added=0 updated=0 unchanged=0 skipped_user=0
    while IFS= read -r src; do
        rel="${src#"$template_dir"/}"
        # перекрыт слоем user — источник template/user, common-версию не трогаем
        if [[ -f "$user_dir/$rel" ]]; then
            skipped_user=$((skipped_user + 1))
            continue
        fi
        dst="$env_dir/$rel"
        if [[ ! -e "$dst" ]]; then
            if [[ "$dry_run" == "1" ]]; then
                log "добавлю: $rel"
            else
                mkdir -p "$(dirname "$dst")"
                cp -a "$src" "$dst"
            fi
            added=$((added + 1))
        elif ! cmp -s "$src" "$dst"; then
            if [[ "$dry_run" == "1" ]]; then
                log "обновлю: $rel"
            else
                cp -a "$src" "$dst"
            fi
            updated=$((updated + 1))
        else
            unchanged=$((unchanged + 1))
        fi
    done < <(find "$template_dir" -type f 2>/dev/null)

    if [[ "$dry_run" == "1" ]]; then
        log "dry-run: добавлено $added, обновлено $updated, без изменений $unchanged, перекрыто user $skipped_user"
        return 0
    fi
    log "Окружение '$env_name' обновлено: добавлено $added, обновлено $updated, без изменений $unchanged"
    if [[ "$skipped_user" -gt 0 ]]; then
        log "перекрыто слоем user (не тронуто): $skipped_user"
    fi
    return 0
}

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
    upgrade)
        local env_name="" dry_run="0"
        while [[ $# -gt 0 ]]; do
            case "$1" in
            -n | --dry-run)
                dry_run="1"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                err "Неизвестная опция для env upgrade: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -n "$env_name" ]]; then
                    err "Лишний аргумент: $1"
                    usage
                    exit 1
                fi
                env_name="$1"
                shift
                ;;
            esac
        done
        [[ -n "$env_name" ]] || die "env upgrade требует имя окружения"
        validate_env_name "$env_name"
        upgrade_env "$env_name" "$dry_run"
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
    check_workspace_isolation

    check_docker

    # Персистентный кэш jiti — как в build_docker_run_cmd; mkdir от хост-юзера.
    mkdir -p "$PIBOX_DIR/env/$env_name/.cache/jiti"

    # Проект — в подкаталог по имени (workspace_path из common.sh), cwd — туда же.
    local ws_path
    ws_path="$(workspace_path)"
    cleanup_workspace_mounts "$env_name"
    mkdir -p "$PIBOX_DIR/env/$env_name/workspace/$(workspace_name)"

    log "Запуск оболочки в окружении '$env_name'..."
    docker run --rm -it \
        --add-host host.docker.internal:host-gateway \
        --cap-add SYS_PTRACE --cap-add NET_RAW \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e PIBOX_GIT_SAFE="${PIBOX_GIT_SAFE:-0}" \
        -v "$PIBOX_DIR/env/$env_name:/home/pi" \
        -v "$(pwd):${ws_path}" \
        -w "$ws_path" \
        -v "$PIBOX_DIR/env/$env_name/.cache/jiti:/tmp/jiti" \
        "$IMAGE_NAME" bash
}
