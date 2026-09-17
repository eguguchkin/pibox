#!/usr/bin/env bash
# ============================================================================
# PIBOX — установщик.
#
# Разворачивает рабочую инсталляцию в PIBOX_DIR (по умолчанию ~/pibox):
#   bin/pibox       CLI (копия run.sh)
#   docker/         build-контекст (Dockerfile, entrypoint.sh, .dockerignore)
#   env/.template/  шаблон для новых окружений (имя с точкой — glob '*' его не матчит,
#                   поэтому 'env list' и 'env remove' шаблон не видят)
#   env/            окружения (default создаётся из шаблона)
#   env/extensions.txt  манифест расширений pi (используется 'pibox extensions install')
#   models.json     конфиг моделей (копируется только если нет;
#                   НИКОГДА не перезаписывается — там API-ключи пользователя)
#
# Идемпотентность:
#   - bin/pibox, docker/ и env/.template/ перезаписываются ВСЕГДА:
#     установка = обновление, build-контекст — точное зеркало исходников
#   - env/* не трогается; с --force ВСЕ окружения удаляются
#     (default пересоздаётся из свежего шаблона)
#   - env/extensions.txt копируется только если отсутствует (пользователь
#     может редактировать свой набор расширений)
#
# Опции:
#   -d, --dir PATH     целевая директория (дефолт: ~/pibox или $PIBOX_DIR)
#   -f, --force        принудительное обновление существующих файлов
#   --no-path          не добавлять PIBOX_DIR/bin в PATH
#   --src PATH         директория исходников (дефолт: dirname $0)
#   -h, --help         справка
#   -V, --version      версия установщика
# ============================================================================

set -euo pipefail

VERSION="1.0.0"

# Дефолт берём из env, если задан, иначе ~/pibox.
# Опция -d перекроет это значение.
PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"

# --- Хелперы ---------------------------------------------------------------

log() { echo "==> pibox: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
err() { echo "pibox: error: $*" >&2; }
die() {
    err "$*"
    exit 1
}

usage() {
    cat <<EOF
pibox installer ${VERSION}

Использование:
    ./install.sh [OPTIONS]

Опции:
    -d, --dir PATH     целевая директория (дефолт: \$PIBOX_DIR или ~/pibox)
    -f, --force        удалить ВСЕ окружения (env/*) и пересоздать default
    --no-path          не добавлять PIBOX_DIR/bin в PATH
    --src PATH         директория исходников (дефолт: $(dirname "$0"))
    -h, --help         эта справка
    -V, --version      версия установщика

Примеры:
    ./install.sh                     # установка/обновление в ~/pibox
    ./install.sh -d /opt/pibox       # установка в /opt/pibox
    ./install.sh --force             # обновление + удаление всех окружений (env/*)
    PIBOX_DIR=~/my-pibox ./install.sh
EOF
}

# Проверяет, что у опции есть непустой аргумент, не начинающийся с '-'
require_arg() {
    local opt="$1"
    local val="${2-}"
    [[ -n "$val" ]] || die "Опция $opt требует непустое значение"
    [[ "$val" != -* ]] || die "Опция $opt требует значение, а не опцию: $val"
}

# Безопасное удаление внутри PIBOX_DIR.
# Отказывается удалять /, $HOME, системные каталоги и что-либо вне PIBOX_DIR.
safe_rm_rf() {
    local target="$1"
    [[ -n "$target" ]] || die "safe_rm_rf: пустой путь"
    [[ "$target" != "/" ]] || die "safe_rm_rf: отказ удалять /"
    case "$target" in
    "$HOME" | "$HOME/" | /usr | /usr/ | /etc | /etc/ | /var | /var/ | /bin | /bin/ | /sbin | /sbin/ | /opt | /opt/)
        die "safe_rm_rf: отказ удалять системный путь $target"
        ;;
    esac
    # Разрешаем только то, что лежит внутри PIBOX_DIR (не сам PIBOX_DIR)
    [[ "$target" == "$PIBOX_DIR"/* ]] ||
        die "safe_rm_rf: $target вне PIBOX_DIR ($PIBOX_DIR)"
    rm -rf -- "$target"
}

# --- Парсинг аргументов ----------------------------------------------------

FORCE=0
NO_PATH=0
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
    -d | --dir)
        [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
        require_arg "$1" "$2"
        PIBOX_DIR="$2"
        shift 2
        ;;
    -f | --force)
        FORCE=1
        shift
        ;;
    --no-path)
        NO_PATH=1
        shift
        ;;
    --src)
        [[ $# -ge 2 ]] || die "Опция $1 требует аргумент"
        require_arg "$1" "$2"
        [[ -d "$2" ]] || die "Директория исходников не найдена: $2"
        SRC_DIR="$(cd "$2" && pwd)" || die "Не могу прочитать --src: $2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -V | --version)
        echo "pibox installer ${VERSION}"
        exit 0
        ;;
    *)
        die "Неизвестная опция: $1"
        ;;
    esac
done

# Убираем trailing slash, но не превращаем PIBOX_DIR в пустую строку
while [[ "$PIBOX_DIR" != "/" && "$PIBOX_DIR" == */ ]]; do
    PIBOX_DIR="${PIBOX_DIR%/}"
done

# --- Проверки ---------------------------------------------------------------

# 0. Sanity-check целевой директории
check_target_dir() {
    [[ -n "$PIBOX_DIR" ]] || die "PIBOX_DIR не может быть пустым"

    case "$PIBOX_DIR" in
    / | "$HOME" | "$HOME/" | /usr | /usr/ | /etc | /etc/ | /var | /var/ | /bin | /bin/ | /sbin | /sbin/ | /opt | /opt/)
        die "Отказываюсь устанавливать в $PIBOX_DIR"
        ;;
    esac
}

# 1. Проверка bash
if ! command -v bash >/dev/null 2>&1; then
    die "bash не найден. Установите bash >= 4.0"
fi

# 2. Проверка Docker >= 20.10
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"
    fi

    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1,2)
    if [[ -z "$docker_version" ]]; then
        die "Не могу определить версию Docker. Docker daemon запущен?"
    fi

    # Разбираем major.minor как числа и сравниваем с 20.10
    local major="${docker_version%%.*}"
    local minor="0"
    if [[ "$docker_version" == *.* ]]; then
        minor="${docker_version#*.}"
        minor="${minor%%.*}"
    fi

    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        die "Не удалось разобрать версию Docker: '${docker_version}'"
    fi

    if ((major < 20 || (major == 20 && minor < 10))); then
        die "Требуется Docker >= 20.10 (найдено: ${docker_version}). Обновите Docker."
    fi

    log "Docker ${docker_version} OK"
}

# 3. Проверка прав на запись
check_write_access() {
    if [[ ! -d "$PIBOX_DIR" ]]; then
        if ! mkdir -p "$PIBOX_DIR" 2>/dev/null; then
            die "Не могу создать директорию: ${PIBOX_DIR}. Проверьте права."
        fi
    fi

    if [[ ! -w "$PIBOX_DIR" ]]; then
        die "Нет прав на запись в: ${PIBOX_DIR}"
    fi
}

# 4. Проверка исходников
check_sources() {
    local required_files=(
        "run.sh"
        "Dockerfile"
        "entrypoint.sh"
        ".dockerignore"
        "models.json"
        "env/.template/README.md"
        "env/extensions.txt"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$SRC_DIR/$file" ]]; then
            die "Отсутствует обязательный файл: $SRC_DIR/$file"
        fi
    done
}

# --- Установка ---------------------------------------------------------------

install() {
    local target_bin="$PIBOX_DIR/bin"
    local target_docker="$PIBOX_DIR/docker"
    local target_env_template="$PIBOX_DIR/env/.template"
    local target_env="$PIBOX_DIR/env"
    local target_models="$PIBOX_DIR/models.json"

    log "Установка pibox в: ${PIBOX_DIR}"

    # 1. Создание структуры директорий
    mkdir -p "$target_bin" "$target_docker" "$target_env_template" "$target_env"

    # 2. Копирование CLI (run.sh → bin/pibox) — всегда: установка = обновление
    log "Копирую CLI: run.sh → bin/pibox"
    cp "$SRC_DIR/run.sh" "$target_bin/pibox"
    chmod 755 "$target_bin/pibox"

    # 3. Build-контекст — всегда точное зеркало исходников (сборка должна
    # соответствовать репо; чужие/устаревшие файлы в docker/ не выживают)
    log "Обновляю build-контекст в docker/"
    safe_rm_rf "$target_docker"
    mkdir -p "$target_docker"
    for file in Dockerfile entrypoint.sh .dockerignore; do
        log "Копирую: $file → docker/"
        cp "$SRC_DIR/$file" "$target_docker/"
    done

    # 4. --force: удалить ВСЕ окружения (env/*). Без --force не трогаем.
    #    ВАЖНО: строго ДО обновления env/.template — зачистка сносит весь env/,
    #    включая шаблон; если делать наоборот, шаг 6 упадёт с «cp: cannot stat
    #    .../env/.template/.» (env/default останется пустым, CLI-тесты красные).
    if ((FORCE == 1)); then
        warn "--force: удаляю ВСЕ окружения в ${target_env} (включая default)"
        safe_rm_rf "$target_env"
    fi
    mkdir -p "$target_env"

    # 5. Шаблон окружения — всегда свежий из исходников
    log "Обновляю env/.template/"
    safe_rm_rf "$target_env_template"
    mkdir -p "$target_env_template"
    cp -a "$SRC_DIR/env/.template/." "$target_env_template/"

    # 6. Создание default окружения (если не существует)
    if [[ ! -d "$target_env/default" ]]; then
        log "Создаю окружение default из шаблона"
        mkdir -p "$target_env/default"
        cp -a "$target_env_template/." "$target_env/default/"
    else
        log "Окружение default уже существует — пропускаю создание"
    fi

    # 7. Манифест расширений — в env/ (копируется ТОЛЬКО если отсутствует:
    #    пользователь вправе редактировать свой набор; sed '-i' не нужен —
    #    файл маленький и одноразовый)
    if [[ ! -f "$target_env/extensions.txt" ]]; then
        log "Копирую манифест расширений: extensions.txt → env/"
        cp "$SRC_DIR/env/extensions.txt" "$target_env/extensions.txt"
    else
        log "Манифест env/extensions.txt уже существует — не трогаю"
    fi

    # 8. models.json — не перезаписывается НИКОГДА (API-ключи пользователя):
    #    копируется только если отсутствует
    if [[ ! -f "$target_models" ]] && [[ -f "$SRC_DIR/models.json" ]]; then
        log "Копирую models.json → models.json"
        cp "$SRC_DIR/models.json" "$target_models"

        warn "Не забудьте отредактировать ${target_models} и указать ваши API-ключи."
    fi

    # 9. Добавление в PATH
    if ((NO_PATH == 0)); then
        add_to_path
    fi

    log "Установка завершена успешно!"
    log "Следующие шаги:"
    log "  1. Отредактируйте ${target_models} (укажите API-ключи)"
    log "  2. Соберите образ: pibox build"
    log "  3. Установите набор расширений: pibox extensions install   (несколько минут)"
    log "     (опционально: поправьте свой набор в ${target_env}/extensions.txt)"
    log "  4. Запустите агента: cd ~/your-project && pibox"
}

# --- Добавление в PATH ---------------------------------------------------

add_to_path() {
    local shell_rc=""
    local shell_name="${SHELL##*/}"

    case "$shell_name" in
    bash)
        shell_rc="$HOME/.bashrc"
        ;;
    zsh)
        shell_rc="$HOME/.zshrc"
        ;;
    fish)
        warn "Fish shell обнаружен. Добавьте вручную: fish_add_path ${PIBOX_DIR}/bin"
        return 0
        ;;
    *)
        warn "Неизвестный shell: ${shell_name}. Добавьте ${PIBOX_DIR}/bin в PATH вручную."
        return 0
        ;;
    esac

    # Проверка: если такой путь уже прописан — не дублируем
    if grep -qF "$PIBOX_DIR/bin" "$shell_rc" 2>/dev/null; then
        log "PATH уже содержит ${PIBOX_DIR}/bin"
        return 0
    fi

    # Добавление в начало PATH (prepend), с guard-комментарием
    log "Добавляю ${PIBOX_DIR}/bin в PATH (${shell_rc})"

    {
        echo ""
        echo "# >>> pibox installer >>>"
        echo "export PATH=\"${PIBOX_DIR}/bin:\$PATH\""
        echo "# <<< pibox installer <<<"
    } >>"$shell_rc"

    warn "PATH обновлён. Перезапустите shell или выполните: source ${shell_rc}"
}

# --- Основной блок -----------------------------------------------------------

main() {
    check_target_dir
    check_docker
    check_write_access
    check_sources
    install
}

main "$@"
