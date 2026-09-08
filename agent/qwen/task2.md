Ниже представлена полная реализация **Задачи 2**. 

Для корректной сборки образа нам понадобится сам `Dockerfile` и временная заглушка `entrypoint.sh` (которая будет полноценно реализована в Задаче 3), чтобы команда `COPY` не завершилась ошибкой.

### 📂 1. Структура файлов для этого этапа
В корне репозитория должны находиться:
```text
pibox-repo/
├── Dockerfile         # Основной файл сборки образа
└── entrypoint.sh      # Временная заглушка для успешной сборки
```

---

### 💻 2. Листинги файлов

#### `Dockerfile`
Образ собирается с использованием **multi-stage** подхода. На первом этапе (`builder`) мы скачиваем бинарные файлы `mise` и `yq`, чтобы не тянуть лишние зависимости и кэши в финальный образ. На втором этапе (`runtime`) устанавливаются все системные пакеты, Node.js, Python и сам Pi-агент.

```dockerfile
# syntax=docker/dockerfile:1

# ==========================================
# Stage 1: Builder (Скачивание бинарников)
# ==========================================
FROM ubuntu:latest AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Устанавливаем mise глобально в /usr/local/bin
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Скачиваем последнюю версию yq
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq


# ==========================================
# Stage 2: Runtime (Финальный образ)
# ==========================================
FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# 1. Установка базовых системных, сетевых и файловых утилит
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Системные
    ca-certificates \
    locales \
    tzdata \
    lsb-release \
    gosu \
    tini \
    coreutils \
    less \
    grep \
    sed \
    findutils \
    gawk \
    diffutils \
    file \
    xxd \
    procps \
    psmisc \
    tmux \
    # Сеть и безопасность
    curl \
    wget \
    openssl \
    iproute2 \
    iputils-ping \
    openssh-client \
    dnsutils \
    lsof \
    # Файлы и архивы
    git \
    tar \
    gzip \
    unzip \
    rsync \
    zip \
    bzip2 \
    xz-utils \
    zstd \
    lz4 \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Dev tools
    jq \
    ripgrep \
    vim \
    htop \
    ncdu \
    hexedit \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# 2. Установка актуальной версии Node.js (20.x)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Копирование бинарников из builder stage
COPY --from=builder /usr/local/bin/mise /usr/local/bin/mise
COPY --from=builder /usr/local/bin/yq /usr/local/bin/yq

# 4. Настройка локали
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# 5. Создание внутреннего пользователя pi
# Флаг -m создает home-директорию и копирует в нее базовые dotfiles из /etc/skel
RUN useradd -m -s /bin/bash -u 1000 pi

# 6. Установка Pi Coding Agent
# Запуск от root гарантирует, что npm install -g положит пакеты в /usr/local/lib/node_modules,
# а не в ~/.npm-global, что критично, так как /home/pi будет примонтирован снаружи.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# 7. Настройка точки входа
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 8. Сохранение эталонного home в /opt/skel
# На этом этапе /home/pi содержит только чистые .bashrc и .profile из /etc/skel.
# Мы сохраняем их, чтобы в entrypoint.sh смержить с примонтированным окружением пользователя.
RUN cp -a /home/pi /opt/skel

# Передаем управление в entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
```

#### `entrypoint.sh` (Заглушка)
Создайте этот файл, чтобы `COPY entrypoint.sh` в Dockerfile отработал успешно. Полная логика будет реализована в Задаче 3.

```bash
#!/usr/bin/env bash
set -e

# Заглушка для Задачи 2. 
# В Задаче 3 здесь будет логика подстройки UID/GID и мерджа /opt/skel.

echo "[PIBOX STUB] Entrypoint initialized."
echo "[PIBOX STUB] Passing control to CMD: $@"

# Просто передаем управление дальше
exec "$@"
```

---

### 🧠 3. Пояснения к ключевым архитектурным решениям

1. **Почему `npm install -g` безопасен для bind-mount?**
   Когда вы запускаете `npm install -g` от имени `root` (что происходит во время сборки Docker-образа), npm использует системный prefix (обычно `/usr/local`). Пакеты устанавливаются в `/usr/local/lib/node_modules`, а исполняемые файлы линкуются в `/usr/local/bin`. Директория `/home/pi` остается нетронутой. Когда позже мы примонтируем внешний volume в `/home/pi`, глобальные пакеты никуда не денутся и будут доступны агенту.
2. **Зачем нужен `/opt/skel`?**
   При создании пользователя (`useradd -m`) Ubuntu копирует содержимое `/etc/skel` (файлы `.bashrc`, `.profile`) в `/home/pi`. Но при запуске контейнера мы перетираем `/home/pi` пустым или пользовательским volume'ом. Сохранив эталонную копию в `/opt/skel`, мы сможем в `entrypoint.sh` аккуратно "долить" недостающие системные dotfiles в окружение пользователя, не затирая его собственные кастомные конфиги.
3. **Multi-stage для бинарников:**
   Инструменты `mise` и `yq` распространяются как готовые бинарники. Скачивая их в отдельном `builder` контейнере, мы избегаем попадания `wget`, `curl` и временных файлов загрузки в финальный слой образа, что делает его немного чище.

---

### 🧪 4. Инструкция по тестированию

1. **Соберите образ:**
   ```bash
   docker build -t pibox-base:latest .
   ```
   *Сборка должна пройти без ошибок. Обратите внимание на размер образа (ожидается ~600-900 МБ в зависимости от кэша).*

2. **Проверьте наличие ключевых компонентов:**
   Выполните команду ниже, чтобы убедиться, что все инструменты установлены и лежат в правильных местах:
   ```bash
   docker run --rm pibox-base:latest bash -c "
       echo '--- Binaries ---'
       which pi && which mise && which yq && which gosu && which tini
       echo '--- Node Modules ---'
       ls -la /usr/local/lib/node_modules/@earendil-works
       echo '--- Skel Check ---'
       ls -la /opt/skel
   "
   ```

3. **Проверьте, что `/home/pi` пуст (готов к bind-mount):**
   ```bash
   docker run --rm pibox-base:latest ls -la /home/pi
   ```
   *Вы должны увидеть стандартные `.bashrc`, `.profile` и `.bash_logout`, которые позже будут скопированы в `/opt/skel`.*