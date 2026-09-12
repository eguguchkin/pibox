# syntax=docker/dockerfile:1
# ============================================================================
# PIBOX — образ для безопасного запуска Pi Coding Agent в Docker.
#
# АРХИТЕКТУРНЫЕ ИНВАРИАНТЫ (нарушение любого = переделка):
#  1. ВСЕ установки — глобально (/usr, /usr/local). /home/pi при запуске
#     полностью подменяется bind-mount: всё, что установлено в home,
#     теряется. В /home/pi при сборке — ТОЛЬКО fallback-дотфайлы.
#  2. Node.js — из официального образа node (builder), НЕ из apt Ubuntu
#     (в noble — Node 18.x, недостаточно уверенно).
#  3. glibc-инвариант: база builder по glibc НЕ НОВЕЕ базы runtime:
#     bookworm (2.36) <= noble (2.39). Бинарники под старую glibc работают
#     на новой, обратное — нет. НЕ переводить builder на trixie (2.41).
#  4. Тяжёлые тулчейны (cmake, gdb, rustc, ...) в образ НЕ ставятся: их
#     агент ставит сам через mise в ~/.local — персистентно в env.
#  5. Multi-stage: npm-кэш и мусор установки остаются в builder.
# ============================================================================

ARG UBUNTU_VERSION=24.04
ARG NODE_IMAGE=node:22-bookworm-slim
ARG PI_VERSION=0.85.1

# ── Stage 1: builder — node + npm + pi в /usr/local ─────────────────────────
FROM ${NODE_IMAGE} AS builder
ARG PI_VERSION

# --ignore-scripts обязателен: pi не требует lifecycle-скриптов (задача 1),
# а флаг отсекает выполнение произвольного postinstall-кода при сборке.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force
# Итог: /usr/local/{bin/{node,npm,npx,pi}, include/node, lib/node_modules/...}
# npm-кэш (/root/.npm) остаётся в builder — в runtime не попадает.

# ── Stage 2: runtime — ubuntu 24.04 + базовый набор ─────────────────────────
FROM ubuntu:${UBUNTU_VERSION}
ARG PI_VERSION
ARG UBUNTU_VERSION

LABEL org.opencontainers.image.title="pibox" \
      org.opencontainers.image.description="Pi Coding Agent in an isolated Docker sandbox" \
      org.opencontainers.image.version="${PI_VERSION}+pibox" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}"

# — apt: базовый набор (сверен с docs/NOTES.md, задача 1) —
# НЕ ставим через apt: nodejs/npm (приходят из builder — иначе два
# конфликтующих node); cat/find/xargs (уже в coreutils/findutils базового
# образа); тяжёлые тулчейны (инвариант №4).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates locales tzdata lsb-release gosu tini \
      less grep sed gawk diffutils file xxd procps psmisc tmux \
      curl wget openssl iproute2 iputils-ping openssh-client dnsutils lsof \
      git tar gzip unzip zip rsync bzip2 xz-utils zstd lz4 \
      python3 python3-pip python3-venv \
      jq ripgrep yq vim htop ncdu hexedit \
 && rm -rf /var/lib/apt/lists/*
# Примечания: hexedit/ncdu/yq — из universe (в docker-образе Ubuntu он
# включён). yq из apt — Python-обёртка над jq, НЕ Go-yq (mikefarah),
# синтаксис отличается — см. docs/NOTES.md.

# — locale —
RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# — node + npm + pi из builder (одним COPY) —
COPY --from=builder /usr/local/ /usr/local/

# --- mise: глобальный бинарник ---
# Используем официальный установщик с MISE_INSTALL_PATH
# (НЕ через mise.run без env — тот пишет в ~/.local/bin)
RUN set -eux; \
    curl -fsSL https://mise.run -o /tmp/install-mise.sh; \
    MISE_INSTALL_PATH=/usr/local/bin/mise sh /tmp/install-mise.sh; \
    rm -f /tmp/install-mise.sh; \
    mise --version

ENV MISE_YES=1

# --- пользователь pi ---
# ВАЖНО: в ubuntu:24.04 есть стандартный пользователь "ubuntu" с UID 1000.
# Удаляем его, чтобы освободить UID для pi.
# UID/GID 1000 — сборочный дефолт; реальный UID/GID хостового пользователя
# подгонит entrypoint динамически (задача 5).
RUN userdel -r ubuntu 2>/dev/null || true; \
    useradd --create-home --uid 1000 --shell /bin/bash pi


    
# — fallback-дотфайлы (КОНТРАКТ с задачей 4: канонические — в env-template) —
RUN cat >> /home/pi/.bashrc <<'BASHRC'

# Тулчейны mise
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

# Цветной prompt pibox
export PS1='\[\e[31m\](pibox)\[\e[0m\] \[\e[34m\]\u@\h\[\e[0m\]:\[\e[32m\]\w\[\e[0m\]\$ '
BASHRC

# — эталонный home: снимок ДО создания workspace (WORKDIR ниже) —
# Владелец /opt/skel не важен: merge в entrypoint выполняется от root,
# права выправляет задача 5 при первой инициализации окружения.
RUN cp -a /home/pi /opt/skel \
 && chown -R pi:pi /home/pi

# — entrypoint (временно passthrough; полная логика — задача 5) —
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# — окружение по умолчанию —
# PATH прописан ЯВНО, БЕЗ подстановки $PATH: в ubuntu-образе PATH не
# объявлен как ENV, подстановка дала бы сломанный путь (см. подводный
# камень №1). entrypoint (задача 5) переэкспортирует PATH для pi.
ENV HOME=/home/pi \
    PATH="/home/pi/.local/bin:/home/pi/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WORKDIR /home/pi/workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
