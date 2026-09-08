
Ниже представлена полная реализация **Задачи 4**. 

Скрипт `bin/pibox` — это главный интерфейс пользователя. Он отвечает за безопасность запуска (проверку рабочей директории), автоматическое создание окружений и формирование сложной команды `docker run` со всеми необходимыми монтированиями, правами и сетевыми настройками.

### 📂 1. Структура файлов для этого этапа
В корне репозитория должен находиться:
```text
pibox-repo/
└── bin/
    └── pibox          # CLI-скрипт (реализация ниже)
```

---

### 💻 2. Листинг файла

#### `bin/pibox`
Создайте файл со следующим содержимым и обязательно сделайте его исполняемым (`chmod +x bin/pibox`).

```bash
#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# PIBOX CLI
# Единственная точка входа для управления окружениями
# и запуска агента в Docker-контейнере.
# ==========================================================

# --- Конфигурация ---
# Определяем PIBOX_DIR. Если не задано, используем ~/pibox
PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"
DEFAULT_ENV="default"
IMAGE_NAME="pibox-base:latest"

# --- Переменные для аргументов ---
ENV_NAME="$DEFAULT_ENV"
PORTS=()
GIT_SAFE=0
AGENT_ARGS=()

# --- Проверка зависимостей ---
if ! command -v docker &> /dev/null; then
    echo "❌ ERROR: Docker is not installed or not in PATH."
    exit 1
fi

# --- Парсинг аргументов ---
# Мы разделяем флаги самого скрипта (например, --env, -p)
# и аргументы, которые предназначены для агента внутри контейнера.
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                ENV_NAME="$2"
                shift 2
            else
                echo "❌ ERROR: --env requires a value."
                exit 1
            fi
            ;;
        -p|--port)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                PORTS+=("$2")
                shift 2
            else
                echo "❌ ERROR: $1 requires a value."
                exit 1
            fi
            ;;
        --git-safe)
            GIT_SAFE=1
            shift
            ;;
        --)
            # Явный разделитель: всё, что идет после --, передается агенту
            shift
            break
            ;;
        *)
            # Если аргумент не распознан как флаг, считаем, что дальше
            # идут аргументы агента (например, имя команды или флаги агента).
            break
            ;;
    esac
done

# Всё, что осталось, передаем агенту
AGENT_ARGS=("$@")

# --- Проверка безопасности рабочей директории ---
# Получаем абсолютные пути. Используем realpath или readlink -f для совместимости.
if command -v realpath &> /dev/null; then
    WS_DIR=$(realpath "$PWD")
    PIBOX_REAL=$(realpath "$PIBOX_DIR")
else
    WS_DIR=$(readlink -f "$PWD")
    PIBOX_REAL=$(readlink -f "$PIBOX_DIR")
fi

# Проверка на вложенность:
# Если WS_DIR находится внутри PIBOX_DIR или наоборот — прерываем запуск.
if [[ "$WS_DIR" == "$PIBOX_REAL" || "$WS_DIR" == "$PIBOX_REAL"/* ]]; then
    echo "❌ ERROR: Workspace ($WS_DIR) is inside PIBOX_DIR ($PIBOX_REAL)."
    echo "   Please run pibox from a different directory."
    exit 1
fi

if [[ "$PIBOX_REAL" == "$WS_DIR" || "$PIBOX_REAL" == "$WS_DIR"/* ]]; then
    echo "❌ ERROR: PIBOX_DIR ($PIBOX_REAL) is inside Workspace ($WS_DIR)."
    echo "   Please run pibox from a different directory."
    exit 1
fi

echo "=================================================="
echo " 🚀 PIBOX Launcher"
echo "=================================================="
echo "   Environment: $ENV_NAME"
echo "   Workspace:   $WS_DIR"
echo "   PIBOX_DIR:   $PIBOX_REAL"
echo "--------------------------------------------------"

# --- Инициализация окружения ---
ENV_PATH="$PIBOX_REAL/env/$ENV_NAME"
ENV_TEMPLATE="$PIBOX_REAL/env-template"

if [ ! -d "$ENV_PATH" ]; then
    echo "📦 Environment '$ENV_NAME' not found. Creating from template..."
    if [ -d "$ENV_TEMPLATE" ]; then
        # Используем rsync или tar для сохранения скрытых файлов
        if command -v rsync &> /dev/null; then
            rsync -a "$ENV_TEMPLATE/" "$ENV_PATH/"
        else
            mkdir -p "$ENV_PATH"
            (cd "$ENV_TEMPLATE" && tar -cf - .) | (cd "$ENV_PATH" && tar -xf -)
        fi
        echo "✅ Environment '$ENV_NAME' created."
    else
        echo "❌ ERROR: env-template not found in $PIBOX_REAL."
        exit 1
    fi
else
    echo "✅ Environment '$ENV_NAME' found."
fi

# --- Копирование models.json ---
# В ТЗ: models.json лежит в $PIBOX_DIR/env/models.json и копируется 
# в окружение перед первым запуском, если его там нет.
GLOBAL_MODELS="$PIBOX_REAL/env/models.json"
ENV_MODELS="$ENV_PATH/.pi/agent/models.json"

if [ -f "$GLOBAL_MODELS" ]; then
    if [ ! -f "$ENV_MODELS" ]; then
        echo "📄 Copying models.json to environment..."
        mkdir -p "$ENV_PATH/.pi/agent"
        cp "$GLOBAL_MODELS" "$ENV_MODELS"
    fi
else
    echo "⚠️  Warning: Global models.json not found at $GLOBAL_MODELS"
fi

# --- Проверка наличия образа ---
if ! docker image inspect "$IMAGE_NAME" &> /dev/null; then
    echo "❌ ERROR: Docker image '$IMAGE_NAME' not found."
    echo "   Please build it first (docker build -t $IMAGE_NAME .)"
    exit 1
fi

# --- Подготовка аргументов docker run ---
DOCKER_ARGS=(
    "-it"
    "--rm"
    "--name" "pibox-${ENV_NAME}-$(date +%s)"
    # Передаем хостовые UID и GID для динамической подстройки в entrypoint
    "--env" "HOST_UID=$(id -u)"
    "--env" "HOST_GID=$(id -g)"
    # Флаг для включения безопасной директории git
    "--env" "PIBOX_GIT_SAFE=$GIT_SAFE"
    # Монтируем окружение агента и рабочую директорию проекта
    "--volume" "$ENV_PATH:/home/pi"
    "--volume" "$WS_DIR:/home/pi/workspace"
    # Capabilities для отладчиков и сетевых утилит
    "--cap-add" "SYS_PTRACE"
    "--cap-add" "NET_RAW"
    # Доступ к сервисам хост-машины (например, локальному Model API)
    "--add-host" "host.docker.internal:host-gateway"
    # Ограничение ресурсов контейнера
    "--cpus" "2.0"
    "--memory" "4g"
)

# Добавляем пользовательские порты, если они были указаны
for port in "${PORTS[@]}"; do
    DOCKER_ARGS+=("-p" "$port")
done

# Добавляем имя образа
DOCKER_ARGS+=("$IMAGE_NAME")

# Добавляем аргументы агента в конец команды
if [ ${#AGENT_ARGS[@]} -gt 0 ]; then
    DOCKER_ARGS+=("${AGENT_ARGS[@]}")
fi

# --- Запуск ---
echo "🐳 Starting Docker container..."
echo "--------------------------------------------------"

exec docker run "${DOCKER_ARGS[@]}"
```

---

### 🧠 3. Пояснения к ключевым архитектурным решениям

1. **Безопасность Workspace через `realpath`:**
   Скрипт строго проверяет, чтобы текущая директория (`$PWD`) не находилась внутри `$PIBOX_DIR` и наоборот. Это защищает системные файлы и конфигурации самого PIBOX от случайного изменения или удаления агентом, работающим внутри контейнера.
2. **Разделение аргументов CLI и Агента:**
   Скрипт использует гибридный парсинг. Все флаги, которые он знает (`--env`, `-p`, `--git-safe`), он обрабатывает сам. Как только встречается неизвестный флаг или команда (например, `pi` или `bash`), скрипт прекращает парсинг и передает все оставшиеся аргументы внутрь контейнера. 
   *Примеры:*
   * `pibox` — запустит агента с параметрами по умолчанию.
   * `pibox --env php8 -p 8080:8080` — запустит агента в окружении `php8` с пробросом порта.
   * `pibox bash` — запустит не агента, а командную оболочку внутри контейнера.
   * `pibox --env rust -- --custom-flag` — всё, что после `--`, будет передано агенту как аргумент.
3. **Идемпотентная инициализация окружения:**
   Если окружение (например, `php8`) не существует, скрипт автоматически создаст его из `env-template`, скопировав все скрытые файлы и конфиги. При повторном запуске он просто использует уже существующее окружение, сохраняя все установленные агентом тулчейны и библиотеки.

---

### 🧪 4. Инструкция по тестированию

1. **Обновите скрипт в системе:**
   Так как `install.sh` копирует файлы из репозитория в `~/pibox`, вам нужно обновить установленную версию:
   ```bash
   # Находясь в корне репозитория
   ./install.sh
   ```

2. **Проверка безопасности (негативный тест):**
   Попробуйте запустить скрипт внутри директории `pibox`:
   ```bash
   cd ~/pibox
   pibox
   ```
   *Ожидаемый результат: Скрипт должен завершиться с ошибкой `Workspace is inside PIBOX_DIR`.*

3. **Тест 1: Запуск в чистой директории:**
   ```bash
   mkdir -p /tmp/my-project
   cd /tmp/my-project
   pibox
   ```
   *Ожидаемый результат: Контейнер запустится, и в терминале вы увидите логи инициализации `entrypoint.sh`, после чего запустится агент `pi`.*

4. **Тест 2: Создание нового окружения:**
   ```bash
   cd /tmp/my-project
   pibox --env php8
   ```
   *Ожидаемый результат: В логах появится сообщение `Environment 'php8' not found. Creating from template...`. После этого будет создан каталог `~/pibox/env/php8` с файлами из шаблона.*

5. **Тест 3: Проброс портов:**
   ```bash
   pibox -p 8080:8080 bash
   ```
   *Ожидаемый результат: Контейнер запустится в интерактивном режиме `bash`, а порт 8080 будет проброшен на хост.*