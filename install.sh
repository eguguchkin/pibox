#!/usr/bin/env bash
# ============================================================================
# PIBOX — установщик.
#
# Разворачивает рабочую инсталляцию в PIBOX_DIR (по умолчанию ~/pibox):
#   bin/pibox       CLI — точка входа (подгружает lib/)
#   lib/            модули CLI (копируются целиком, зеркало исходников)
#   docker/         build-контекст (Dockerfile, entrypoint.sh, .dockerignore)
#   template/common/  СЛОЙ 1: продукт — начальное состояние окружений
#                     (перезаписывается ВСЕГДА: установка = обновление)
#   template/user/    СЛОЙ 2: личные инварианты владельца (models.json,
#                     USER.md, личные расширения/скиллы/конфиги) —
#                     копируется АДДИТИВНО: существующее не трогается
#   template/extensions.txt  манифест расширений pi (используется
#                     'pibox extensions install')
#   env/            окружения (default создаётся из шаблонов)
#
# Идемпотентность:
#   - bin/pibox + lib/, docker/, template/common/ и template/extensions.txt
#     перезаписываются ВСЕГДА: установка = обновление, build-контекст —
#     точное зеркало исходников
#   - template/user/ копируется аддитивно (cp -rn): новые заглушки доезжают,
#     правки владельца не перезаписываются НИКОГДА — там могут быть ключи
#   - env/* не трогается; с --force ВСЕ окружения удаляются
#     (default пересоздаётся из свежих шаблонов)
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

# 1. Проверка bash (достаточно 3.2 — дефолтный macOS bash; код CLI/тестов
# написан без bash4+ конструкций: без ассоц. массивов и отрицательных индексов)
if ! command -v bash >/dev/null 2>&1; then
    die "bash не найден"
fi
if [ "$((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))" -lt 302 ]; then
    die "требуется bash >= 3.2 (найдено ${BASH_VERSION})"
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
        "bin/pibox"
        "lib/common.sh"
        "lib/docker-cmd.sh"
        "lib/cmd-build.sh"
        "lib/cmd-doctor.sh"
        "lib/cmd-env.sh"
        "lib/cmd-extensions.sh"
        "lib/cmd-run.sh"
        "lib/cmd-webui.sh"
        "lib/cmd-update.sh"
        "lib/env.sh"
        "lib/layers.sh"
        "lib/cmd-user.sh"
        "lib/ext-manifest.sh"
        "lib/ext-progress.sh"
        "lib/main.sh"
        "Dockerfile"
        "entrypoint.sh"
        "webui.sh"
        ".dockerignore"
        "template/README.md"
        "template/extensions.txt"
        "template/common/.pi/agent/AGENTS.md"
        "template/user/.pi/agent/models.json"
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
    local target_template="$PIBOX_DIR/template"
    local target_env="$PIBOX_DIR/env"

    log "Установка pibox в: ${PIBOX_DIR}"

    # 1. Создание структуры директорий
    mkdir -p "$target_bin" "$target_docker" "$target_template" "$target_env"

    # 2. Копирование CLI (bin/pibox + lib/) — всегда: установка = обновление
    log "Копирую CLI: bin/pibox + lib/"
    cp "$SRC_DIR/bin/pibox" "$target_bin/pibox"
    chmod 755 "$target_bin/pibox"
    # lib/ — точное зеркало исходников (чужие/устаревшие модули не выживают)
    safe_rm_rf "$PIBOX_DIR/lib"
    mkdir -p "$PIBOX_DIR/lib"
    cp "$SRC_DIR"/lib/*.sh "$PIBOX_DIR/lib/"

    # 3. Build-контекст — всегда точное зеркало исходников (сборка должна
    # соответствовать репо; чужие/устаревшие файлы в docker/ не выживают)
    log "Обновляю build-контекст в docker/"
    safe_rm_rf "$target_docker"
    mkdir -p "$target_docker"
    for file in Dockerfile entrypoint.sh webui.sh .dockerignore; do
        log "Копирую: $file → docker/"
        cp "$SRC_DIR/$file" "$target_docker/"
    done

    # 4. --force: удалить ВСЕ окружения (env/*). Без --force не трогаем.
    if ((FORCE == 1)); then
        warn "--force: удаляю ВСЕ окружения в ${target_env} (включая default)"
        safe_rm_rf "$target_env"
    fi
    mkdir -p "$target_env"

    # 5. СЛОЙ 1 (template/common) — всегда свежий из исходников.
    #    Применяется к окружению один раз, при создании (create_env).
    log "Обновляю template/common/ (слой 1: начальное состояние)"
    safe_rm_rf "$target_template/common"
    mkdir -p "$target_template/common"
    cp -a "$SRC_DIR/template/common/." "$target_template/common/"

    # 6. СЛОЙ 2 (template/user) — АДДИТИВНО (cp -Rn): новые заглушки доезжают,
    #    существующие файлы владельца (в т.ч. ключи) не перезаписываются.
    #    Применяется к окружению при каждом запуске (apply_user_layer).
    if [[ -d "$SRC_DIR/template/user" ]]; then
        log "Копирую template/user/ аддитивно (слой 2: личные инварианты)"
        mkdir -p "$target_template/user"
        cp -Rn "$SRC_DIR/template/user/." "$target_template/user/"
    fi

    # 7. Манифест расширений и README — всегда из исходников
    cp "$SRC_DIR/template/extensions.txt" "$target_template/extensions.txt"
    cp "$SRC_DIR/template/README.md" "$target_template/README.md"

    # 8. Создание default окружения (если не существует)
    if [[ ! -d "$target_env/default" ]]; then
        log "Создаю окружение default из шаблонов"
        mkdir -p "$target_env/default"
        cp -a "$target_template/common/." "$target_env/default/"
        # заглушки слоя 2 — как при обычном запуске (аддитивно)
        cp -Rn "$target_template/user/." "$target_env/default/" 2>/dev/null || true
    else
        log "Окружение default уже существует — пропускаю создание"
    fi

    # 9. Добавление в PATH
    if ((NO_PATH == 0)); then
        add_to_path
    fi

    log "Установка завершена успешно!"
    log "Следующие шаги:"
    log "  1. Укажите API-ключи: ${target_template}/user/.pi/agent/models.json"
    log "  2. Соберите образ: pibox build"
    log "  3. Установите набор расширений: pibox extensions install   (несколько минут)"
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
