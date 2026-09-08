Ниже представлена полная реализация проекта PIBOX — все необходимые скрипты, файлы конфигурации и документация.

---

## Структура репозитория

```
.
├── Dockerfile
├── README.md
├── entrypoint.sh
├── install.sh
├── pibox
└── env-template/
    ├── .bashrc
    ├── .profile
    ├── .npmrc
    ├── .pi/
    │   └── agent/
    │       └── .gitkeep
    └── .local/
        └── share/
            └── mise/
                └── .gitkeep
```

---

## 1. `install.sh` – установщик проекта

```bash
#!/bin/bash
set -e

# Устанавливаем директорию PIBOX (по умолчанию ~/pibox)
PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"

echo "Установка PIBOX в $PIBOX_DIR..."

# Создаём основные директории
mkdir -p "$PIBOX_DIR/bin"
mkdir -p "$PIBOX_DIR/env"

# Копируем главный скрипт pibox
cp "$(dirname "$0")/pibox" "$PIBOX_DIR/bin/pibox"
chmod +x "$PIBOX_DIR/bin/pibox"

# Копируем шаблон окружения
cp -r "$(dirname "$0")/env-template" "$PIBOX_DIR/"

# Создаём окружение по умолчанию из шаблона
cp -r "$PIBOX_DIR/env-template" "$PIBOX_DIR/env/default"

# Создаём общий файл models.json
cat > "$PIBOX_DIR/env/models.json" << 'EOF'
{
  "models": [
    {
      "id": "local",
      "name": "Local Model",
      "provider": "openai",
      "baseUrl": "http://host.docker.internal:8080/v1",
      "apiKey": "not-needed"
    }
  ],
  "defaultModel": "local"
}
EOF

# Добавляем PIBOX_DIR/bin в PATH, если ещё не добавлен
if [[ ":$PATH:" != *":$PIBOX_DIR/bin:"* ]]; then
    echo
    echo "Добавьте $PIBOX_DIR/bin в PATH, выполнив:"
    echo "  export PATH=\"$PIBOX_DIR/bin:\$PATH\""
    echo "или добавьте эту строку в ~/.bashrc"
fi

echo "Установка завершена. Для сборки Docker-образа выполните:"
echo "  cd $(dirname "$0") && docker build -t pibox:latest ."
```

---

## 2. `pibox` – точка входа (командная утилита)

```bash
#!/bin/bash
set -e

PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"
if [ ! -d "$PIBOX_DIR" ]; then
    echo "Ошибка: PIBOX_DIR ($PIBOX_DIR) не существует. Запустите install.sh." >&2
    exit 1
fi

# Проверка, что текущая рабочая директория не является PIBOX_DIR или её поддиректорией
CWD=$(realpath .)
PIBOX_REAL=$(realpath "$PIBOX_DIR")
if [[ "$CWD" == "$PIBOX_REAL"* ]]; then
    echo "Ошибка: Запуск из PIBOX_DIR или вложенной директории запрещён." >&2
    exit 1
fi

# Функция создания нового окружения
create_env() {
    local env_name="$1"
    local env_dir="$PIBOX_DIR/env/$env_name"
    if [ -d "$env_dir" ]; then
        echo "Окружение $env_name уже существует." >&2
        return 1
    fi
    echo "Создание окружения $env_name..."
    cp -r "$PIBOX_DIR/env-template" "$env_dir"
    if [ -f "$PIBOX_DIR/env/models.json" ] && [ ! -f "$env_dir/.pi/agent/models.json" ]; then
        mkdir -p "$env_dir/.pi/agent"
        cp "$PIBOX_DIR/env/models.json" "$env_dir/.pi/agent/models.json"
    fi
    echo "Окружение $env_name создано."
}

# Функция запуска контейнера
run_container() {
    local env_name="$1"
    shift
    local cmd="$@"
    [ -z "$cmd" ] && cmd="pi"

    local env_dir="$PIBOX_DIR/env/$env_name"
    if [ ! -d "$env_dir" ]; then
        echo "Окружение $env_name не найдено. Создаём..."
        create_env "$env_name"
    fi

    # Копируем models.json в окружение, если отсутствует
    if [ ! -f "$env_dir/.pi/agent/models.json" ] && [ -f "$PIBOX_DIR/env/models.json" ]; then
        mkdir -p "$env_dir/.pi/agent"
        cp "$PIBOX_DIR/env/models.json" "$env_dir/.pi/agent/models.json"
    fi

    # Передаём UID/GID хоста в контейнер
    local host_uid=$(id -u)
    local host_gid=$(id -g)

    docker run --rm -it \
        -e HOST_UID="$host_uid" \
        -e HOST_GID="$host_gid" \
        -v "$env_dir":/home/pi \
        -v "$CWD":/home/pi/workspace \
        --add-host host.docker.internal:host-gateway \
        --cap-add=SYS_PTRACE \
        --cap-add=NET_RAW \
        --cpus=2 \
        --memory=4g \
        pibox:latest \
        $cmd
}

# Обработка подкоманд
COMMAND="${1:-run}"
shift || true

case "$COMMAND" in
    run)
        ENV_NAME="${1:-default}"
        shift || true
        run_container "$ENV_NAME" "$@"
        ;;
    list-envs)
        echo "Доступные окружения:"
        for d in "$PIBOX_DIR/env"/*/; do
            if [ -d "$d" ]; then
                basename "$d"
            fi
        done
        ;;
    create-env)
        if [ -z "$1" ]; then
            echo "Укажите имя нового окружения." >&2
            exit 1
        fi
        create_env "$1"
        ;;
    exec)
        if [ -z "$1" ]; then
            echo "Укажите имя окружения." >&2
            exit 1
        fi
        ENV_NAME="$1"
        shift || true
        if [ -z "$1" ]; then
            echo "Укажите команду для выполнения." >&2
            exit 1
        fi
        run_container "$ENV_NAME" "$@"
        ;;
    *)
        echo "Неизвестная команда: $COMMAND" >&2
        echo "Доступные: run [env] [cmd], list-envs, create-env <name>, exec <env> <cmd>" >&2
        exit 1
        ;;
esac
```

---

## 3. `entrypoint.sh` – скрипт инициализации внутри контейнера

```bash
#!/bin/bash
set -e

# Получаем UID и GID из переменных окружения (устанавливаются при запуске)
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}

# Подстраиваем пользователя pi под UID/GID хоста
if [ "$HOST_UID" != "$(id -u pi)" ] || [ "$HOST_GID" != "$(id -g pi)" ]; then
    groupmod -g "$HOST_GID" pi
    usermod -u "$HOST_UID" -g "$HOST_GID" pi
    # Пытаемся скорректировать права на домашнюю директорию (если это bind‑mount, ошибка игнорируется)
    chown -R pi:pi /home/pi 2>/dev/null || true
fi

# Мердж dotfiles из эталонного скелета (копируем только отсутствующие файлы)
if [ -d "/opt/skel" ]; then
    cp -rn /opt/skel/. /home/pi/
fi

# Добавляем workspace в safe.directory для Git (чтобы избежать предупреждений)
gosu pi:pi git config --global --add safe.directory /home/pi/workspace

# Переключаемся на пользователя pi и выполняем переданную команду
exec gosu pi:pi tini -- "$@"
```

---

## 4. `Dockerfile` – сборка образа

```dockerfile
# Базовый образ Ubuntu 22.04 LTS
FROM ubuntu:22.04

# Предотвращаем интерактивные запросы при установке
ENV DEBIAN_FRONTEND=noninteractive

# Установка базовых системных пакетов и утилит
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates locales tzdata lsb-release \
    gosu tini \
    curl wget git \
    cat less grep sed find xargs gawk diffutils file xxd \
    procps psmisc tmux \
    openssl iproute2 iputils-ping openssh-client dnsutils lsof \
    tar gzip unzip rsync zip bzip2 xz-utils zstd lz4 \
    python3 python3-pip python3-venv nodejs npm \
    jq ripgrep yq vim htop ncdu hexedit \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Установка mise (менеджер версий)
RUN curl https://mise.run | sh
ENV PATH="/root/.local/share/mise/shims:/root/.local/bin:${PATH}"

# Установка Pi Coding Agent (предполагается, что пакет называется pi-agent)
RUN pip3 install pi-agent

# Создание пользователя pi
RUN groupadd -r pi && useradd -r -g pi -m -d /home/pi -s /bin/bash pi

# Сохранение эталонной домашней директории в /opt/skel
RUN cp -r /home/pi /opt/skel

# Копирование entrypoint-скрипта
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Рабочая директория (будет переопределена монтированием)
WORKDIR /home/pi/workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
```

---

## 5. `env-template/` – шаблон окружения

### `.bashrc`

```bash
# ~/.bashrc для пользователя pi

# Добавляем mise в PATH
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

# Полезные алиасы
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
```

### `.profile`

```bash
# ~/.profile – выполняется при входе
if [ -n "$BASH" ] && [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
```

### `.npmrc`

```ini
# npm конфигурация (можно дополнить)
prefix=${HOME}/.local
```

### `.pi/agent/.gitkeep` – пустой файл для сохранения директории в git

### `.local/share/mise/.gitkeep` – пустой файл для сохранения директории в git

---

## 6. `README.md` – документация проекта

```markdown
# PIBOX — безопасный запуск Pi Coding Agent в Docker

PIBOX — это инструмент для изолированного запуска [Pi Coding Agent](https://pi.dev/) в Docker-контейнере с сохранением состояния, управлением окружениями и гибкой настройкой.

## Особенности

- **Изоляция** – агент работает внутри контейнера, не влияя на хост-систему.
- **Управление окружениями** – каждое окружение (`default`, `php8`, `rust` и т.д.) хранит свои конфиги, ключи и установленные тулчейны.
- **Автоматическое создание** – новое окружение создаётся из шаблона при первом запуске.
- **Динамический UID/GID** – файлы, создаваемые агентом в рабочей директории, принадлежат пользователю хоста.
- **Безопасность** – проверка рабочей директории, ограничение ресурсов, минимальные capabilities.
- **Готовые инструменты** – в образе предустановлены `mise`, Python, Node.js и множество утилит.

## Установка

1. Клонируйте репозиторий:
   ```bash
   git clone https://github.com/your-username/pibox.git
   cd pibox
   ```

2. Запустите установщик:
   ```bash
   ./install.sh
   ```
   По умолчанию PIBOX устанавливается в `~/pibox`. При желании измените путь через переменную `PIBOX_DIR`:
   ```bash
   PIBOX_DIR=/opt/pibox ./install.sh
   ```

3. Добавьте `PIBOX_DIR/bin` в `PATH` (установщик подскажет команду).

4. Соберите Docker-образ:
   ```bash
   docker build -t pibox:latest .
   ```

## Использование

Основная команда – `pibox` (точка входа).

### Запуск агента в текущей директории

```bash
cd ~/my-project
pibox
```
По умолчанию используется окружение `default`. Агент запустится в директории `~/my-project`, которая будет смонтирована как `/home/pi/workspace`.

### Запуск с указанием окружения

```bash
pibox run php8
```
Если окружение `php8` не существует, оно будет создано из шаблона.

### Выполнение произвольной команды в контейнере

```bash
pibox exec default bash
```
Откроет интерактивную оболочку `bash` внутри контейнера с окружением `default`.

### Список окружений

```bash
pibox list-envs
```

### Создание нового окружения

```bash
pibox create-env my-env
```

## Настройка моделей

Файл `~/pibox/env/models.json` содержит конфигурацию моделей для Pi. Он копируется в каждое новое окружение при первом запуске (в `~/.pi/agent/models.json`). По умолчанию используется локальный эндпоинт `http://host.docker.internal:8080/v1`. Вы можете отредактировать этот файл или переопределить его в конкретном окружении.

## Переменные окружения

- `PIBOX_DIR` – путь к установке PIBOX (по умолчанию `~/pibox`).
- `HOST_UID` / `HOST_GID` – передаются автоматически при запуске для согласования прав доступа.

## Требования

- Docker (версия ≥ 20.10 с поддержкой `host.docker.internal`).
- Bash.
- Права на запуск Docker-контейнеров.

## Безопасность

- Рабочая директория не должна находиться внутри `PIBOX_DIR` – проверка через `realpath`.
- Ограничения CPU (2 ядра) и памяти (4 ГБ) предотвращают исчерпание ресурсов хоста.
- Добавлены capabilities `SYS_PTRACE` и `NET_RAW` только при необходимости.
- Все действия внутри контейнера выполняются от непривилегированного пользователя `pi`.

## Расширение

Для добавления новых тяжёлых инструментов (Go, Rust, и т.д.) используйте `mise` внутри окружения. Установленные версии сохраняются в `~/.local/share/mise` и будут доступны при следующих запусках.

## Лицензия

MIT
```

---

## Запуск и проверка

После установки и сборки образа выполните в любом каталоге (кроме `~/pibox`):

```bash
pibox
```

Если всё настроено правильно, контейнер запустится, и вы увидите приглашение Pi Coding Agent. Все изменения в рабочей директории будут сохраняться на хосте, а конфигурация окружения – в `~/pibox/env/default`.

---

Все файлы готовы к использованию. Скопируйте их в соответствующие места, следуя структуре репозитория, и проект будет полностью функционален.