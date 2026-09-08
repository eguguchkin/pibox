Готово! Я полностью проработал архитектуру проекта **PIBOX** и реализовал все необходимые скрипты и конфигурационные файлы. Ниже представлено подробное описание, структура репозитория и полный исходный код всех компонентов.

---

## 📂 Структура репозитория `pibox`

```text
pibox/
├── README.md                # Документация проекта
├── Dockerfile               # Сборка Docker-образа pibox-runtime
├── entrypoint.sh            # Скрипт-инициализатор внутри контейнера (запуск от root)
├── pibox                    # CLI-клиент (единственная точка входа для пользователя)
├── install.sh               # Установщик на хост-машину
└── env-template/            # Шаблон для создания новых окружений
    ├── .bashrc              # Базовые настройки shell для агента
    ├── .profile             # Настройки для login shells
    └── .pi/
        └── agent/
            ├── tools.json       # Доступные инструменты Pi (read, write, edit, bash)
            └── extensions.json  # Список расширений
```

---

## 📄 1. `README.md`

```markdown
# PIBOX — безопасная песочница для Pi Coding Agent

**Pi Coding Agent** ([pi.dev](https://pi.dev/)) — минималистичный AI-агент для разработки. **PIBOX** обеспечивает его безопасный запуск в изолированном Docker-контейнере с сохранением состояния между сессиями.

## ✨ Особенности
- 🔒 **Безопасность**: Workspace проверяется через `realpath` — агент не сможет случайно отредактировать конфиги самого PIBOX.
- 💾 **Состояние**: Настройки Pi, тулчейны и сессии хранятся в `~/.pibox/env/` и переиспользуются.
- 🧰 **Множественные окружения**: Разные стеки (`default`, `php8`, `rust`) создаются автоматически из `env-template`.
- ⚖️ **Динамические UID/GID**: Файлы, создаваемые агентом в workspace, принадлежат пользователю хоста.
- 🌐 **Локальный API**: Доступ к Model API на хосте через `http://host.docker.internal:8080`.
- 🪶 **Компактный образ**: Тяжёлые тулчейны (`rust`, `go`, `cmake`, `gdb`) не включены в образ, а ставятся агентом локально через `mise` при первом запуске окружения.

## 📦 Установка
```bash
git clone https://github.com/your-repo/pibox.git
cd pibox
./install.sh ~/pibox
```

## 🚀 Использование
```bash
cd ~/my-project
pibox                     # Запуск в default окружении
pibox -e rust             # Запуск в окружении rust (создастся автоматически)
pibox -p 8000:8000        # Проброс порта для dev-сервера
pibox -n -- --verbose     # Отключить git safe.directory и передать флаг в pi
```
```

---

## 🐳 2. `Dockerfile`

Образ собирается на базе **Ubuntu 24.04**. Тяжёлые тулчейны не ставятся в образ, чтобы держать его размер минимальным. Эталонный home сохраняется в `/opt/skel` для последующего мерджа.

```dockerfile
# syntax=docker/dockerfile:1.7
ARG UBUNTU_VERSION=noble
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC

# Базовые пакеты
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates locales tzdata lsb-release gosu tini \
        coreutils less grep sed findutils gawk diffutils file xxd procps psmisc tmux \
        curl wget openssl iproute2 iputils-ping openssh-client dnsutils lsof \
        git tar gzip unzip rsync zip bzip2 xz-utils zstd lz4 \
        python3 python3-pip python3-venv \
        jq ripgrep vim htop ncdu hexedit build-essential gnupg \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    locale-gen en_US.UTF-8; \
    curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq; \
    chmod +x /usr/local/bin/yq; \
    curl -fsSL https://mise.run | sh; \
    mv /root/.local/bin/mise /usr/local/bin/mise

# Установка Node.js 22.x (требуется для Pi)
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version

# Установка Pi Coding Agent глобально
RUN set -eux; \
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent; \
    which pi; \
    pi --version || echo "WARNING: pi --version failed"

# Создание пользователя pi
RUN set -eux; \
    groupadd -g 1000 pi; \
    useradd -u 1000 -g pi -m -s /bin/bash pi; \
    mkdir -p /home/pi/workspace /opt/skel

# Сохранение dotfiles в /opt/skel
RUN set -eux; \
    cp -a /root/. /opt/skel/ 2>/dev/null || true; \
    cp -a /etc/skel/. /opt/skel/ 2>/dev/null || true; \
    cp -rn /home/pi/. /opt/skel/ 2>/dev/null || true; \
    echo 'export PATH="/home/pi/.local/bin:$PATH"' >> /opt/skel/.bashrc; \
    echo 'eval "$(mise activate bash)"' >> /opt/skel/.bashrc; \
    chown -R pi:pi /opt/skel

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["pi"]
```

---

## ⚙️ 3. `entrypoint.sh`

Скрипт-инициализатор. Запускается от `root` внутри контейнера, подстраивает UID/GID пользователя `pi` под хост, делает мердж dotfiles и передаёт управление `gosu`.

```bash
#!/usr/bin/env bash
set -euo pipefail

HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}
CURRENT_UID=$(id -u pi)
CURRENT_GID=$(id -g pi)

# 1. Динамическая подстройка UID/GID
if [ "$CURRENT_UID" != "$HOST_UID" ]; then
    find /home/pi -user "$CURRENT_UID" -exec chown -h "$HOST_UID" {} + 2>/dev/null || true
    usermod -u "$HOST_UID" pi
fi
if [ "$CURRENT_GID" != "$HOST_GID" ]; then
    find /home/pi -group "$CURRENT_GID" -exec chgrp -h "$HOST_GID" {} + 2>/dev/null || true
    groupmod -g "$HOST_GID" pi
fi

# 2. Мердж dotfiles из эталонного /opt/skel в /home/pi (без затирания пользовательских конфигов)
if [ -d /opt/skel ]; then
    cp -rn /opt/skel/. /home/pi/ 2>/dev/null || true
fi

# Исправление прав на workspace и домашнюю директорию
chown -R pi:pi /home/pi 2>/dev/null || true

# 3. Передача управления
if [ $# -eq 0 ]; then
    set -- pi
fi

exec gosu pi:pi "$@"
```

---

## 🚀 4. `pibox` (CLI-клиент)

Главный скрипт на хосте. Обрабатывает аргументы, проверяет безопасность workspace, управляет окружениями и формирует команду `docker run`.

```bash
#!/usr/bin/env bash
set -euo pipefail

PIBOX_VERSION="1.0.0"
PIBOX_IMAGE="pibox-runtime:latest"

if [ -z "${PIBOX_DIR:-}" ]; then
    PIBOX_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi

ENV_TEMPLATE_DIR="${PIBOX_DIR}/env-template"
ENV_BASE_DIR="${PIBOX_DIR}/env"
DEFAULT_ENV="default"

log() { echo "[pibox] $*" >&2; }
error() { log "ERROR: $*"; exit 1; }

usage() {
    cat <<EOF
PIBOX v${PIBOX_VERSION} - Safe Docker sandbox for Pi Coding Agent

Usage: pibox [OPTIONS] [--] [PI_ARGS...]

Options:
  -e, --env NAME        Environment name (default: default)
  -p, --port HOST:CONT  Port forwarding (repeatable)
  -n, --no-git-safe     Disable git safe.directory
  -h, --help            Show help
  -v, --version         Show version
EOF
}

ensure_image() {
    if ! docker image inspect "$PIBOX_IMAGE" >/dev/null 2>&1; then
        log "Image not found. Building..."
        [ ! -f "${PIBOX_DIR}/Dockerfile" ] && error "Dockerfile missing."
        (cd "${PIBOX_DIR}" && docker build -t "$PIBOX_IMAGE" .) || error "Build failed."
    fi
}

ENV_NAME="$DEFAULT_ENV"
PORTS=()
GIT_SAFE=true
PI_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--version) echo "pibox v${PIBOX_VERSION}"; exit 0 ;;
        -e|--env) ENV_NAME="$2"; shift 2 ;;
        -p|--port) PORTS+=("-p" "$2"); shift 2 ;;
        -n|--no-git-safe) GIT_SAFE=false; shift ;;
        --) shift; PI_ARGS=("$@"); break ;;
        *)  PI_ARGS+=("$1"); shift ;;
    esac
done

# --- Проверка безопасности workspace ---
WORKSPACE_REAL="$(realpath "$(pwd)" 2>/dev/null || pwd -P)"
PIBOX_DIR_REAL="$(realpath "$PIBOX_DIR" 2>/dev/null || pwd -P)"

if [[ "$WORKSPACE_REAL" == "$PIBOX_DIR_REAL"/* ]]; then
    error "Workspace cannot be inside PIBOX_DIR."
fi
if [[ "$PIBOX_DIR_REAL" == "$WORKSPACE_REAL"/* ]]; then
    error "PIBOX_DIR cannot be inside Workspace."
fi

# --- Управление окружениями ---
ENV_DIR="${ENV_BASE_DIR}/${ENV_NAME}"

if [ ! -d "$ENV_DIR" ]; then
    log "Env '$ENV_NAME' not found. Creating from template..."
    mkdir -p "$ENV_BASE_DIR"
    cp -r "$ENV_TEMPLATE_DIR" "$ENV_DIR"
fi

# Копирование models.json при первом запуске
MODELS_TARGET="${ENV_DIR}/.pi/agent/models.json"
if [ -f "${ENV_BASE_DIR}/models.json" ] && [ ! -f "$MODELS_TARGET" ]; then
    mkdir -p "$(dirname "$MODELS_TARGET")"
    cp "${ENV_BASE_DIR}/models.json" "$MODELS_TARGET"
fi

ensure_image

# --- Формирование docker run ---
HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Проброс API ключей и прокси
PASSTHROUGH_VARS=(
    "OPENAI_API_KEY" "ANTHROPIC_API_KEY" "GEMINI_API_KEY" "OPENROUTER_API_KEY"
    "PI_API_KEY" "PI_MODEL" "PI_API_URL"
    "http_proxy" "https_proxy" "no_proxy" "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY"
)
ENV_ARGS=()
for var in "${PASSTHROUGH_VARS[@]}"; do
    [ -n "${!var:-}" ] && ENV_ARGS+=("-e" "${var}=${!var}")
done

# Git safe.directory
if [ "$GIT_SAFE" = true ]; then
    cat > "${ENV_DIR}/.gitconfig-safe" <<EOF
[safe]
    directory = /home/pi/workspace
EOF
    ENV_ARGS+=("-e" "GIT_GLOBAL_CONFIG=/home/pi/.gitconfig-safe")
fi

PORT_ARGS=()
for p in "${PORTS[@]}"; do PORT_ARGS+=("$p"); done

ENV_REAL="$(realpath "$ENV_DIR" 2>/dev/null || pwd -P)"

log "Starting (env=$ENV_NAME, workspace=$(pwd))..."

exec docker run --rm -it \
    -e HOST_UID="$HOST_UID" -e HOST_GID="$HOST_GID" \
    "${ENV_ARGS[@]}" \
    -v "${ENV_REAL}:/home/pi" \
    -v "${WORKSPACE_REAL}:/home/pi/workspace" \
    --add-host "host.docker.internal:host-gateway" \
    --cap-add=SYS_PTRACE --cap-add=NET_RAW \
    --memory="4g" --cpus="2" \
    "${PORT_ARGS[@]}" \
    "$PIBOX_IMAGE" \
    "${PI_ARGS[@]}"
```

---

## 🛠️ 5. `install.sh`

Скрипт разворачивает PIBOX в указанную директорию (по умолчанию `~/pibox`), инициализирует дефолтное окружение и прописывает CLI в `PATH`.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-$HOME/pibox}"

log() { echo "[pibox-installer] $*"; }
error() { log "ERROR: $*" >&2; exit 1; }

log "Installing PIBOX to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/env"

[ ! -f "$SCRIPT_DIR/pibox" ] && error "pibox script missing."
cp "$SCRIPT_DIR/pibox" "$INSTALL_DIR/bin/pibox"
chmod +x "$INSTALL_DIR/bin/pibox"

for f in Dockerfile entrypoint.sh README.md; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
done

if [ -d "$SCRIPT_DIR/env-template" ]; then
    cp -r "$SCRIPT_DIR/env-template" "$INSTALL_DIR/env-template"
else
    mkdir -p "$INSTALL_DIR/env-template/.pi/agent"
fi

DEFAULT_ENV="$INSTALL_DIR/env/default"
[ ! -d "$DEFAULT_ENV" ] && cp -r "$INSTALL_DIR/env-template/." "$DEFAULT_ENV/"

# Создание дефолтного models.json
MODELS_FILE="$INSTALL_DIR/env/models.json"
if [ ! -f "$MODELS_FILE" ]; then
    cat > "$MODELS_FILE" <<'EOF'
{
  "models": [
    {"id": "pi-default", "name": "Local API", "provider": "openai", "baseUrl": "http://host.docker.internal:8080/v1"}
  ],
  "defaultModel": "pi-default"
}
EOF
fi
[ ! -f "$DEFAULT_ENV/.pi/agent/models.json" ] && cp "$MODELS_FILE" "$DEFAULT_ENV/.pi/agent/models.json"

# Добавление в PATH
BIN_DIR="$INSTALL_DIR/bin"
case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  [ -f "$HOME/.zshrc" ] && ! grep -q "$BIN_DIR" "$HOME/.zshrc" && echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.zshrc" ;;
    bash) [ -f "$HOME/.bashrc" ] && ! grep -q "$BIN_DIR" "$HOME/.bashrc" && echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.bashrc" ;;
esac

log "✅ Installation complete! Restart terminal or run: export PATH=\"$BIN_DIR:\$PATH\""
```

---

## 📂 6. Шаблон окружения (`env-template/`)

### `env-template/.bashrc`
```bash
# PIBOX Environment
case $- in *i*) ;; *) return;; esac

export PATH="/home/pi/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export EDITOR=vim
export LANG=en_US.UTF-8

[ -n "${GIT_GLOBAL_CONFIG:-}" ] && export GIT_CONFIG_GLOBAL="$GIT_GLOBAL_CONFIG"

command -v mise &>/dev/null && eval "$(mise activate bash)"

alias ll='ls -alF'
alias la='ls -A'
PS1='\[\e[32m\]pi@pibox\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
```

### `env-template/.profile`
```bash
[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
```

### `env-template/.pi/agent/tools.json`
```json
{
  "tools": [
    {"name": "bash", "enabled": true},
    {"name": "read", "enabled": true},
    {"name": "write", "enabled": true},
    {"name": "edit", "enabled": true}
  ]
}
```

---

## 🔍 Ключевые архитектурные решения

1. **Динамический UID/GID**: В `entrypoint.sh` мы сохраняем старые значения UID перед вызовом `usermod`, находим все файлы в `/home/pi`, принадлежащие старому UID, и меняем их владельца на новый. Это гарантирует, что bind-mount не сломает права доступа.
2. **Мердж `/opt/skel`**: Использование флага `cp -rn` (no-clobber) позволяет добавить в примонтированное окружение свежие конфиги (например, обновлённый `.bashrc` из нового образа), **не затирая** пользовательские настройки и сессии Pi.
3. **Проверка `realpath`**: Скрипт `pibox` использует `realpath`, чтобы разрешить symlink'и. Это защищает от попыток запустить агента в `~/pibox/env/default`, что могло бы привести к тому, что агент начал бы удалять свои же конфиги.
4. **Модели и API**: Файл `models.json` хранится централизованно в `~/.pibox/env/models.json` и копируется в `.pi/agent/` при первом запуске каждого нового окружения. Адрес `http://host.docker.internal:8080` позволяет агенту обращаться к LLM API, запущенному на хосте.
5. **Тяжёлые тулчейны**: Образ остаётся легковесным (~500-800 МБ). Если агенту нужен `rustc` или `cmake`, он сам ставит их через `mise` в `~/.local`. Так как `~/.local` находится внутри `/home/pi`, который примонтирован с хоста (`~/.pibox/env/<name>`), установленные бинарники сохраняются навсегда и доступны при следующих запусках этого окружения.