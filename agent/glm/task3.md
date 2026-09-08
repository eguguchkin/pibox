# Задача 3 — Dockerfile (multi-stage сборка)

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent: `/home/pi` контейнера подменяется bind-mount'ом окружения с хоста, текущий каталог пользователя становится `workspace`. Поэтому **всё в образе ставится глобально** (`/usr`, `/usr/local`) — иначе установки потеряются при первом запуске. Тяжёлые тулчейны (компиляторы, отладчики) в образ не входят — их агент ставит сам через `mise` в `~/.local`, и они переживают перезапуск вместе с env. |
| **Цель задачи** | Заменить заглушку `Dockerfile` из задачи 2 на полную multi-stage сборку: Ubuntu 24.04 + базовый набор пакетов + Node 22 + `pi-coding-agent` + глобальный `mise` + эталонный home в `/opt/skel`. Получить собирающийся и верифицируемый образ `pibox:latest`. |
| **Зависимости** | Задача 1 (сверенный список пакетов в `docs/NOTES.md`), задача 2 (каркас, `.dockerignore`, CI) |
| **Артефакты** | `Dockerfile` (полный), `entrypoint.sh` (временный passthrough), обновления `docs/NOTES.md` |
| **Не входит в задачу** | Логика entrypoint (UID/GID, skel-merge — задача 5), содержимое `env-template` (задача 4), CLI/установщик (задачи 6–7). `.dockerignore`, `ci.yml`, `run.sh`, `install.sh`, `models.json`, `env-template/`, `tests/` — **не трогаем**: задача 2 уже подготовила всё необходимое. |

---

## 🏗️ Ключевые архитектурные решения (принять до написания кода)

| # | Решение | Обоснование |
|---|---|---|
| 1 | **Node.js — из официального образа `node:22-bookworm-slim` (builder), не из apt** | Ubuntu noble даёт Node 18.x — недостаточно уверенно (TODO №1 из задачи 1). Официальный образ — контролируемая версия 22 + готовые `node`/`npm` для COPY. |
| 2 | **Один `COPY --from=builder /usr/local/ /usr/local/`** | В builder после `npm i -g` в `/usr/local` лежат сразу node, npm и pi. npm-кэш (`/root/.npm`) остаётся в builder — в этом реальный выигрыш multi-stage. |
| 3 | **glibc-инвариант: база builder не новее runtime по glibc** | bookworm (glibc 2.36) → noble (glibc 2.39): бинарники, собранные под старую glibc, работают на новой. Обратное — нет. Builder на trixie (glibc 2.41) с `ubuntu:24.04` **сломает** образ. |
| 4 | **`ENV PATH` — явный полный список, без `$PATH`** | В ubuntu-образе `PATH` не объявлен как ENV — подстановка `$PATH` в `ENV` даст сломанный путь (детали в «Подводных камнях», №1). |
| 5 | **`MISE_DATA_DIR` не задаём** | Данные mise по умолчанию — `~/.local/share/mise`, т.е. внутри home → в смонтированном env → тулчейны агента персистентны. |
| 6 | **`/opt/skel` = снимок `/home/pi` на момент сборки** | Всё, что в home до bind-mount, недоступно после; entrypoint (задача 5) мерджит skel через `cp -rn`. |
| 7 | **Контракт дотфайлов с задачей 4** | Канонические `.bashrc`/`.profile` — в `env-template` (задача 4). В skel — **минимальный фолбэк** (PATH + mise), копируется только при отсутствии своего файла. |
| 8 | **`entrypoint.sh` обновляется до временного passthrough** | Заглушка из задачи 2 (`exit 1`) не позволяет тестировать образ. `exec "$@"` делает образ верифицируемым; задача 5 заменит файл целиком. |

---

## 1. Подготовка (обязательные шаги перед сборкой)

1. **Версия mise.** Открыть <https://github.com/jdx/mise/releases>, взять актуальный стабильный релиз и **проверить точное имя tarball-ассета** для `linux-x64` и `linux-arm64` (шаблон: `mise-<версия>-linux-<arch>.tar.gz` — если фактическое имя отличается, скорректировать URL в Dockerfile). Выбранную версию подставить в `ARG MISE_VERSION`.
2. **Версия pi** — `0.85.1` (зафиксирована задачей 1). При желании обновить — только с записью в NOTES.md.
3. **Прогнать список пакетов через проверку** (в контейнере `ubuntu:24.04`):

```bash
docker run --rm ubuntu:24.04 bash -c '
  for p in ca-certificates locales tzdata lsb-release gosu tini \
           less grep sed gawk diffutils file xxd procps psmisc tmux \
           curl wget openssl iproute2 iputils-ping openssh-client dnsutils lsof \
           git tar gzip unzip zip rsync bzip2 xz-utils zstd lz4 \
           python3 python3-pip python3-venv \
           jq ripgrep yq vim htop ncdu hexedit; do
    apt-cache policy "$p" >/dev/null 2>&1 || echo "НЕТ В РЕПОЗИТОРИЯХ: $p"
  done; echo done'
```

Если какой-то пакет не найден (например, `hexedit`/`ncdu` при изменении репозиториев) — исключить из списка и записать это в NOTES.md.

---

## 2. `Dockerfile` — полный текст

```dockerfile
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
# ⚠️ ПЛЕЙСХОЛДЕР: заменить на актуальную версию mise (шаг 1 инструкции,
# зафиксировать выбор в docs/NOTES.md)
ARG MISE_VERSION=v2025.8.0

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
ARG MISE_VERSION

LABEL org.opencontainers.image.title="pibox" \
      org.opencontainers.image.description="Pi Coding Agent in an isolated Docker sandbox" \
      org.opencontainers.image.version="${PI_VERSION}+pibox" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}"
# TODO(задача 9): добавить org.opencontainers.image.source и .licenses

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

# — mise: глобальный бинарник (НЕ через mise.run — тот пишет в home) —
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" = "amd64" ]; then arch="x64"; fi; \
    curl -fsSL \
      "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${arch}.tar.gz" \
      -o /tmp/mise.tar.gz; \
    tar -xzf /tmp/mise.tar.gz -C /tmp; \
    if [ -f /tmp/mise ]; then \
        mv /tmp/mise /usr/local/bin/mise; \
    elif [ -f /tmp/mise/mise ]; then \
        mv /tmp/mise/mise /usr/local/bin/mise; \
    else \
        echo "pibox: mise binary not found in archive" >&2; \
        exit 1; \
    fi; \
    rm -rf /tmp/mise.tar.gz /tmp/mise; \
    chmod +x /usr/local/bin/mise; \
    mise --version
# Двойная проверка (файл /tmp/mise или /tmp/mise/mise) устойчива к двум
# возможным структурам tarball'а — имя ассета проверено на шаге 1.
#
# MISE_DATA_DIR НЕ задавать: данные mise по умолчанию — в
# ~/.local/share/mise, внутри home => в смонтированном env => тулчейны
# агента переживают перезапуск контейнера.
ENV MISE_YES=1

# — пользователь pi —
# UID/GID 1000 — сборочный дефолт; реальный UID/GID хостового пользователя
# подгонит entrypoint динамически (задача 5).
RUN useradd --create-home --uid 1000 --shell /bin/bash pi

# — fallback-дотфайлы (КОНТРАКТ с задачей 4: канонические — в env-template) —
COPY <<'BASHRC' /home/pi/.bashrc
# ~/.bashrc — ФОЛБЭК из /opt/skel (pibox).
# Каноническая версия — в env-template (задача 4). Этот файл попадает в
# окружение только при отсутствии собственного .bashrc (cp -rn в entrypoint).

# Неинтерактивный bash не читает rc-файлы; выходим сразу на всякий случай.
case $- in *i*) ;; *) return ;; esac

# Тулчейны mise и локальные установки агента
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

export HISTSIZE=10000
export HISTFILESIZE=20000
export PS1='(pibox) \u@\h:\w\$ '
BASHRC

COPY <<'PROFILE' /home/pi/.profile
# ~/.profile — ФОЛБЭК из /opt/skel (pibox).
# Каноническая версия — в env-template (задача 4).

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
PROFILE

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
```

### Разбор по секциям

| Секция | Назначение | Критичная деталь |
|---|---|---|
| ARG-блок до FROM | версии фиксируются аргументами сборки | переопределяются `--build-arg`, значения записываются в NOTES.md |
| builder | `npm i -g pi` | `--ignore-scripts`; кэш npm умирает в builder |
| apt RUN | 39 пакетов | один слой + `--no-install-recommends` + очистка `lists` |
| locale | `en_US.UTF-8` | `ENV LANG`/`LC_ALL` |
| `COPY /usr/local/` | node+npm+pi | glibc-инвариант (решение №3) |
| mise RUN | бинарник в `/usr/local/bin` | `MISE_DATA_DIR` не задаём (решение №5) |
| `useradd` | `pi`, uid 1000 | реальный UID подгонит задача 5 |
| heredoc COPY | fallback `.bashrc`/`.profile` | контракт с задачей 4 (решение №7) |
| `cp -a → /opt/skel` | эталонный home | строго ДО `WORKDIR` |
| ENV | `HOME`, явный `PATH`, `MISE_YES` | без `$PATH`-подстановки (решение №4) |
| ENTRYPOINT/CMD | `/entrypoint.sh`, `pi` | exec-цепочка, override аргументами |

---

## 3. `entrypoint.sh` — временный passthrough

> **Осознанное изменение артефакта задачи 2.** Заглушка с `exit 1` не позволяет проверить образ после сборки. Passthrough — минимально достаточная версия для тестирования; задача 5 заменит файл целиком (UID/GID, skel-merge, `gosu pi:pi tini -- "$@"`).

```bash
#!/usr/bin/env bash
# Entrypoint контейнера pibox.
#
# ВРЕМЕННАЯ ВЕРСИЯ (задача 3): прозрачный passthrough, чтобы образ был
# пригоден для тестирования (pi --version, проверка инструментов, smoke).
# Полная реализация — подстройка UID/GID, skel-merge, exec через
# `gosu pi:pi tini -- "$@"` — задача 5; файл будет заменён целиком.

set -euo pipefail

echo "pibox: entrypoint: временный passthrough (задача 3); полная логика — задача 5" >&2

exec "$@"
```

`shellcheck entrypoint.sh` обязан проходить без замечаний (CI из задачи 2 это проверяет).

---

## 4. Обновление `docs/NOTES.md`

Добавить в конец файла раздел (и отметить выполненными `[x]` соответствующие TODO из раздела 8 задачи 1):

```markdown
## 11. Результаты задачи 3 (Dockerfile)

### Закрытые TODO
- ✅ Версия Node.js: Node НЕ из apt (noble даёт 18.x). Решено: node/npm
  копируются из официального образа node:22-bookworm-slim (multi-stage).
  Версия закреплена мажором 22.
- ✅ Вложенные bind-mount: проверено на собранном образе — Docker
  корректно монтирует -v env:/home/pi + -v ws:/home/pi/workspace
  (workspace перекрывает путь внутри /home/pi).
- ✅/⚠️ mise в non-interactive shell: rc-файлы неинтерактивным bash НЕ
  читаются. PATH с шимами задаётся ENV образа и переэкспортируется
  entrypoint (задача 5); `mise activate` — только для интерактивных сессий.

### Зафиксированные версии
| Компонент | Версия | Закрепление |
|---|---|---|
| Ubuntu | 24.04 | ARG UBUNTU_VERSION |
| Node.js | 22 (мажор), bookworm-slim | ARG NODE_IMAGE |
| pi-coding-agent | 0.85.1 | ARG PI_VERSION |
| mise | <фактическая версия> | ARG MISE_VERSION |

### Размер образа
`docker images pibox:latest` → <записать фактический результат>.
Ориентир: ~0.6–0.9 ГБ (против 2+ ГБ «всё-в-одном» с тулчейнами).

### Замечания
- yq из apt — Python-обёртка над jq, НЕ Go-yq (mikefarah); поведение
  отличается. Если нужен Go-yq — отдельное решение (замена на бинарник
  с GitHub) с фиксацией здесь.
- pip в образе подчиняется PEP 668 (externally-managed): глобальная
  установка требует --break-system-packages; агенту следует использовать
  venv (python3-venv установлен).
- Учесть в задаче 4: агент не может `npm i -g` от пользователя pi без
  root (префикс /usr/local). Кандидат на решение — ~/.npmrc с
  prefix=~/.local в env-template (персистентно, без root).
```

---

## 5. Сборка и верификация

```bash
# 0. Предусловия
docker version          # >= 20.10; для Docker 20.10–22: export DOCKER_BUILDKIT=1
                       # (heredoc COPY и --chmod требуют BuildKit; Docker 23+ — по умолчанию)
shellcheck entrypoint.sh

# 1. Сборка
docker build -t pibox:latest .

# 2. Версии ключевых инструментов
docker run --rm pibox:latest bash -c '
  echo "node:   $(node --version)"; echo "npm:    $(npm --version)";
  echo "pi:     $(pi --version)";   echo "mise:   $(mise --version)";
  echo "python: $(python3 --version)"; echo "git:  $(git --version)"'
# Ожидание: node v22.x, npm 10.x, pi 0.85.1, mise <выбранная>, python 3.12.x

# 3. Всё глобально, вне home (инвариант №1)
docker run --rm pibox:latest bash -c '
  command -v pi node npm mise jq yq rg xxd gosu tini; ls -A /home/pi'
# Ожидание: бинарники в /usr/local/bin; в /home/pi только
# .bashrc .profile .bash_logout — НИКАКИХ установок

# 4. Пользователь и skel
docker run --rm pibox:latest bash -c 'id pi; ls -la /opt/skel'
# Ожидание: uid=1000(pi); /opt/skel содержит .bashrc/.profile/.bash_logout

# 5. Тяжёлых тулчейнов в образе НЕТ (инвариант №4)
docker run --rm pibox:latest bash -c \
  'command -v gcc gdb rustc cargo cmake valgrind || echo "OK: тулчейнов нет"'

# 6. pi стартует через entryoint-passthrough (и от root, и от pi)
docker run --rm pibox:latest pi --version
docker run --rm --user pi pibox:latest pi --version

# 7. host-gateway (закрывает TODO задачи 1)
docker run --rm --add-host=host.docker.internal:host-gateway \
  pibox:latest getent hosts host.docker.internal
# Ожидание: строка вида "172.17.0.1  host.docker.internal"

# 8. Вложенные bind-mount (закрывает TODO задачи 1) + механика skel-merge
mkdir -p /tmp/pibox-check/env /tmp/pibox-check/ws
echo probe > /tmp/pibox-check/ws/probe.txt
docker run --rm -v /tmp/pibox-check/env:/home/pi \
                    -v /tmp/pibox-check/ws:/home/pi/workspace \
  pibox:latest cat /home/pi/workspace/probe.txt        # → probe
docker run --rm -v /tmp/pibox-check/env:/home/pi \
                    -v /tmp/pibox-check/ws:/home/pi/workspace \
  pibox:latest ls -A /home/pi                           # → пусто (home скрыт монтом)
docker run --rm -v /tmp/pibox-check/env:/home/pi \
  pibox:latest bash -c 'cp -rn /opt/skel/. /home/pi/ && ls -A /home/pi'
# → .bash_logout .bashrc .profile  (механика, на которую опирается задача 5)
rm -rf /tmp/pibox-check

# 9. Размер образа — записать в NOTES.md
docker images pibox:latest

# 10. Коммит
git add Dockerfile entrypoint.sh docs/NOTES.md
git commit -m "feat(image): multi-stage Dockerfile (task 3): ubuntu 24.04 + node 22 + pi + mise + /opt/skel"
```

CI из задачи 2 (`shellcheck` + `docker build`) прогоняется без изменений — GitHub-раннеры используют Docker с BuildKit по умолчанию.

---

## 6. ✅ Критерии готовности

- [ ] `docker build -t pibox:latest .` проходит без ошибок и предупреждений о несуществующих пакетах
- [ ] `pi`, `node`, `npm`, `mise`, `gosu`, `tini`, `jq`, `yq`, `rg`, `xxd` — в `PATH` (проверка 3)
- [ ] `pi --version` работает и от root, и через `--user pi` (проверка 6)
- [ ] `id pi` → `uid=1000(pi)`; `/opt/skel` существует с тремя дотфайлами (проверка 4)
- [ ] `/home/pi` не содержит установок инструментов (проверка 3)
- [ ] В образе нет `gcc/gdb/rustc/cmake` (проверка 5)
- [ ] `host.docker.internal` резолвится с `--add-host` (проверка 7)
- [ ] Вложенные bind-mount работают; skel-merge через `cp -rn` продемонстрирован (проверка 8)
- [ ] Размер образа зафиксирован в `docs/NOTES.md`
- [ ] `shellcheck entrypoint.sh` чист; CI зелёный
- [ ] `docs/NOTES.md` обновлён: версии, закрытые TODO, замечания (yq, PEP 668, npm-префикс для задачи 4)

---

## 7. ⚠️ Подводные камни

1. **`ENV PATH="...:$PATH"` — ловушка.** В ubuntu-образе `PATH` не объявлен как ENV, поэтому подстановка разворачивается в пустую строку → `PATH="…:"` без системных путей, образ «сломан» (нет `/usr/bin`). `PATH` всегда прописывается явным полным списком.

2. **Глобальные ARG видны только в `FROM`.** ARG, объявленный до первого `FROM`, внутри stage недоступен — его нужно **повторно объявить** в stage (`ARG PI_VERSION` в runtime сделан именно ради `LABEL`). Забудешь — получите пустую метку или ошибку.

3. **`set -e` + `[ ... ] && cmd`.** Конструкция `[ "$arch" = "amd64" ] && arch="x64"` на arm64 вернёт код 1 и **убьёт RUN** (сбой левой части `&&`-цепочки). Только `if/fi` — как в Dockerfile выше.

4. **Направление совместимости glibc.** Бинарники из builder работают в runtime только если glibc builder ≤ glibc runtime: bookworm (2.36) → noble (2.39) ✅; trixie (2.41) → noble ❌ (`version 'GLIBC_2.41' not found`). Пин баз через явные теги (`node:22-bookworm-slim`) обязателен.

5. **Имя mise-ассета и структура tarball.** URL и содержимое архива проверяются вручную на releases-странице (шаг 1); RUN устойчив к двум布局 (бинарник в корне / в каталоге), но не к переименованию ассета — тогда правится шаблон URL.

6. **BuildKit обязателен** (heredoc `COPY <<EOF`, `--chmod`): Docker 23+ — по умолчанию; на 20.10–22 — `DOCKER_BUILDKIT=1 docker build …`. Это требование записать в NOTES (попадёт в README задачи 9).

7. **Не добавлять apt-пакеты `nodejs`/`npm`.** Появится второй node в `/usr/bin` рядом с `/usr/local/bin/node` из builder — конфликт версий и «какой node реально выполняется». Единственный источник Node — builder.

8. **PEP 668.** Глобальный `pip install` в Ubuntu 24.04 заблокирован (`externally-managed-environment`). Это норма: агенту — venv (`python3-venv` установлен). Замечание уже в NOTES — задача 4 отразит в документации окружения.

9. **Вкус `yq`.** apt-версия — Python-обёртка (синтаксис `yq '.a.b'` = jq-фильтры). Go-yq mikefarah имеет другой CLI. Если команде нужен Go-yq — решение фиксируется отдельной записью в NOTES и заменой установки на бинарник с GitHub.

10. **`npm i -g` от пользователя pi невозможен** (префикс `/usr/local` принадлежит root). Это передано задаче 4: кандидат — `~/.npmrc` с `prefix=~/.local` в env-template (установки персистентны и без root). На уровне образа `npm_config_prefix` НЕ задавать.

11. **`WORKDIR` после снимка `/opt/skel`** — иначе в эталон попадёт пустая директория `workspace/` (косметика, но контракт «skel = только дотфайлы» чище без неё).

---

## 8. 🔗 Контракты, зафиксированные задачей 3

| Контракт | Значение |
|---|---|
| Пользователь | `pi`, UID/GID 1000 (сборочный дефолт), shell `/bin/bash` |
| Эталонный home | `/opt/skel` — снимок `/home/pi` (`.bashrc`, `.profile`, `.bash_logout`) |
| Entrypoint | `/entrypoint.sh`, exec-стиль; `CMD ["pi"]`; переопределяется аргументами |
| ENV образа | `HOME=/home/pi`, явный `PATH` с mise-shims, `MISE_YES=1`, `LANG/LC_ALL=en_US.UTF-8` |
| Инструменты | `pi`, `node`, `npm`, `mise`, `gosu`, `tini` — глобально, в `PATH` |
| Данные mise | `~/.local/share/mise` (внутри home → персистентны через env) |
| Workspace | `/home/pi/workspace` (WORKDIR; перекрывается bind-mount'ом при запуске) |

**Что получают следующие задачи:**

| Задача | Получает |
|---|---|
| **4 (env-template)** | контракт дотфайлов: env-template каноничен, skel-фолбэк минимально достаточен; `models.json` в skel НЕ входит; кандидат `~/.npmrc` с `prefix=~/.local`; факт PEP 668 для документации |
| **5 (entrypoint)** | passthrough для полной замены; готовые `gosu`/`tini`; ENV-контракт выше; механика skel-merge проверена (проверка 8) |
| **6 (run.sh)** | имя образа по умолчанию `pibox:latest` (переопределяется `PIBOX_IMAGE`); требование `--add-host` и caps подтверждено работоспособностью образа |
| **8 (тесты)** | готовый набор проверок 2–8 как основа smoke-сценариев |
| **9 (README)** | TODO-метку в LABEL (`image.source`); требования к Docker (версия, BuildKit) из NOTES |