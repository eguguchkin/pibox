# Задача 7 — `install.sh` (Установщик на хост)

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent. Установщик разворачивает рабочую инсталляцию в `PIBOX_DIR` (по умолчанию `~/pibox`): CLI-скрипт, build-контекст образа, шаблон окружения, первичное окружение и конфиг моделей. |
| **Цель задачи** | Реализовать идемпотентный установщик `install.sh` с опциями, проверками зависимостей и сохранением пользовательских окружений при обновлении. |
| **Зависимости** | Задача 6 (CLI `run.sh` с плейсхолдером `__PIBOX_DIR__`), задача 4 (`env-template`), задача 3 (`Dockerfile` и `entrypoint.sh`) |
| **Артефакты** | `install.sh` — полная реализация, заменяющая заглушку из задачи 2 |
| **Не входит в задачу** | Тесты (задача 8), документация (задача 9) |

---

## 🏗️ Ключевые архитектурные решения

| # | Решение | Обоснование |
|---|---|---|
| 1 | **Идемпотентность через `-f` (force) и проверки существования** | Повторный запуск без `--force` не перезаписывает существующие файлы; `--force` обновляет шаблоны и CLI, но не трогает пользовательские окружения |
| 2 | **Подстановка `__PIBOX_DIR__` в `run.sh` через `sed`** | Уникальный плейсхолдер, не встречающийся в обычном тексте; избегаем конфликтов с `$` в путях |
| 3 | **Копирование `models.json` только если отсутствует** | Пользователь мог настроить ключи; `--force` перезаписывает с предупреждением |
| 4 | **PATH-обновление с защитой от дублей** | Добавление в `~/.bashrc` или `~/.zshrc` только если строки ещё нет; guard по маркеру |
| 5 | **Проверка Docker ≥ 20.10** | Критично для `--add-host host.docker.internal:host-gateway` 【turn0search5】【turn0search6】 |

---

## 1. Полный код `install.sh`

```bash
#!/usr/bin/env bash
# ============================================================================
# PIBOX — установщик.
#
# Разворачивает рабочую инсталляцию в PIBOX_DIR (по умолчанию ~/pibox):
#   bin/pibox       CLI (исходник run.sh с подстановкой __PIBOX_DIR__)
#   docker/         build-контекст (Dockerfile, entrypoint.sh, .dockerignore)
#   env-template/   шаблон для новых окружений
#   env/            окружения (default создаётся из шаблона)
#   env/models.json конфиг моделей (копируется, если нет)
#
# Идемпотентность:
#   - Повторный запуск без --force не перезаписывает существующие файлы
#   - --force обновляет CLI, docker/, env-template/ (но НЕ env/*)
#   - env/default создаётся только если отсутствует
#   - models.json копируется только если отсутствует (или с --force)
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
DEFAULT_PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"

# --- Хелперы ---------------------------------------------------------------

log()  { echo "==> pibox: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
err()  { echo "pibox: error: $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
pibox installer ${VERSION}

Использование:
    ./install.sh [OPTIONS]

Опции:
    -d, --dir PATH     целевая директория (дефолт: \$PIBOX_DIR или ~/pibox)
    -f, --force        принудительное обновление существующих файлов
    --no-path          не добавлять PIBOX_DIR/bin в PATH
    --src PATH         директория исходников (дефолт: $(dirname "$0"))
    -h, --help         эта справка
    -V, --version      версия установщика

Примеры:
    ./install.sh                     # установка в ~/pibox
    ./install.sh -d /opt/pibox       # установка в /opt/pibox
    ./install.sh --force             # обновление существующей установки
    PIBOX_DIR=~/my-pibox ./install.sh
EOF
}

# --- Парсинг аргументов ----------------------------------------------------

PIBOX_DIR=""
FORCE=0
NO_PATH=0
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            PIBOX_DIR="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --no-path)
            NO_PATH=1
            shift
            ;;
        --src)
            SRC_DIR="$(cd "$2" && pwd)" || die "Не могу прочитать --src: $2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -V|--version)
            echo "pibox installer ${VERSION}"
            exit 0
            ;;
        *)
            die "Неизвестная опция: $1"
            ;;
    esac
done

# Дефолтный PIBOX_DIR если не указан
PIBOX_DIR="${PIBOX_DIR:-$DEFAULT_PIBOX_DIR}"

# --- Проверки ---------------------------------------------------------------

# 1. Проверка bash
if ! command -v bash >/dev/null 2>&1; then
    die "bash не найден. Установите bash >= 4.0"
fi

# 2. Проверка Docker >= 20.10
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"
    fi

    # Проверка версии (20.10+)
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1,2)
    if [[ -z "$docker_version" ]]; then
        die "Не могу определить версию Docker. Docker daemon запущен?"
    fi

    # Сравнение версий (20.10 = 2010, 24.04 = 2404 и т.д.)
    local docker_num
    docker_num=$(echo "$docker_version" | tr -d '.')
    if (( docker_num < 2010 )); then
        die "Требуется Docker >= 20.10 (найдено: ${docker_version}). Обновите Docker."
    fi

    log "Docker ${docker_version} OK"
}

# 3. Проверка прав на запись
check_write_access() {
    if [[ ! -d "$PIBOX_DIR" ]]; then
        # Пытаемся создать директорию
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
        "install.sh"
        "Dockerfile"
        "entrypoint.sh"
        ".dockerignore"
        "models.json"
        "env-template/README.md"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$SRC_DIR/$file" ]]; then
            die "Отсутствует обязательный файл: $SRC_DIR/$file"
        fi
    done

    # Проверка структуры env-template
    if [[ ! -d "$SRC_DIR/env-template/.pi/agent" ]]; then
        die "Некорректная структура env-template. Отсутствует: .pi/agent"
    fi
}

# --- Установка ---------------------------------------------------------------

install() {
    local target_bin="$PIBOX_DIR/bin"
    local target_docker="$PIBOX_DIR/docker"
    local target_env_template="$PIBOX_DIR/env-template"
    local target_env="$PIBOX_DIR/env"
    local target_models="$PIBOX_DIR/env/models.json"

    log "Установка pibox в: ${PIBOX_DIR}"

    # 1. Создание структуры директорий
    mkdir -p "$target_bin" "$target_docker" "$target_env_template" "$target_env"

    # 2. Копирование CLI (run.sh → bin/pibox) с подстановкой
    if [[ -f "$target_bin/pibox" ]] && (( FORCE == 0 )); then
        warn "bin/pibox уже существует. Используйте --force для обновления."
    else
        log "Копирую CLI: run.sh → bin/pibox"
        # Подстановка __PIBOX_DIR__ на реальный путь
        # Используем # как разделитель в sed, чтобы избежать конфликтов с / в путях
        sed "s#__PIBOX_DIR__#${PIBOX_DIR}#g" "$SRC_DIR/run.sh" > "$target_bin/pibox"
        chmod 755 "$target_bin/pibox"
    fi

    # 3. Копирование build-контекста
    if (( FORCE == 1 )); then
        log "Обновляю build-контекст в docker/"
        rm -rf "$target_docker"
        mkdir -p "$target_docker"
    fi

    for file in Dockerfile entrypoint.sh .dockerignore; do
        if [[ ! -f "$target_docker/$file" ]] || (( FORCE == 1 )); then
            log "Копирую: $file → docker/"
            cp "$SRC_DIR/$file" "$target_docker/"
        fi
    done

    # 4. Копирование env-template
    if (( FORCE == 1 )); then
        log "Обновляю env-template/"
        rm -rf "$target_env_template"
        cp -a "$SRC_DIR/env-template" "$target_env_template"
    else
        if [[ ! -d "$target_env_template/.pi" ]]; then
            log "Копирую env-template/"
            cp -a "$SRC_DIR/env-template" "$target_env_template"
        fi
    fi

    # 5. Создание default окружения (если не существует)
    if [[ ! -d "$target_env/default" ]]; then
        log "Создаю окружение default из шаблона"
        cp -a "$target_env_template" "$target_env/default"
    else
        log "Окружение default уже существует — пропускаю создание"
    fi

    # 6. Копирование models.json (если не существует или force)
    if [[ ! -f "$target_models" ]] || (( FORCE == 1 )); then
        if [[ -f "$SRC_DIR/models.json" ]]; then
            log "Копирую models.json → env/models.json"
            cp "$SRC_DIR/models.json" "$target_models"

            # Предупреждение о необходимости настройки
            warn "Не забудьте отредактировать ${target_models} и указать ваши API-ключи."
        fi
    fi

    # 7. Добавление в PATH
    if (( NO_PATH == 0 )); then
        add_to_path
    fi

    # 8. Создание маркера установки
    echo "Installed: $(date)" > "$PIBOX_DIR/.pibox_installed"

    log "Установка завершена успешно!"
    log "Следующие шаги:"
    log "  1. Отредактируйте ${target_models} (укажите API-ключи)"
    log "  2. Соберите образ: pibox build"
    log "  3. Запустите агента: cd ~/your-project && pibox"
}

# --- Добавление в PATH ---------------------------------------------------

add_to_path() {
    local shell_rc=""
    local shell_name="${SHELL##*/}"

    # Определяем rc-файл текущего шелла
    case "$shell_name" in
        bash)
            shell_rc="$HOME/.bashrc"
            ;;
        zsh)
            shell_rc="$HOME/.zshrc"
            ;;
        fish)
            warn "Fish shell обнаружен. Добавьте вручную: set -gx PATH $PIBOX_DIR/bin \$PATH"
            return 0
            ;;
        *)
            warn "Неизвестный shell: ${shell_name}. Добавьте $PIBOX_DIR/bin в PATH вручную."
            return 0
            ;;
    esac

    # Проверка, если уже есть в PATH
    if grep -q "PIBOX_DIR/bin" "$shell_rc" 2>/dev/null; then
        log "PATH уже содержит ${PIBOX_DIR}/bin"
        return 0
    fi

    # Добавление в PATH с guard-комментарием
    log "Добавляю ${PIBOX_DIR}/bin в PATH (${shell_rc})"

    {
        echo ""
        echo "# >>> pibox installer >>>"
        echo "export PATH=\"\$PATH:${PIBOX_DIR}/bin\""
        echo "# <<< pibox installer <<<"
    } >> "$shell_rc"

    warn "PATH обновлён. Перезапустите shell или выполните: source ${shell_rc}"
}

# --- Основной блок -----------------------------------------------------------

main() {
    # Проверки
    check_docker
    check_write_access
    check_sources

    # Установка
    install
}

main "$@"
```

---

## 2. Разбор ключевых функций

### 2.1 Проверка Docker версии

```bash
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"
    fi

    # Проверка версии (20.10+)
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1,2)
    if [[ -z "$docker_version" ]]; then
        die "Не могу определить версию Docker. Docker daemon запущен?"
    fi

    # Сравнение версий (20.10 = 2010, 24.04 = 2404 и т.д.)
    local docker_num
    docker_num=$(echo "$docker_version" | tr -d '.')
    if (( docker_num < 2010 )); then
        die "Требуется Docker >= 20.10 (найдено: ${docker_version}). Обновите Docker."
    fi

    log "Docker ${docker_version} OK"
}
```

**Почему это важно:** Docker 20.10+ требуется для поддержки `--add-host host.docker.internal:host-gateway`, который критичен для доступа к сервисам на хосте из контейнера 【turn0search5】【turn0search6】.

### 2.2 Подстановка `__PIBOX_DIR__` в CLI

```bash
sed "s#__PIBOX_DIR__#${PIBOX_DIR}#g" "$SRC_DIR/run.sh" > "$target_bin/pibox"
```

**Почему `#` как разделитель:** Пути могут содержать `/` (например, `/home/user/pibox`), что конфликтует с стандартным разделителем `/` в `sed`. Использование `#` избегает этой проблемы.

### 2.3 Идемпотентность

```bash
if [[ -f "$target_bin/pibox" ]] && (( FORCE == 0 )); then
    warn "bin/pibox уже существует. Используйте --force для обновления."
else
    # Копирование
fi
```

**Логика:**
- Без `--force`: существующие файлы пропускаются
- С `--force`: файлы обновляются (кроме пользовательских окружений в `env/*`)

---

## 3. Тестирование установщика

### 3.1 Предварительные условия

```bash
# 1. Подготовка тестового окружения
TEST_DIR=$(mktemp -d /tmp/pibox-install-test-XXXXXX)
SRC_DIR=$(pwd)  # директория с исходниками

# 2. Установка в тестовую директорию
./install.sh --dir "$TEST_DIR" --no-path

# 3. Проверка структуры
tree "$TEST_DIR" || find "$TEST_DIR" -type f | sort

# Ожидаемая структура:
# $TEST_DIR/
# ├── bin/pibox
# ├── docker/
# │   ├── Dockerfile
# │   ├── entrypoint.sh
# │   └── .dockerignore
# ├── env-template/
# │   └── (содержимое из задачи 4)
# ├── env/
# │   ├── default/  (копия env-template)
# │   └── models.json
# └── .pibox_installed
```

### 3.2 Тест идемпотентности

```bash
# 1. Первый запуск (установка)
./install.sh --dir "$TEST_DIR" --no-path

# 2. Второй запуск (без --force)
./install.sh --dir "$TEST_DIR" --no-path

# 3. Проверка: файлы не перезаписаны (mtime не изменился)
BEFORE=$(stat -c %Y "$TEST_DIR/bin/pibox")
./install.sh --dir "$TEST_DIR" --no-path
AFTER=$(stat -c %Y "$TEST_DIR/bin/pibox")

if [[ "$BEFORE" == "$AFTER" ]]; then
    echo "PASS: повторная установка не изменила файл"
else
    echo "FAIL: файл был перезаписан"
fi

# 4. Запуск с --force
./install.sh --dir "$TEST_DIR" --no-path --force

# 5. Проверка: файлы обновлены
AFTER_FORCE=$(stat -c %Y "$TEST_DIR/bin/pibox")
if [[ "$AFTER" != "$AFTER_FORCE" ]]; then
    echo "PASS: --force обновил файл"
else
    echo "FAIL: --force не обновил файл"
fi
```

### 3.3 Тест PATH-обновления

```bash
# 1. Установка с обновлением PATH
./install.sh --dir "$TEST_DIR"

# 2. Проверка, что PATH содержит тестовую директорию
if echo "$PATH" | grep -q "$TEST_DIR/bin"; then
    echo "PASS: PATH обновлён"
else
    echo "FAIL: PATH не обновлён"
fi

# 3. Проверка, что в .bashrc есть guard
if grep -q ">>> pibox installer >>>" "$HOME/.bashrc"; then
    echo "PASS: guard в .bashrc"
else
    echo "FAIL: guard не найден"
fi

# 4. Повторная установка — не должно быть дублей
./install.sh --dir "$TEST_DIR"
if [[ $(grep -c ">>> pibox installer >>>" "$HOME/.bashrc") -eq 1 ]]; then
    echo "PASS: нет дублей в PATH"
else
    echo "FAIL: дубли в PATH"
fi
```

### 3.4 Тест обновления

```bash
# 1. Установка
./install.sh --dir "$TEST_DIR" --no-path

# 2. Изменение исходников
echo "# Test update" >> "$SRC_DIR/run.sh"

# 3. Обновление с --force
./install.sh --dir "$TEST_DIR" --no-path --force

# 4. Проверка, что изменения попали в установленную версию
if grep -q "# Test update" "$TEST_DIR/bin/pibox"; then
    echo "PASS: обновление применилось"
else
    echo "FAIL: обновление не применилось"
fi

# 5. Проверка, что env/default не затронут (если не было изменений в шаблоне)
# (env/default копируется только если отсутствует)
```

---

## 4. ✅ Критерии готовности

- [ ] `./install.sh --help` выводит справку
- [ ] `./install.sh --version` выводит версию
- [ ] Установка в дефолтную директорию (`~/pibox`) работает
- [ ] Установка в кастомную директорию (`-d`) работает
- [ ] Проверка Docker ≥ 20.10 работает
- [ ] Проверка прав на запись работает
- [ ] Проверка исходников работает (все обязательные файлы)
- [ ] Копирование CLI с подстановкой `__PIBOX_DIR__` работает
- [ ] Копирование build-контекста (`docker/`) работает
- [ ] Копирование `env-template` работает
- [ ] Создание `env/default` из шаблона работает
- [ ] Копирование `models.json` (если отсутствует) работает
- [ ] PATH-обновление с guard работает (без дублей)
- [ ] Идемпотентность: повторный запуск без `--force` не меняет файлы
- [ ] Идемпотентность: `--force` обновляет CLI, docker/, env-template, но не env/
- [ ] `shellcheck install.sh` проходит без замечаний

---

## 5. ⚠️ Подводные камни

| # | Проблема | Решение |
|---|---|---|
| 1 | **Подстановка путей с `/` в `sed`** | Использование `#` как разделителя в `sed` |
| 2 | **Права на запись в целевую директорию** | Проверка `[[ ! -w "$PIBOX_DIR" ]]` перед началом |
| 3 | **Повторная установка ломает PATH** | Guard-комментарии и проверка на существование |
| 4 | **Обновление перезаписывает пользовательские окружения** | `env/*` никогда не трогаем; `env/default` создаём только если отсутствует |
| 5 | **Docker < 20.10 не поддерживает host-gateway** | Явная проверка версии с понятной ошибкой |
| 6 | **Отсутствие обязательных файлов в исходниках** | Проверка `check_sources` перед началом |
| 7 | **Fish shell не поддерживает `export PATH=`** | Отдельная ветка с предупреждением и ручной инструкцией |

---

## 6. 🔗 Контракты, зафиксированные задачей 7

### Входные данные (опции CLI)

| Опция | Дефолт | Описание |
|---|---|---|
| `-d, --dir PATH` | `~/pibox` или `$PIBOX_DIR` | Целевая директория установки |
| `-f, --force` | `false` | Принудительное обновление существующих файлов |
| `--no-path` | `false` | Не добавлять `PIBOX_DIR/bin` в PATH |
| `--src PATH` | `dirname $0` | Директория с исходниками |

### Выходные данные (структура PIBOX_DIR)

```
PIBOX_DIR/
├── bin/
│   └── pibox              # CLI с подстановкой путей
├── docker/
│   ├── Dockerfile         # Build-контекст
│   ├── entrypoint.sh
│   └── .dockerignore
├── env-template/          # Шаблон для новых окружений
├── env/
│   ├── default/           # Первичное окружение (копия шаблона)
│   └── models.json        # Конфиг моделей (копируется, если нет)
└── .pibox_installed       # Маркер установки
```

### Контракт с задачей 6 (run.sh)

```bash
# В исходнике run.sh:
PIBOX_DIR="${PIBOX_DIR:-__PIBOX_DIR__}"

# После установки (в bin/pibox):
PIBOX_DIR="${PIBOX_DIR:-/home/user/pibox}"
```

**Что получают следующие задачи:**

| Задача | Получает |
|---|---|
| **8 (тесты)** | Установщик для создания тестовых окружений; проверку идемпотентности |
| **9 (README)** | Команды установки для документации; примеры использования |