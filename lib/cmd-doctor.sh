# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
cmd_doctor() {
    local env_name="$DEFAULT_ENV"
    local fix="0"

    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -e | --env)
            [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
            env_name="$2"
            shift 2
            ;;
        --fix)
            fix="1"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Неизвестная опция для doctor: $1"
            usage
            exit 1
            ;;
        esac
    done

    validate_env_name "$env_name"

    local errors=0 warnings=0
    d_ok() { printf '  [OK]   %s\n' "$*"; }
    d_info() { printf '  [..]   %s\n' "$*"; }
    d_warn() {
        printf '  [WARN] %s\n' "$*"
        warnings=$((warnings + 1))
    }
    d_err() {
        printf '  [FAIL] %s\n' "$*"
        errors=$((errors + 1))
    }

    # KB -> человекочитаемый размер
    human_kb() {
        if [[ "$1" -ge 1024 ]]; then printf '%d МБ' "$(($1 / 1024))"; else printf '%d КБ' "$1"; fi
    }

    local doctor_mode="окружение: $env_name"
    [[ "$fix" == "1" ]] && doctor_mode="$doctor_mode, режим --fix"
    log "Диагностика pibox ($doctor_mode)..."

    # D1: docker
    local server_version
    server_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    if [[ -z "$server_version" ]]; then
        d_err "docker не найден или daemon не отвечает"
        printf '\nПродолжение диагностики невозможно без docker.\n'
        return 1
    fi
    d_ok "docker ${server_version}"

    # D2: образ
    local image_ok=0
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        d_ok "образ ${IMAGE_NAME} найден"
    else
        image_ok=1
        d_err "образ ${IMAGE_NAME} не найден — соберите: pibox build"
    fi

    # D3: состав образа — pi на месте, тяжёлые тулчейны не протекли.
    # Важно: /home/pi — персистентный bind-mount, туда пользователь осознанно
    # ставит тулчейны через mise; они НЕ часть образа. Поэтому ищем только
    # то, что реально лежит в образе: резолвим путь бинарника и игнорируем /home.
    if [[ "$image_ok" == "0" ]]; then
        if docker run --rm "$IMAGE_NAME" bash -c \
            'command -v pi >/dev/null 2>&1 || exit 1; for t in gcc gdb rustc cargo cmake valgrind strace tcpdump; do p="$(command -v "$t" 2>/dev/null)" || continue; case "$(readlink -f "$p")" in /home/*) continue ;; esac; exit 1; done' \
            >/dev/null 2>&1; then
            d_ok "образ: pi на месте, тяжёлых тулчейнов нет"
        else
            d_warn "в образе протек тулчейн или пропал pi — пересоберите: pibox build --no-cache"
        fi
    fi

    # D4: окружение
    local env_ok=0
    local env_dir="$PIBOX_DIR/env/$env_name"
    if [[ -d "$env_dir" ]]; then
        d_ok "окружение '$env_name': $env_dir"
    else
        env_ok=1
        local available="" ed
        for ed in "$PIBOX_DIR/env"/*; do
            [[ -d "$ed" ]] || continue
            available+="$(basename "$ed") "
        done
        d_err "окружение '$env_name' не найдено — создастся автоматически при 'pibox run -e $env_name'"
        d_info "доступные окружения: ${available:-()пусто)}"
    fi

    # D5: каркас окружения — то, что есть в источниках, должно быть и в окружении.
    # Источник зависит от файла: models.json живёт в корне репо (в шаблон не
    # копируется, раскладывается по окружениям при первом запуске), остальное —
    # в env/.template.
    local template_dir="$PIBOX_DIR/env/.template"
    if [[ "$env_ok" == "0" ]]; then
        if [[ -d "$template_dir" ]]; then
            local rel src e_path
            for rel in .pi/agent/AGENTS.md .pi/agent/models.json .pi/agent/skills; do
                if [[ "$rel" == ".pi/agent/models.json" ]]; then
                    src="$PIBOX_DIR/models.json"
                else
                    src="$template_dir/$rel"
                fi
                e_path="$env_dir/$rel"
                [[ -e "$src" ]] || continue
                if [[ -e "$e_path" ]]; then
                    d_ok "$rel"
                elif [[ "$fix" == "1" ]]; then
                    mkdir -p "$(dirname "$e_path")"
                    if cp -a "$src" "$e_path"; then
                        d_ok "$rel — восстановлен (--fix)"
                    else
                        d_err "$rel — не удалось восстановить"
                    fi
                else
                    d_err "$rel отсутствует — восстановление: pibox doctor -e $env_name --fix"
                fi
            done
        else
            d_err "шаблон окружения не найден: $template_dir — переустановите pibox: install.sh"
        fi
    fi

    # D6: платформенные дубли расширений (статический аудит)
    local nm="$env_dir/.pi/agent/npm/node_modules"
    if [[ -d "$nm" ]]; then
        local host_arch good_arch junk_arch1 junk_arch2
        host_arch="$(uname -m)"
        case "$host_arch" in
        x86_64 | amd64)
            good_arch="x64"
            junk_arch1="arm64"
            junk_arch2="aarch64"
            ;;
        aarch64 | arm64)
            good_arch="arm64"
            junk_arch1="x64"
            junk_arch2="x86"
            ;;
        *)
            good_arch=""
            junk_arch1=""
            junk_arch2=""
            ;;
        esac
        local -a junk_patterns=(-name '*-musl' -o -name '*-darwin*' -o -name '*-win32*')
        if [[ -n "$junk_arch1" ]]; then
            junk_patterns+=("-o" "-name" "*-linux-${junk_arch1}*" "-o" "-name" "*-linux-${junk_arch2}*")
        fi

        local junk_dirs=()
        local d
        while IFS= read -r d; do
            junk_dirs+=("$d")
        done < <(find "$nm" -maxdepth 6 -type d \( "${junk_patterns[@]}" \) 2>/dev/null)

        local junk_total_kb=0
        local rel_twin d_kb size
        if [[ ${#junk_dirs[@]} -eq 0 ]]; then
            d_ok "расширения: платформенных дублей нет"
        else
            for d in ${junk_dirs[@]+"${junk_dirs[@]}"}; do
                # твин: рабочий вариант того же пакета
                case "$d" in
                *-musl) rel_twin="${d%-musl}-gnu" ;;
                *-linux-x64*) rel_twin="${d/-linux-x64/-linux-arm64}" ;;
                *-linux-x86*) rel_twin="${d/-linux-x86/-linux-arm64}" ;;
                *-linux-arm64*) rel_twin="${d/-linux-arm64/-linux-x64}" ;;
                *-linux-aarch64*) rel_twin="${d/-linux-aarch64/-linux-x64}" ;;
                *) rel_twin="" ;; # darwin/win32 мертвы на linux всегда
                esac
                d_kb="$(du -sk "$d" 2>/dev/null | cut -f1)"
                d_kb="${d_kb:-0}"
                size="$(human_kb "$d_kb")"
                if [[ -z "$rel_twin" || -d "$rel_twin" ]]; then
                    junk_total_kb=$((junk_total_kb + d_kb))
                    if [[ "$fix" == "1" ]]; then
                        if rm -rf "$d"; then
                            d_ok "дубль удалён (--fix): ${d#"$nm"/} ($size)"
                        else
                            d_err "не удалось удалить дубль: $d"
                        fi
                    else
                        d_warn "дубль: ${d#"$nm"/} ($size) — чистка: pibox doctor -e $env_name --fix"
                    fi
                else
                    d_warn "платформенный пакет без рабочего твина (не удаляю, разберитесь вручную): ${d#"$nm"/}"
                fi
            done
        fi

        # Известный случай: x64-артефакты внутри основного пакета @llamaindex/liteparse
        # при установленном платформенном пакете (файлы .node/.so чужой архитектуры).
        if [[ -n "$good_arch" ]] && command -v file >/dev/null 2>&1 &&
            [[ -d "$nm/@llamaindex/liteparse" ]] &&
            [[ -d "$nm/@llamaindex/liteparse-linux-$good_arch-gnu" ]]; then
            local f farch dead fk
            while IFS= read -r f; do
                farch="$(file -b "$f" 2>/dev/null || true)"
                dead=0
                case "$farch" in
                *x86-64*) [[ "$good_arch" != "arm64" ]] || dead=1 ;;
                *aarch64* | *ARM*) [[ "$good_arch" != "x64" ]] || dead=1 ;;
                *) continue ;; # не ELF или не определился — не трогаем
                esac
                [[ "$dead" == "1" ]] || continue
                fk="$(du -sk "$f" 2>/dev/null | cut -f1)"
                fk="${fk:-0}"
                junk_total_kb=$((junk_total_kb + fk))
                if [[ "$fix" == "1" ]]; then
                    if rm -f "$f"; then
                        d_ok "чужой-arch артефакт удалён (--fix): ${f#"$nm"/} ($(human_kb "$fk"))"
                    else
                        d_err "не удалось удалить: $f"
                    fi
                else
                    d_warn "чужой-arch артефакт: ${f#"$nm"/} ($(human_kb "$fk")) — чистка: pibox doctor -e $env_name --fix"
                fi
            done < <(find "$nm/@llamaindex/liteparse" -maxdepth 1 -type f \( -name '*.node' -o -name '*.so' \) 2>/dev/null)
        fi

        if [[ "$junk_total_kb" -gt 0 ]]; then
            d_info "итого мусора в расширениях: $(human_kb "$junk_total_kb")"
        fi
    else
        d_info "расширения не установлены ($nm отсутствует)"
    fi

    # D7: npm-кэш (персистентен в env, раздувается — см. PROJECT.md)
    local cache_dir="$env_dir/.npm/_cacache"
    if [[ -d "$cache_dir" ]]; then
        local ck
        ck="$(du -sk "$cache_dir" 2>/dev/null | cut -f1)"
        ck="${ck:-0}"
        local cname="pibox-$env_name"
        if [[ "$ck" -ge $((300 * 1024)) ]]; then
            if [[ "$fix" == "1" ]] &&
                docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname" &&
                docker exec "$cname" npm cache clean --force >/dev/null 2>&1; then
                d_ok "npm-кэш очищен в контейнере ($cname)"
            else
                d_warn "npm-кэш раздут: ~$(human_kb "$ck") — чистка (при запущенном контейнере): docker exec $cname npm cache clean --force"
            fi
        else
            d_ok "npm-кэш: ~$(human_kb "$ck")"
        fi
    fi

    # D8: контейнер окружения
    local cname="pibox-$env_name"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        d_ok "контейнер $cname запущен"
    else
        d_info "контейнер $cname не запущен (это нормально; запуск: pibox run -e $env_name)"
    fi

    # D9: расширения — сверка окружения с манифестом env/extensions.txt
    # (нужен jq; без него проверка пропускается). Три вида расхождений:
    #   отсутствует пакет (WARN)  — установка: pibox extensions install
    #   версия не совпадает (WARN) — обновление той же командой
    #   пакет вне манифеста (INFO) — установлен вручную, pibox его не трогает
    # Расхождения с манифестом — не ошибки: свежее окружение без расширений —
    # нормальное состояние (doctor не должен падать с кодом 1).
    if ! command -v jq >/dev/null 2>&1; then
        d_info "jq не найден — сверка расширений с манифестом пропущена"
    else
        load_extensions_manifest
        if [[ ${#EXT_ENTRIES[@]} -eq 0 ]]; then
            d_info "манифест расширений пуст или отсутствует: $EXTENSIONS_FILE"
        elif [[ "$env_ok" == "1" ]]; then
            : # окружения нет — D4 уже сообщил, сверять не с чем
        else
            local m_entry m_have m_tot=0 m_miss=0 m_drift=0 manifest_err=0
            local -a manifest_names=() manifest_vers=()
            for m_entry in ${EXT_ENTRIES[@]+"${EXT_ENTRIES[@]}"}; do
                if parse_ext_entry "$m_entry"; then
                    manifest_names+=("$EXT_NAME")
                    manifest_vers+=("$EXT_VER")
                else
                    d_err "манифест: не удалось разобрать запись: $m_entry"
                    manifest_err=1
                fi
            done
            if [[ "$manifest_err" == "0" ]]; then
                local nm9="$env_dir/.pi/agent/npm/node_modules" i9 count9=${#manifest_names[@]}
                # установки pi добавляют запись и в settings.json; но пакет
                # может быть осознанно установлен без загрузки (напр. конфликт
                # memory-расширений — см. шапку манифеста), поэтому settings
                # проверяем только для пакетов, отсутствующих в node_modules:
                # их нет нигде — чинится одной командой extensions install.
                load_settings_packages "$env_dir/.pi/agent/settings.json"
                local -a set_missing=()
                for ((i9 = 0; i9 < count9; i9++)); do
                    m_tot=$((m_tot + 1))
                    m_have="$(get_installed_ext_version "$nm9" "${manifest_names[$i9]}")"
                    if [[ -z "$m_have" ]]; then
                        m_miss=$((m_miss + 1))
                        local short9="npm:${manifest_names[$i9]}" found9=0 sp9
                        for sp9 in ${EXT_SETTINGS_PACKAGES[@]+"${EXT_SETTINGS_PACKAGES[@]}"}; do
                            [[ "$sp9" == "$short9" || "$sp9" == "npm:${manifest_names[$i9]}@${manifest_vers[$i9]}" ]] && found9=1 && break
                        done
                        [[ "$found9" == "1" ]] || set_missing+=("$short9")
                    elif [[ "$m_have" != "${manifest_vers[$i9]}" ]]; then
                        m_drift=$((m_drift + 1))
                        d_warn "версия не совпадает: ${manifest_names[$i9]} — установлено ${m_have:-нет}, в манифесте ${manifest_vers[$i9]}"
                    fi
                done
                if [[ "$m_miss" -gt 0 ]]; then
                    d_warn "расширения: отсутствуют $m_miss из $m_tot (манифест $EXTENSIONS_FILE) — установка: pibox extensions install -e $env_name"
                elif [[ "$m_drift" -eq 0 ]]; then
                    d_ok "расширения: все $m_tot из манифеста установлены"
                else
                    d_warn "расширения: версии расходятся с манифестом в $m_drift пакетах — обновление: pibox extensions install -e $env_name"
                fi

                # Замыкание зависимостей: рекурсивно собираем deps (+optionalDeps)
                # всех пакетов из манифеста по установленным package.json.
                # needed_req — обязательные deps (их отсутствие = сломанная установка),
                # needed_any — включая optional (не обязаны быть на диске, но
                # не дают считать сам пакет «лишним»).
                # [bash3.2] Без ассоциативных массивов и отрицательных индексов:
                # pkg_*_* — параллельные индексированные массивы (имя/строка deps);
                # seen9/needed_req — списки слов в строке, поиск по « x ».
                local -a pkg_names=() pkg_req=() pkg_opt=()
                local pj9 rd9
                while IFS= read -r pj9; do
                    rd9="${pj9#"$nm9"/}"
                    rd9="${rd9%/package.json}"
                    pkg_names+=("$rd9")
                    pkg_req+=("$(jq -r '[.dependencies // {} | keys[]] | join(" ")' "$pj9" 2>/dev/null)")
                    pkg_opt+=("$(jq -r '[.optionalDependencies // {} | keys[]] | join(" ")' "$pj9" 2>/dev/null)")
                done < <(find "$nm9" -mindepth 2 -maxdepth 3 -name package.json 2>/dev/null)

                local seen9="" needed_req="" q9 dep9
                local -a queue9=()
                for m9 in ${manifest_names[@]+"${manifest_names[@]}"}; do queue9+=("$m9"); done
                while [[ ${#queue9[@]} -gt 0 ]]; do
                    q9="${queue9[0]}"
                    queue9=("${queue9[@]:1}")
                    [[ " $seen9 " == *" $q9 "* ]] && continue
                    seen9+="$q9 "
                    # deps пакета q9 — из параллельных массивов
                    local q_req="" q_opt=""
                    local pi9
                    for ((pi9 = 0; pi9 < ${#pkg_names[@]}; pi9++)); do
                        [[ "${pkg_names[$pi9]}" == "$q9" ]] && {
                            q_req="${pkg_req[$pi9]}"
                            q_opt="${pkg_opt[$pi9]}"
                            break
                        }
                    done
                    for dep9 in $q_req $q_opt; do
                        [[ -z "$dep9" ]] && continue
                        [[ " $seen9 " == *" $dep9 "* ]] || queue9+=("$dep9")
                    done
                    for dep9 in $q_req; do
                        [[ -z "$dep9" ]] && continue
                        [[ " $needed_req " == *" $dep9 "* ]] || needed_req+="$dep9 "
                    done
                done

                # Сверка: установленное вне замыкания — «лишнее» (ручная
                # установка); обязательная зависимость, которой нет на диске —
                # сломанная установка.
                local -a extra_pkgs=() dep_missing=()
                for ((pi9 = 0; pi9 < ${#pkg_names[@]}; pi9++)); do
                    rd9="${pkg_names[$pi9]}"
                    [[ " $seen9 " == *" $rd9 "* ]] || extra_pkgs+=("$rd9")
                done
                for rd9 in $needed_req; do
                    [[ ! -f "$nm9/$rd9/package.json" ]] && dep_missing+=("$rd9")
                done
                if [[ ${#extra_pkgs[@]} -gt 0 ]]; then
                    d_info "вне манифеста и не зависимости (${#extra_pkgs[@]}): ${extra_pkgs[*]}"
                fi
                if [[ ${#dep_missing[@]} -gt 0 ]]; then
                    d_warn "сломанные зависимости (${#dep_missing[@]}): ${dep_missing[*]} — переустановка: pibox extensions install -e $env_name"
                fi

                # отсутствующие в node_modules и в settings.json (см. выше)
                if [[ ${#set_missing[@]} -gt 0 ]]; then
                    d_warn "в settings.json нет ${#set_missing[@]} пакетов (${set_missing[*]}) — чинит pibox extensions install -e $env_name"
                fi
            fi
        fi
    fi

    # Итог
    printf '\n'
    if [[ "$errors" -eq 0 && "$warnings" -eq 0 ]]; then
        printf 'Итог: всё в порядке\n'
    else
        printf 'Итог: ошибок: %d, предупреждений: %d\n' "$errors" "$warnings"
    fi
    [[ "$errors" -eq 0 ]]
}
