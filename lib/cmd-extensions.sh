# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
cmd_extensions() {
    local subcmd="${1:-}"
    [[ "$subcmd" == "install" ]] || {
        err "использование: pibox extensions install [-e ИМЯ]"
        exit 1
    }
    shift

    local env_name="$DEFAULT_ENV"
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            env_name="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестная опция для extensions install: $1"
            usage
            exit 1
            ;;
        esac
    done

    validate_env_name "$env_name"

    local env_dir="$PIBOX_DIR/env/$env_name"
    if [[ ! -d "$env_dir" ]]; then
        die "окружение '$env_name' не найдено — создайте: pibox env create $env_name"
    fi

    load_extensions_manifest
    if [[ ${#EXT_ENTRIES[@]} -eq 0 ]]; then
        die "манифест пуст или отсутствует: $PIBOX_DIR/$EXTENSIONS_FILE"
    fi

    check_docker
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        die "образ $IMAGE_NAME не найден — соберите: pibox build"
    fi

    local nm="$env_dir/.pi/agent/npm/node_modules"
    local total=${#EXT_ENTRIES[@]}
    local installed=0 skipped=0 failed=0 idx=0
    local entry have
    local -a need_install=() need_settings=()

    # Фаза планирования — молча: решаем, что ставить. Ничего не печатаем,
    # чтобы пользователь видел прогресс шаг за шагом, а не список заранее.
    # actions[] параллелен EXT_ENTRIES: "skip" | "install" (пусто = не разобрали).
    log "Расширения окружения '$env_name' ($total в манифесте)..."
    local -a actions=()
    for entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
        idx=$((idx + 1))
        if ! parse_ext_entry "$entry"; then
            warn "[$idx/$total] не могу разобрать запись манифеста: $entry"
            failed=$((failed + 1))
            continue
        fi
        have="$(get_installed_ext_version "$nm" "$EXT_NAME")"
        if [[ "$have" == "$EXT_VER" ]]; then
            actions+=("skip")
            skipped=$((skipped + 1))
        else
            actions+=("install")
            need_install+=("$entry")
        fi
        need_settings+=("$entry")
    done

    # Установка: по одному пакету за запуск pi. Чужая ошибка не рушит остаток;
    # ошибка одного пакета не должна блокировать остальные (npm-дерево общее,
    # но установки pi идемпотентны — безопасно перезапускать).
    if [[ ${#need_install[@]} -eq 0 ]]; then
        # всё уже установлено — зелёные строки по числу расширений манифеста
        local a_idx=0 e
        for e in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
            a_idx=$((a_idx + 1))
            parse_ext_entry "$e" || continue # warn уже выведен при планировании
            if [[ -t 2 ]]; then
                printf '\033[32m✓ [%d/%d] %s@%s — уже установлен\033[0m\n' \
                    "$a_idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
            else
                printf '✓ [%d/%d] %s@%s — уже установлен\n' \
                    "$a_idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
            fi
        done
    else
        local tty_render=0
        [[ -t 2 ]] && tty_render=1
        local tmpdir winfile statusfile startfile running fulllog tpid
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pibox-ext.XXXXXX")"
        winfile="$tmpdir/window"
        statusfile="$tmpdir/status"
        startfile="$tmpdir/start"
        running="$tmpdir/running"
        fulllog="$tmpdir/full.log"
        : >"$winfile"
        : >"$fulllog"

        local cur=0 ok_line ok_color elapsed now
        local START_TS entry_act
        local idx=0 # сброс: idx уже использован в фазе планирования
        local a_idx=0
        if [[ $tty_render -eq 1 ]]; then
            printf '\033[?25l' >&2 # скрыть курсор на всю установку — один раз
        fi
        trap '_ext_on_interrupt "$running" "${tpid:-}"' INT TERM
        for entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
            idx=$((idx + 1))
            parse_ext_entry "$entry" || continue # warn уже выведен при планировании
            entry_act=""
            if [[ $a_idx -lt ${#actions[@]} ]]; then
                entry_act="${actions[$a_idx]}"
            fi
            a_idx=$((a_idx + 1))
            if [[ "$entry_act" == "skip" ]]; then
                # пропуск печатается на месте, в порядке манифеста; живой
                # области в этот момент нет — предыдущий пакет уже зафиксирован
                if [[ $tty_render -eq 1 ]]; then
                    printf '\033[32m  [%d/%d] %s@%s — уже установлен\033[0m\n' \
                        "$idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
                else
                    printf '  [%d/%d] %s@%s — уже установлен\n' \
                        "$idx" "$total" "$EXT_NAME" "$EXT_VER" >&2
                fi
                continue
            fi
            cur=$((cur + 1))
            have="$(get_installed_ext_version "$nm" "$EXT_NAME")"
            START_TS="$(date +%s)"
            if [[ -n "$have" ]]; then
                printf '%s' "[$idx/$total] $EXT_NAME@$EXT_VER (обновляю, было $have)" >"$statusfile"
            else
                printf '%s' "[$idx/$total] $EXT_NAME@$EXT_VER" >"$statusfile"
            fi
            printf '%s' "$START_TS" >"$startfile"
            : >"$winfile"
            if [[ $tty_render -eq 1 ]]; then
                : >"$running"
                _ext_timer_loop "$running" "$statusfile" "$startfile" "$winfile" &
                tpid=$!
            else
                printf '  pi install %s\n' "$entry" >&2
            fi
            # if-обёртка гасит errexit/pipefail от docker-провала. Читатель НЕ
            # рисует — только пишет в full.log и в окно; рисует один таймер.
            # Атомарность дописывания: одиночный printf со встроенными \n.
            if docker run --rm \
                -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
                -v "$env_dir:/home/pi" \
                "$IMAGE_NAME" pi install "$entry" 2>&1 | while IFS= read -r line; do
                printf '%s\n' "$line" >>"$fulllog"
                _ext_strip_ansi <<<"$line" | sed 's/^/  │ /' >>"$winfile"
            done; then
                installed=$((installed + 1))
                ok_color=32
                ok_line="✓ $EXT_NAME@$EXT_VER"
            else
                failed=$((failed + 1))
                ok_color=31
                ok_line="✗ $EXT_NAME@$EXT_VER — ошибка (полный лог: $fulllog)"
                if [[ $tty_render -ne 1 ]]; then
                    warn "не удалось установить: $entry (продолжаю остальными)"
                fi
            fi
            now="$(date +%s)"
            elapsed=$((now - START_TS))
            ok_line="$ok_line (${elapsed}s)"
            if [[ $tty_render -eq 1 ]]; then
                rm -f "$running"
                wait "$tpid" 2>/dev/null || true
                # стереть живую область, затем ✓/✗ фиксируется навсегда;
                # следующий пункт добавится строкой ниже
                _ext_commit "$ok_line" "$ok_color" >&2
            else
                printf '  %s\n' "$ok_line" >&2
            fi
        done
        if [[ $tty_render -eq 1 ]]; then
            _ext_show_cursor
            trap - INT TERM
        fi
        if [[ $failed -gt 0 && $tty_render -eq 1 ]]; then
            # живая область уже стёрта в _ext_commit; курсор ниже ✓-строк
            printf '\033[90m── последние строки журнала ──\033[0m\n' >&2
            tail -n 20 "$fulllog" | _ext_strip_ansi >&2
        fi
        rm -rf "$tmpdir"
    fi

    # settings.json: добавляем только отсутствующие записи (порядок сохраняем).
    local settings="$env_dir/.pi/agent/settings.json"
    mkdir -p "$(dirname "$settings")"
    [[ -f "$settings" ]] || printf '{"packages":[]}\n' >"$settings"
    load_settings_packages "$settings"
    local -a missing=()
    local want known
    for want in ${need_settings[@]+"${need_settings[@]}"}; do
        parse_ext_entry "$want" || continue
        # в settings.json источник без версии (pi хранит "npm:имя")
        local short="npm:$EXT_NAME"
        known=""
        local sp
        for sp in ${EXT_SETTINGS_PACKAGES[@]+"${EXT_SETTINGS_PACKAGES[@]}"}; do
            if [[ "$sp" == "$short" || "$sp" == "$want" ]]; then
                known=1
                break
            fi
        done
        [[ -n "$known" ]] || missing+=("$short")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        mkdir -p "$(dirname "$settings")"
        local m
        for m in ${missing[@]+"${missing[@]}"}; do
            if jq --arg p "$m" '.packages = ((.packages // []) + [$p] | unique)' "$settings" >"$settings.tmp" &&
                mv "$settings.tmp" "$settings"; then
                :
            else
                rm -f "$settings.tmp"
                warn "не удалось дополнить settings.json ($m) — добавьте вручную: \"packages\" += \"$m\""
                failed=$((failed + 1))
            fi
        done
    fi

    printf '\n' >&2
    log "Готово: новых: $installed, уже стояли: $skipped, проблем: $failed"
    if [[ $failed -gt 0 ]]; then
        die "есть ошибки установки — повторите: pibox extensions install -e $env_name"
    fi
    log "Расширения подключатся при следующем запуске pi в окружении '$env_name'"
}

# Обновление установки (заглушка)
