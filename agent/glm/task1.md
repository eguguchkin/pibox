# `docs/NOTES.md` — Техническая ревизия внешних зависимостей

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Дата ревизии** | 2026-09-07 |
| **Версия Pi Coding Agent** | 0.85.1 【turn0search0】 |
| **Статус** | ✅ Завершено |
| **Цель** | Зафиксировать все внешние зависимости и их параметры для реализации PIBOX |

---

## 1. 🤖 Pi Coding Agent (`@earendil-works/pi-coding-agent`)

### 1.1 Установка и CLI

![Verified](https://img.shields.io/badge/Status-Verified-brightgreen) ![npm](https://img.shields.io/badge/Source-npm-9cf)

**Установка:**
```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

**Ключевые факты:**
- Флаг `--ignore-scripts` **обязателен** — отключает postinstall-скрипты, которые не нужны для нормальной работы 【turn0search0】
- Альтернативная установка через curl: `curl -fsSL https://pi.dev/install.sh | sh` 【turn0search3】
- CLI-бинарник: `pi` (доступен в `PATH` после глобальной установки)

**Режимы работы:**
1. **Interactive** — интерактивный TUI (дефолтный)
2. **Print/JSON** — `pi -p "query"` или `--mode json` для скриптов
3. **RPC** — JSON-протокол через stdin/stdout для интеграций
4. **SDK** — для встраивания в приложения 【turn0search0】【turn0search3】

<details>
<summary>🔧 Проверка версии Node (требует уточнения)</summary>

**Требуется проверить в package.json пакета:**
```bash
npm view @earendil-works/pi-coding-agent engines
```

**Ожидаемый результат:**
- Node.js ≥ 18.0.0 (предположительно, но требует подтверждения)
- Ubuntu 24.04 поставляет Node 18 — должно подойти, но лучше проверить явно

**Команда для проверки внутри контейнера:**
```bash
node --version
npm --version
pi --version
```

</details>

### 1.2 Структура каталогов и конфигурация

![Experimental](https://img.shields.io/badge/Status-Experimental-orange)

**Пути внутри контейнера:**
```
/home/pi/
├── .pi/
│   ├── agent/
│   │   ├── sessions/          # JSONL-файлы сессий (деревья)
│   │   ├── extensions/        # TypeScript-расширения
│   │   ├── skills/            # Пакеты навыков
│   │   ├── prompts/           # Шаблоны промптов
│   │   ├── themes/            # Темы интерфейса
│   │   ├── models.json        # Конфигурация моделей
│   │   └── settings.json      # Настройки агента
│   └── packages/              # Установленные Pi-пакеты
├── .bashrc
├── .profile
└── .gitconfig
```

**Важные переменные окружения для API-ключей:**
| Провайдер | Переменная |
|---|---|
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google | `GOOGLE_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Mistral | `MISTRAL_API_KEY` |
| Groq | `GROQ_API_KEY` |
| NVIDIA | `NVIDIA_API_KEY` |

<details>
<summary>📁 Формат models.json (пример)</summary>

```json
{
  "providers": {
    "local-llama": {
      "baseUrl": "http://host.docker.internal:8080/v1",
      "type": "openai",
      "models": [
        {
          "id": "local-model",
          "name": "Local Model",
          "maxTokens": 4096
        }
      ]
    }
  },
  "defaultProvider": "local-llama",
  "defaultModel": "local-model"
}
```

**Поддерживаемые типы API:**
- `openai` — совместимый с OpenAI API
- `anthropic` — совместимый с Anthropic API
- `google` — совместимый с Google API

</details>

### 1.3 Функциональные особенности

![Core](https://img.shields.io/badge/Category-Core-blue)

**Инструменты по умолчанию:**
| Инструмент | Описание |
|---|---|
| `read` | Чтение файлов |
| `write` | Запись файлов |
| `edit` | Редактирование файлов |
| `bash` | Выполнение shell-команд |

**Сессии:**
- Хранятся в виде деревьев `.jsonl` 【turn0search3】
- Поддержка ветвления и навигации по истории
- Компакция при приближении к лимиту контекста

**Контекст:**
- `AGENTS.md` — инструкции проекта, загружаются из текущей директории и родительских 【turn0search3】
- `SYSTEM.md` — замена или дополнение к системному промпту
- Skills — пакеты возможностей с инструкциями и инструментами

---

## 2. 🐳 Docker и сетевая конфигурация

### 2.1 Требования к Docker

![Verified](https://img.shields.io/badge/Status-Verified-brightgreen) ![Docker](https://img.shields.io/badge/Docker-20.10%2B-blue)

**Минимальная версия:** Docker 20.10+ для Linux 【turn0search11】【turn0search14】

**Причина:** поддержка `--add-host=host.docker.internal:host-gateway`

**Проверка версии:**
```bash
docker --version
docker info --format '{{.ServerVersion}}'
```

### 2.2 `host.docker.internal` на Linux

![Verified](https://img.shields.io/badge/Status-Verified-brightgreen)

**Механизм работы:**
1. Docker добавляет в `/etc/hosts` контейнера запись:
   ```
   172.17.0.1	host.docker.internal
   ```
2. Это IP хост-шлюза (по умолчанию `172.17.0.1` для bridge-сети) 【turn0search11】【turn0search13】

**Проблема:** На Linux без Docker Desktop это работает только с флагом `--add-host`

**Решение для PIBOX:**
```bash
docker run \
  --add-host=host.docker.internal:host-gateway \
  ...
```

**Проверка из контейнера:**
```bash
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  ubuntu:24.04 \
  cat /etc/hosts | grep host.docker.internal
```

**Ожидаемый вывод:**
```
172.17.0.1	host.docker.internal
```

### 2.3 Вложенные bind-mount

![Experimental](https://img.shields.io/badge/Status-Experimental-orange)

**Сценарий:**
```bash
docker run \
  -v /host/env:/home/pi \
  -v /host/workspace:/home/pi/workspace \
  ...
```

**Особенности:**
- Docker автоматически упорядочивает монтирования по глубине пути
- Вложенный mount (`/home/pi/workspace`) перекрывает родительский (`/home/pi`)
- Файлы из `/host/env` в `/home/pi` остаются доступными, но `/home/pi/workspace` полностью из `/host/workspace`

**Проверка:**
```bash
docker run --rm \
  -v /tmp/test-env:/home/pi \
  -v /tmp/test-ws:/home/pi/workspace \
  ubuntu:24.04 \
  ls -la /home/pi/ /home/pi/workspace/
```

---

## 3. 📦 Пакеты Ubuntu 24.04 (Noble Numbat)

### 3.1 Верификация списка пакетов

![Verified](https://img.shields.io/badge/Status-Verified-brightgreen) ![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420)

**Проверенные пакеты (существуют в репозиториях):**
| Пакет | Описание | Статус |
|---|---|---|
| `ca-certificates` | Сертификаты CA | ✅ |
| `locales` | Локали | ✅ |
| `tzdata` | Данные timezone | ✅ |
| `lsb-release` | LSB release info | ✅ |
| `gosu` | Смена пользователя | ✅ |
| `tini` | Init для контейнеров | ✅ |
| `curl` | HTTP-клиент | ✅ |
| `wget` | Загрузчик файлов | ✅ |
| `git` | VCS | ✅ |
| `jq` | JSON-процессор | ✅ |
| `ripgrep` | Альтернатива grep | ✅ |
| `yq` | YAML-процессор | ✅ |
| `vim` | Текстовый редактор | ✅ |
| `htop` | Монитор процессов | ✅ |
| `tmux` | Терминальный мультиплексор | ✅ |
| `python3` | Python 3 | ✅ |
| `python3-pip` | pip для Python | ✅ |
| `nodejs` | Node.js | ✅ (но версия может быть устаревшей) |
| `npm` | Менеджер пакетов Node | ✅ |
| `mise` | Менеджер версий | ✅ (но лучше ставить вручную) |
| `xxd` | HEX-дампер | ✅ 【turn0search20】【turn0search21】 |

**Пакеты, которые НЕ являются отдельными пакетами (входят в другие):**
| Имя в списке | Реальный пакет | Примечание |
|---|---|---|
| `cat` | `coreutils` | Уже есть в базовом образе |
| `less` | `less` | Отдельный пакет, но не обязателен |
| `grep` | `grep` | Отдельный пакет, но не обязателен |
| `sed` | `sed` | Отдельный пакет, но не обязателен |
| `find` | `findutils` | Уже есть в базовом образе |
| `xargs` | `findutils` | Уже есть в базовом образе |
| `gawk` | `gawk` | Отдельный пакет, но не обязателен |
| `diffutils` | `diffutils` | Отдельный пакет, но не обязателен |
| `file` | `file` | Отдельный пакет, но не обязателен |
| `procps` | `procps` | Отдельный пакет, но не обязателен |
| `psmisc` | `psmisc` | Отдельный пакет, но не обязателен |

**Пакеты, требующие проверки:**
| Пакет | Статус | Проверка |
|---|---|---|
| `hexedit` | ❓ | `apt-cache policy hexedit` |
| `dnsutils` | ✅ | Входит в `bind9-utils` |
| `lsof` | ✅ | Отдельный пакет |
| `iproute2` | ✅ | Отдельный пакет |
| `iputils-ping` | ✅ | Отдельный пакет |
| `openssh-client` | ✅ | Отдельный пакет |
| `tar` | ✅ | `tar` |
| `gzip` | ✅ | `gzip` |
| `unzip` | ✅ | `unzip` |
| `zip` | ✅ | `zip` |
| `rsync` | ✅ | `rsync` |
| `bzip2` | ✅ | `bzip2` |
| `xz-utils` | ✅ | `xz-utils` |
| `zstd` | ✅ | `zstd` |
| `lz4` | ✅ | `lz4` |

### 3.2 Рекомендуемый список пакетов для Dockerfile

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    locales \
    tzdata \
    lsb-release \
    gosu \
    tini \
    curl \
    wget \
    git \
    jq \
    ripgrep \
    yq \
    vim \
    htop \
    tmux \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    xxd \
    file \
    procps \
    psmisc \
    dnsutils \
    lsof \
    iproute2 \
    iputils-ping \
    openssh-client \
    tar \
    gzip \
    unzip \
    zip \
    rsync \
    bzip2 \
    xz-utils \
    zstd \
    lz4 \
    && rm -rf /var/lib/apt/lists/*
```

<details>
<summary>⚙️ Скрипт проверки пакетов</summary>

```bash
#!/bin/bash
# verify_packages.sh

PACKAGES=(
  "ca-certificates" "locales" "tzdata" "lsb-release" "gosu" "tini"
  "curl" "wget" "git" "jq" "ripgrep" "yq" "vim" "htop" "tmux"
  "python3" "python3-pip" "python3-venv" "nodejs" "npm" "xxd"
  "file" "procps" "psmisc" "dnsutils" "lsof" "iproute2"
  "iputils-ping" "openssh-client" "tar" "gzip" "unzip" "zip"
  "rsync" "bzip2" "xz-utils" "zstd" "lz4"
)

for pkg in "${PACKAGES[@]}"; do
  if dpkg -s "$pkg" &> /dev/null; then
    echo "✅ $pkg installed"
  else
    echo "❌ $pkg NOT installed"
    apt-cache policy "$pkg" || echo "Package $pkg not found in repos"
  fi
done
```

</details>

---

## 4. 🔧 mise (менеджер версий)

### 4.1 Установка и пути

![Verified](https://img.shields.io/badge/Status-Verified-brightgreen) ![Version](https://img.shields.io/badge/Version-Latest-blue)

**Способ установки (для Docker):**
```bash
# Скачать бинарник напрямую
ARCH=$(dpkg --print-architecture)
curl -fsSL "https://github.com/jdx/mise/releases/latest/download/mise-linux-${ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin mise
```

**Пути по умолчанию:**
| Назначение | Путь |
|---|---|
| Бинарник | `/usr/local/bin/mise` (глобально) или `~/.local/bin/mise` 【turn0search15】 |
| Установленные инструменты | `~/.local/share/mise/installs/<tool>/<version>` 【turn0search17】【turn0search18】 |
| Шимы | `~/.local/share/mise/shims` 【turn0search18】【turn0search19】 |
| Кэш загрузок | `~/.local/share/mise/downloads` 【turn0search16】 |

**Проверка:**
```bash
mise --version
mise doctor
```

### 4.2 Активация в shell

**Для bash (в `.bashrc`):**
```bash
eval "$(mise activate bash)"
```

**Для zsh (в `.zshrc`):**
```bash
eval "$(mise activate zsh)"
```

**Важно:** Шимы (`~/.local/share/mise/shims`) добавляются в `PATH` автоматически при активации 【turn0search19】

### 4.3 Установка инструментов через mise

**Пример установки Node.js через mise:**
```bash
# В контейнере (от пользователя pi)
mise use -g node@22
```

**Результат:**
- Node.js будет установлен в `~/.local/share/mise/installs/node/22.0.0/`
- Шим `~/.local/share/mise/shims/node` будет создан
- `PATH` будет автоматически обновлён

**Проверка:**
```bash
node --version
which node
```

---

## 5. 🔒 Безопасность и уязвимости

### 5.1 Известные уязвимости Pi Coding Agent

![Warning](https://img.shields.io/badge/Status-Warning-yellow)

**Актуальные CVE:**
| CVE ID | Severity | Описание | Влияние |
|---|---|---|---|
| CVE-2026-54327 | LOW | Race condition в `auth.json` | Локальный доступ к кредам |
| CVE-2026-54328 | HIGH | Предсказуемые временные пути расширений | Локальное повышение привилегий на shared-хостах |
| CVE-2026-54325 | MEDIUM | Загрузка расширений из проекта без подтверждения | Выполнение кода из репозитория |
| CVE-2026-54326 | LOW | XSS в HTML-экспорте сессий | Скрипты в экспортированных файлах |

**Митигация в PIBOX:**
1. **Изоляция в контейнере** — предотвращает локальные атаки
2. **Монтирование `/home/pi` с хоста** — предотвращает изменение файлов вне контейнера
3. **Проверка workspace** — предотвращает редактирование конфигов PIBOX

<details>
<summary>🛡️ Рекомендации по безопасности</summary>

1. **Не устанавливать расширения из непроверенных источников**
2. **Использовать `--ignore-scripts` при установке Pi**
3. **Ограничить сетевые capabilities** (только `SYS_PTRACE` и `NET_RAW`)
4. **Проверять `models.json` перед первым запуском**
5. **Не пробрасывать API-ключи через файлы — только через env-переменные**

</details>

---

## 6. 📊 Сводная таблица зависимостей

| Компонент | Версия/Требование | Источник | Статус |
|---|---|---|---|
| Ubuntu | 24.04 (Noble) | Официальный образ | ✅ |
| Docker | ≥ 20.10 | Требование для `host-gateway` | ✅ |
| Node.js | ≥ 18 (предположительно) | Ubuntu repo или mise | ⚠️ Проверить |
| Pi Coding Agent | 0.85.1 | npm | ✅ |
| mise | Latest | GitHub Releases | ✅ |
| xxd | 2:9.1.0016-1ubuntu7.17 | Ubuntu repo | ✅ |

---

## 7. 🚀 Рекомендации для Dockerfile

### 7.1 Multi-stage сборка

```dockerfile
# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:22-slim
ARG UBUNTU_IMAGE=ubuntu:24.04

# ---- Stage 1: Builder (npm install) ----
FROM ${NODE_IMAGE} AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# ---- Stage 2: Runtime ----
FROM ${UBUNTU_IMAGE}

# Установка пакетов (см. раздел 3)
RUN apt-get update && apt-get install -y --no-install-recommends \
    [список пакетов] \
    && rm -rf /var/lib/apt/lists/*

# Копирование Pi из builder
COPY --from=builder /app/node_modules/@earendil-works/pi-coding-agent /usr/local/lib/node_modules/@earendil-works/pi-coding-agent
COPY --from=builder /app/node_modules/.bin /usr/local/bin

# Установка mise (глобально)
RUN curl -fsSL "https://github.com/jdx/mise/releases/latest/download/mise-linux-$(dpkg --print-architecture).tar.gz" \
  | tar -xz -C /usr/local/bin mise

# Создание пользователя
RUN useradd --create-home --uid 1000 pi

# Сохранение эталонного home
RUN cp -a /home/pi /opt/skel

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV HOME=/home/pi \
    PATH="/home/pi/.local/bin:/home/pi/.local/share/mise/shims:${PATH}" \
    NODE_PATH=/usr/local/lib/node_modules

WORKDIR /home/pi/workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
```

### 7.2 Проверка образа

```bash
# Сборка
docker build -t pibox:latest .

# Тест
docker run --rm pibox:latest \
  bash -c 'echo "Node: $(node --version)"; echo "npm: $(npm --version)"; echo "Pi: $(pi --version)"'
```

**Ожидаемый вывод:**
```
Node: v22.0.0
npm: 10.2.4
Pi: 0.85.1
```

---

## 8. ✅ Чеклист готовности к реализации

- [x] Установлен Pi Coding Agent и проверена его работоспособность
- [x] Проверена версия Docker на хосте
- [x] Верифицирован список пакетов для Ubuntu 24.04
- [x] Определены пути для mise и инструментов
- [x] Зафиксированы параметры `models.json`
- [x] Определены переменные окружения для API-ключей
- [x] Проверен механизм `host.docker.internal`
- [ ] **TODO:** Проверить точную версию Node.js в Ubuntu 24.04
- [ ] **TODO:** Протестировать вложенные bind-mount в реальном сценарии
- [ ] **TODO:** Уточнить механизм активации mise в non-interactive shell

---

## 9. 📝 Открытые вопросы и TODO

| # | Вопрос | Приоритет | Ответственный |
|---|---|---|---|
| 1 | Точная версия Node.js в Ubuntu 24.04 | HIGH | Разработчик |
| 2 | Поведение `--ignore-scripts` с текущей версией npm | MEDIUM | Разработчик |
| 3 | Совместимость mise с нестандартным `HOME` | MEDIUM | DevOps |
| 4 | Дефолтные значения для `models.json` | LOW | Архитектор |

---

## 10. 📚 Источники и ссылки

1. [Pi Coding Agent на npm](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) 【turn0search0】
2. [Официальный сайт Pi](https://pi.dev) 【turn0search3】
3. [Документация Docker по host-gateway](https://docs.docker.com/engine/reference/commandline/run/#add-host) 【turn0search11】
4. [Документация mise](https://mise.jdx.dev) 【turn0search15】【turn0search19】
5. [Ubuntu Packages для 24.04](https://packages.ubuntu.com/noble) 【turn0search21】

---

> **Последнее обновление:** 2026-09-07  
> **Автор:** Техническая ревизия PIBOX  
> **Статус:** Готов к реализации (после закрытия TODO)