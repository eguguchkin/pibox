# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Манифест расширений ---------------------------------------------------------

EXTENSIONS_FILE="env/extensions.txt"

# Читает манифест расширений (строки вида npm:имя@версия).
# Заполняет глобальный массив EXT_ENTRIES; при отсутствии файла — пустой.
load_extensions_manifest() {
    local manifest="$PIBOX_DIR/$EXTENSIONS_FILE"
    EXT_ENTRIES=()
    [[ -f "$manifest" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* ]] && continue # строка-комментарий целиком
        line="${line%\#*}"               # хвостовой комментарий
        # нормализуем пробелы по краям
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        EXT_ENTRIES+=("$line")
    done <"$manifest"
}

# Разбирает запись "npm:имя@версия" -> EXT_NAME, EXT_VER.
# Возвращает 1, если запись не разобрана.
parse_ext_entry() {
    EXT_NAME=""
    EXT_VER=""
    local entry="$1"
    [[ "$entry" == npm:* ]] || return 1
    local body="${entry#npm:}"
    EXT_VER="${body##*@}"
    EXT_NAME="${body%@*}"
    [[ -n "$EXT_NAME" && -n "$EXT_VER" ]] || return 1
    local bare="${EXT_NAME#@}" # scope-пакеты (@scope/name) допустимы, @ внутри имени — нет
    [[ "$bare" != *@* ]] || return 1
}

# Читает список пакетов из settings.json окружения (jq).
# Заполняет EXT_SETTINGS_PACKAGES.
load_settings_packages() {
    local settings="$1"
    EXT_SETTINGS_PACKAGES=()
    [[ -f "$settings" ]] || return 0
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        EXT_SETTINGS_PACKAGES+=("$p")
    done < <(jq -r '.packages[]?' "$settings" 2>/dev/null)
}

# Установленная версия npm-пакета в env (пусто, если не установлен).
# $1 - каталог node_modules, $2 - имя пакета (со scope).
get_installed_ext_version() {
    local nm="$1" name="$2" pj
    pj="$nm/$name/package.json"
    [[ -f "$pj" ]] || {
        printf ''
        return
    }
    jq -r '.version // empty' "$pj" 2>/dev/null || printf ''
}
