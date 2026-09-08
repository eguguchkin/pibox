# Задача 9 — README и финализация (релиз-состояние)

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent: `/home/pi` контейнера — смонтированный с хоста env-каталог, текущий каталог — `workspace` агента, состояние персистентно. Все задачи 1–8 выполнены: образ, CLI, установщик, entrypoint, тесты. |
| **Цель задачи** | Финальный README (по нему новый пользователь разворачивает проект за ≤10 минут), LICENSE, CHANGELOG, синхронизация версий, проверка на секреты, git-тег первого релиза. |
| **Зависимости** | Все задачи 1–8; особенно задача 8 (находки для Troubleshooting, критерий «тест на коллеге») и задача 3 (TODO в LABEL) |
| **Артефакты** | `README.md` (полный), `LICENSE`, `CHANGELOG.md`, правки `run.sh`/`tests/smoke.sh`/`Dockerfile`, раздел 13 в `docs/NOTES.md`, тег `v1.0.0` |

---

## 🏗️ Ключевые архитектурные решения

| # | Решение | Обоснование |
|---|---|---|
| 1 | **README на русском** | Вся документация проекта и аудитория — русскоязычные; английская версия — welcome-to-contribute, но не блокер релиза |
| 2 | **Честная документация ограничений** | `update`/`doctor` — заглушки (документирован реальный путь обновления); capabilities, порты <1024, пробелы в `--` — прямо в README. README не обещает больше, чем делает код |
| 3 | **Версия — константа в коде, не `git describe`** | Установленный `bin/pibox` живёт вне git-репозитория — derive из git невозможен после install. Константа + синхронный патч smoke-теста C2 |
| 4 | **`PIBOX_IMAGE` в run.sh** | Обещано планом задачи 6, реализовано в smoke.sh (задача 8) — выравниваем run.sh (тесты смогут гонять произвольный тег против CLI, а не только против docker run) |
| 5 | **README включает находки задачи 8** | Troubleshooting построен на реальных багах, найденных тестами, а не на гипотетических — документация проверяема |

---

## 1. `README.md` — полный текст

`````markdown
# PIBOX

> **[Pi Coding Agent](https://pi.dev/) в изолированном Docker-контейнере** —
> с сохранением сессий, конфигов и тулчейнов между запусками.

## Что это и зачем

Pi Coding Agent — минималистичный терминальный AI-агент для разработки: четыре
инструмента (`read`, `write`, `edit`, `bash`), древовидные сессии, расширения и
скиллы. Давать такому агенту прямой доступ к файловой системе хоста и API-ключам
рискованно: одна неудачная команда `bash` может стоить данных.

PIBOX запускает агента в контейнере и решает три задачи:

- **Изоляция.** Файловые операции агента ограничены двумя монтированиями —
  рабочим проектом и его собственным окружением. UID/GID агента динамически
  подстраиваются под пользователя хоста: файлы, созданные агентом, принадлежат
  вам, а не root.
- **Персистентность.** `/home/pi` контейнера — это каталог `env/<имя>` на хосте.
  Сессии, конфиги, расширения и установленные тулчейны переживают перезапуск.
  Несколько изолированных окружений (`default`, `php8`, `rust`…) переключаются
  одной опцией.
- **Компактный образ.** Multi-stage сборка (~0.7 ГБ): в образе только Pi,
  Node.js и базовые утилиты. Тяжёлые тулчейны агент ставит сам через
  [mise](https://mise.jdx.dev/) в `~/.local` — и они сохраняются в окружении.

### Как это устроено

```
ХОСТ-МАШИНА                                КОНТЕЙНЕР pibox:latest
┌───────────────────────────┐              ┌───────────────────────────────┐
│ ~/my-project              │  bind-mount  │ /home/pi/workspace            │
│ (текущий каталог)         │─────────────►│  агент стартует здесь         │
│                           │              │                               │
│ ~/pibox/env/<name>        │  bind-mount  │ /home/pi (весь home)          │
│  ├ .pi/agent/sessions/    │─────────────►│  сессии, конфиги, скиллы      │
│  ├ .pi/agent/models.json  │              │                               │
│  ├ .local/share/mise/     │              │ entrypoint (от root):         │
│  ├ .bashrc  .gitconfig    │              │  1. UID/GID pi ← хост-юзер    │
│  └ ...                    │              │  2. skel-merge (1-й запуск)   │
│                           │              │  3. gosu → tini → pi          │
│ Model API :8080           │◄─────────────│ host.docker.internal:8080     │
└───────────────────────────┘              └───────────────────────────────┘
```

## Требования

| Требование | Проверка |
|---|---|
| Linux + Docker Engine **≥ 20.10** | `docker --version` |
| Пользователь в группе `docker` | `docker info` без ошибок |
| ~1.5 ГБ на образ + место под окружения | `df -h ~` |

- Node.js, Python и тулчейны **на хосте не нужны** — всё внутри контейнера.
- **macOS / Windows (Docker Desktop):** экспериментально — механика UID/GID
  рассчитана на Linux.

## Быстрый старт

```bash
# 1. Установка
git clone https://github.com/YOUR-USER/pibox.git
cd pibox
./install.sh                  # создаёт ~/pibox, добавляет bin в PATH

# 2. Настройте модели (ключ или адрес локального сервера)
${EDITOR:-vi} ~/pibox/env/models.json

# 3. Соберите образ
exec $SHELL -l                # перезагрузить PATH (или новый терминал)
pibox build                   # первый раз — несколько минут

# 4. Запустите агента в любом проекте
cd ~/my-project
pibox
```

Первый запуск инициализирует окружение `default`: merge эталонных dot-файлов,
копирование `models.json`. Если ключ не настроен — пройдите `/login` внутри Pi.

**Проверка, что всё работает:** в запущенном Pi выполните `ls` (bash-инструмент) —
видны файлы текущего проекта; создайте файл — на хосте он появится с вашим
владельцем, не root.

Каталог установки по умолчанию `~/pibox`; переопределяется `PIBOX_DIR` или
`install.sh -d ПУТЬ`.

## Использование

### Команды

| Команда | Описание |
|---|---|
| `pibox [run] [ОПЦИИ] [--] [PI_ARGS…]` | Запуск агента (run — по умолчанию) |
| `pibox build [--no-cache]` | Сборка Docker-образа |
| `pibox env list` | Список окружений |
| `pibox env create ИМЯ` | Создать окружение из шаблона |
| `pibox env remove ИМЯ` | Удалить окружение (**без подтверждения**; `default` защищён) |
| `pibox shell [-e ИМЯ]` | Отладочная bash-оболочка в контейнере |
| `pibox --help` / `--version` | Справка / версия |

`pibox update` и `pibox doctor` — заглушки. Обновление:

```bash
cd pibox && git pull && ./install.sh --force
```

### Опции запуска

| Опция | По умолчанию | Описание |
|---|---|---|
| `-e, --env ИМЯ` | `default` | Окружение; создаётся автоматически при отсутствии |
| `-p, --publish SPEC` | — | Проброс порта, повторяемая (`-p 3000:3000`) |
| `-E, --pass-env VAR` | — | Проброс переменной окружения, повторяемая |
| `--env-file FILE` | — | Файл переменных окружения |
| `--memory LIMIT` | `4g` | Лимит памяти контейнера |
| `--cpus N` | `2` | Лимит CPU |
| `--pids-limit N` | `512` | Лимит процессов |
| `--git-safe` | выкл | `git safe.directory` для workspace |
| `--resync-skel` | выкл | Повторный merge эталонных dot-файлов |
| `--dry-run` | — | Напечатать `docker run` без запуска |
| `--name ИМЯ` | auto | Имя контейнера |

Всё после `--` передаётся Pi: `pibox -- pi -p "объясни этот код"`.

### Примеры

```bash
pibox                          # default-окружение в текущем проекте
pibox -e php8                  # отдельное окружение (создастся из шаблона)
pibox -p 3000:3000             # dev-сервер в контейнере → localhost:3000
pibox -E ANTHROPIC_API_KEY     # ключ из окружения хоста
pibox --git-safe               # включить safe.directory для workspace
pibox shell -e php8            # оболочка для отладки окружения
pibox --dry-run -p 8080:8080   # посмотреть итоговую docker-команду
```

### Обновление и удаление

- **Обновление:** `git pull && ./install.sh --force` — обновит CLI, build-контекст
  и env-template; существующие окружения и `env/models.json` не затрагиваются
  (кроме `models.json` — он перезаписывается, сохраните копию, если настраивали).
- **Удаление:** `rm -rf ~/pibox` и удалить блок `>>> pibox installer >>>` из
  `~/.bashrc` / `~/.zshrc`.

## Окружения

### Жизненный цикл

- Запуск с несуществующим `-e ИМЯ` → окружение **создаётся автоматически** из
  `~/pibox/env-template/`, в него копируется `models.json`.
- Окружение = каталог `~/pibox/env/ИМЯ`, монтируемый как `/home/pi`. Всё, что
  агент ставит или меняет в home, живёт там.
- `env remove` удаляет окружение целиком.
- `install.sh --force` **не трогает** существующие окружения.

### Что хранится в окружении

| Путь | Содержимое |
|---|---|
| `.pi/agent/sessions/` | Древовидные сессии `.jsonl` |
| `.pi/agent/models.json` | Конфиг моделей (копия при первом запуске) |
| `.pi/agent/{extensions,skills,prompts,themes}/` | Кастомизации Pi |
| `.pi/agent/AGENTS.md` | Инструкции агенту для этого окружения |
| `.local/share/mise/` | **Тулчейны mise — персистентны** |
| `.local/lib/node_modules/` | Глобальные npm-пакеты (prefix `~/.local`) |
| `.bashrc`, `.profile`, `.gitconfig`, `.tmux.conf` | Dot-файлы (из шаблона) |

### Тулчейны через mise

Тяжёлых тулчейнов (gcc, rust, go, gdb, cmake…) **нет в образе**. Агент ставит их сам:

```bash
# внутри pibox shell или сам агент:
mise use -g golang@latest     # → ~/.local/share/mise
go version                    # работает и после перезапуска контейнера
```

## Модели и API-ключи

### models.json

Шаблон — `~/pibox/env/models.json`; при первом запуске окружения копируется в
`env/ИМЯ/.pi/agent/models.json`. Пример (локальный OpenAI-совместимый сервер):

```json
{
  "providers": {
    "local": {
      "name": "Local Model API",
      "baseUrl": "http://host.docker.internal:8080/v1",
      "type": "openai",
      "apiKey": "REPLACE_ME",
      "models": [
        { "id": "local-model", "name": "Local Model", "maxTokens": 4096 }
      ]
    }
  },
  "defaultProvider": "local",
  "defaultModel": "local-model"
}
```

`host.docker.internal` внутри контейнера указывает на хост: локальный API на
`localhost:8080` доступен как `http://host.docker.internal:8080`.

### Ключи

- **Через переменные окружения** (рекомендуется): `pibox -E ANTHROPIC_API_KEY`
  или `--env-file .env` — ключи не оседают в файлах окружения.
- **Через `models.json`** — для локальных серверов и кастомных провайдеров.
- **OAuth-подписки** (Anthropic/OpenAI/Copilot): запустите `pibox`, выполните `/login`.

Распространённые переменные: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GOOGLE_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`.

## Безопасность

### Что даёт контейнер

- **Изоляция ФС:** агент видит только `workspace` и своё окружение.
- **UID/GID:** файлы агента принадлежат пользователю хоста; entrypoint
  отказывается работать с UID=0.
- **Лимиты ресурсов:** memory/cpus/pids.
- **Защита конфигов pibox:** запуск из `~/pibox` (или вложенных каталогов)
  блокируется — агент не может редактировать собственную обвязку.

### Чего контейнер НЕ даёт

⚠️ **Контейнер — не полная песочница.** Оцените модель угроз:

- **Сеть открыта.** У контейнера есть интернет и локальная сеть — агент может
  делать HTTP-запросы.
- **Capabilities.** Добавлены `SYS_PTRACE` и `NET_RAW` (для strace/gdb/tcpdump) —
  это расширение прав относительно обычного контейнера.
- **Код расширений выполняется с правами агента.** Ставьте только проверенные
  расширения/скиллы; ключи передавайте через `-E`/`--env-file`, не храните в git.

## Решение проблем

| Симптом | Решение |
|---|---|
| git: `detected dubious ownership` | Владелец workspace ≠ UID контейнера. Запускайте `pibox --git-safe` — включает `safe.directory`, не трогая ваши файлы |
| `bind: permission denied` на порту <1024 | У агента нет `CAP_NET_BIND_SERVICE`. Сервер внутри — на порт >1024, наружу любой: `-p 80:8080` |
| `host.docker.internal` не резолвится | Docker < 20.10 — обновите Docker |
| `strace -p PID` / `tcpdump` от pi падают | Известное ограничение: gosu сбрасывает capabilities при смене UID. `ping` и трассировка собственных потомков работают; детали — `docs/NOTES.md` |
| `pibox: command not found` после install | PATH обновился — `exec $SHELL -l` или новый терминал |
| `bad interpreter: /usr/bin/env^M` | CRLF в скриптах: `git add --renormalize .` (`.gitattributes` настроен) |
| Файлы в workspace принадлежат root | Запускали `docker run` вручную без `-e HOST_UID`? Всегда через `pibox` |
| `pip install` падает (`externally-managed`) | PEP 668 в Ubuntu 24.04 — используйте venv: `python3 -m venv .venv && . .venv/bin/activate` |
| `npm install -g` и root? | Не нужен: `~/.npmrc` задаёт prefix `~/.local`. Без sudo |
| Первый запуск долгий | Норма: сборка образа + mise качает тулчейны. Дальше — из окружения |
| Аргументы после `--` с пробелами искажаются | Известное ограничение CLI. Сложные команды — через `pibox shell` |
| Медленный старт после смены юзера хоста | `find` по env чинит ownership при смене UID; на стабильном хосте не выполняется |

## Разработка

### Структура репозитория

```
pibox/
├── Dockerfile          # multi-stage: ubuntu 24.04 + node 22 + pi + mise
├── entrypoint.sh       # UID/GID, skel-merge, gosu→tini→pi
├── run.sh              # исходник CLI (после install — ~/pibox/bin/pibox)
├── install.sh          # установщик
├── models.json         # шаблон конфига моделей
├── env-template/       # шаблон /home/pi для новых окружений
├── tests/
│   ├── smoke.sh        # ~90 автопроверок: install→build→CLI→runtime
│   └── ACCEPTANCE.md   # ручной чеклист приёмки
├── docs/
│   ├── NOTES.md        # технические факты, находки, зафиксированные версии
│   └── CONVENTIONS.md  # соглашения по коду
└── .github/workflows/ci.yml  # shellcheck + exec-биты + docker build
```

### Тесты

```bash
./tests/smoke.sh              # полный прогон (~2 мин при готовом образе)
./tests/smoke.sh --offline    # без интернет-проверок
./tests/smoke.sh --keep       # сохранить артефакты при FAIL
./tests/smoke.sh --rebuild    # пересобрать образ
PIBOX_IMAGE=pibox:test ./tests/smoke.sh

shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh   # как в CI
```

Ручная приёмка: `tests/ACCEPTANCE.md` — 7 сценариев (~30 мин).

### Обновление версий

В `Dockerfile` (ARG-параметры; выбор фиксируется в `docs/NOTES.md`):

| ARG | Что | Правило |
|---|---|---|
| `UBUNTU_VERSION` | базовый образ | пиновать LTS (`24.04`) |
| `NODE_IMAGE` | источник Node | мажор + distro; **glibc builder ≤ runtime** (bookworm ≤ noble — не trixie!) |
| `PI_VERSION` | `@earendil-works/pi-coding-agent` | точная версия |
| `MISE_VERSION` | mise | точная версия с GitHub Releases |

После смены: `pibox build --no-cache` + прогон smoke-тестов.

### Известные ограничения

Актуальный список с деталями — `docs/NOTES.md`, раздел 12: capabilities после
gosu, сборка CLI-команды в строку, порты <1024 и др.

## Лицензия

MIT — см. [LICENSE](LICENSE).
`````

> Замените `YOUR-USER` на реальный владельца репозитория **до** тегирования (два места: быстрый старт и Dockerfile LABEL ниже).

---

## 2. `LICENSE`

```text
MIT License

Copyright (c) 2026 <ИМЯ ВЛАДЕЛЬЦА>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. `CHANGELOG.md`

```markdown
# Changelog

## 1.0.0 — 2026-XX-XX

Первый релиз.

- Docker-образ `pibox:latest`: multi-stage (ubuntu 24.04 + Node 22 +
  Pi Coding Agent + mise), эталонный home в `/opt/skel`, ~0.7 ГБ.
- CLI `pibox`: `run` / `build` / `env` / `shell`; проброс портов и переменных
  (`-p`, `-E`, `--env-file`); лимиты ресурсов; `--git-safe`, `--resync-skel`,
  `--dry-run`.
- Окружения: `env-template`, автосоздание, персистентные тулчейны через mise,
  npm-пакеты в `~/.local`.
- `entrypoint.sh`: динамическая UID/GID, skel-merge с маркером, `gosu`+`tini`.
- `install.sh`: идемпотентная установка, обновление через `--force`.
- Тесты: smoke (~90 проверок, 4 фазы) + ручной чеклист приёмки.
- CI: shellcheck, exec-биты, docker build.

### Известные ограничения

- `pibox update` / `pibox doctor` — заглушки (обновление: `install.sh --force`).
- `strace -p` / `tcpdump` от pi: gosu сбрасывает capabilities (см. docs/NOTES.md).
- Серверы внутри контейнера: порты >1024.
- Аргументы с пробелами после `--` искажаются (CLI собирает команду в строку).
```

---

## 4. Release-правки к коду

### 4.1 `run.sh` — версия (ОБЯЗАТЕЛЬНО)

```bash
# Было:
VERSION="0.1.0"
# Стало:
VERSION="1.0.0"
```

### 4.2 `tests/smoke.sh` — C2 (ОБЯЗАТЕЛЬНО, синхронно с 4.1!)

Тест C2 захардкожен на старую версию — **правится в одном коммите с 4.1**:

```bash
# Было:
capture_eq "C2: pibox --version" "pibox 0.1.0" "$BIN" --version
# Стало:
capture_eq "C2: pibox --version" "pibox 1.0.0" "$BIN" --version
```

### 4.3 `run.sh` — поддержка `PIBOX_IMAGE` (ОБЯЗАТЕЛЬНО, обещано планом)

```bash
# Было:
IMAGE_NAME="pibox:latest"
# Стало (как в smoke.sh из задачи 8):
IMAGE_NAME="${PIBOX_IMAGE:-pibox:latest}"
```

### 4.4 `run.sh` — выравнивание `cmd_shell` (РЕКОМЕНДУЕТСЯ)

`shell` сейчас теряет `host-gateway` и capabilities — оболочка «слабее» агента
(нельзя проверить доступ к API). Минимальный патч:

```bash
# В cmd_shell заменить docker run на:
    docker run --rm -it \
        --add-host host.docker.internal:host-gateway \
        --cap-add SYS_PTRACE --cap-add NET_RAW \
        -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
        -v "$PIBOX_DIR/env/$env_name:/home/pi" \
        -v "$(pwd):/home/pi/workspace" \
        "$IMAGE_NAME" bash
```

### 4.5 `Dockerfile` — LABEL (ОБЯЗАТЕЛЬНО, TODO из задачи 3)

```dockerfile
# Было (задача 3):
LABEL org.opencontainers.image.title="pibox" \
      org.opencontainers.image.description="Pi Coding Agent in an isolated Docker sandbox" \
      org.opencontainers.image.version="${PI_VERSION}+pibox" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}"
# TODO(задача 9): добавить org.opencontainers.image.source и .licenses

# Стало:
LABEL org.opencontainers.image.title="pibox" \
      org.opencontainers.image.description="Pi Coding Agent in an isolated Docker sandbox" \
      org.opencontainers.image.version="${PI_VERSION}+pibox" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/YOUR-USER/pibox"
```

(строку TODO удалить; `YOUR-USER` заменить на реальный путь репозитория).

---

## 5. Проверки перед релизом

### 5.1 Секреты

```bash
# История коммитов — паттерны ключей
git log -p | grep -inE "sk-ant-|sk-[A-Za-z0-9]{20,}|API[_-]?KEY[[:space:]]*[:=][[:space:]]*['\"][^'\"]{8,}" \
  && echo "ОБНАРУЖЕНЫ СЕКРЕТЫ — не тегировать!" || echo "OK: история чиста"

# Рабочее дерево
grep -rnE "sk-ant-|sk-[A-Za-z0-9]{20,}" --exclude-dir=.git . \
  && echo "ОБНАРУЖЕНЫ СЕКРЕТЫ" || echo "OK: дерево чисто"

# Шаблон models.json — только плейсхолдеры
grep -q "REPLACE_ME" models.json && echo "OK: models.json — плейсхолдер"
```

### 5.2 Качество

```bash
shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh   # 0 замечаний
git ls-files -s '*.sh'                                       # все 100755
git check-attr eol -- run.sh entrypoint.sh Dockerfile        # lf
grep -rn "TODO" Dockerfile                                    # TODO из задачи 3 закрыт
```

### 5.3 Smoke (с релизными правками)

```bash
./tests/smoke.sh          # PASS; единственный KNOWN-ISSUE — R15 (caps), как в задаче 8
```

Если падает **C2** — забыли патч 4.2; если образ пересобирается и ругается на LABEL —
синтаксис в 4.5.

### 5.4 «Тест на коллеге» (критерий из плана)

Человек, не участвовавший в разработке, **только по README**:

1. клонирует репозиторий → `./install.sh`;
2. настраивает `models.json` (или получает тестовый ключ);
3. `pibox build` → `cd ~/any-project && pibox` → задаёт агенту вопрос.

**Бюджет: ≤10 минут.** Если коллега спотыкается на шаге — это дефект README, а не
коллеги: уточнить формулировку и повторить. Результат (время, спотыкания) — в NOTES.

---

## 6. Релиз: коммит и тег

```bash
git add -A
git commit -m "docs: README, LICENSE, CHANGELOG; release 1.0.0 (task 9)

- full user + dev documentation (quick start, CLI, envs, models, security,
  troubleshooting, development)
- version alignment: run.sh/install.sh 1.0.0 (+ smoke C2)
- PIBOX_IMAGE support in run.sh; cmd_shell aligned with run
- Dockerfile LABELs completed (licenses, source)
- MIT LICENSE, CHANGELOG.md"

git tag -a v1.0.0 -m "pibox 1.0.0 — первый релиз"
git push origin main --tags
```

**Тег ставится только после зелёного smoke и чистой проверки секретов** — тег
это обещание воспроизводимости: `git checkout v1.0.0 && ./tests/smoke.sh` должен проходить.

---

## 7. Обновление `docs/NOTES.md` (раздел 13, в конец)

```markdown
## 13. Релиз 1.0.0 (задача 9)

- README.md: полный пользовательский и dev-документ (quick start, CLI,
  окружения, модели, безопасность, troubleshooting на находках задачи 8,
  разработка). Документирует ограничения честно (update/doctor — заглушки).
- LICENSE (MIT, плейсхолдеры владельца), CHANGELOG.md.
- Версия: run.sh = install.sh = 1.0.0; smoke C2 синхронизирован
  (правки в одном коммите — иначе C2 падает).
- run.sh: IMAGE_NAME читает PIBOX_IMAGE (выравнивание со smoke.sh и планом
  задачи 6); cmd_shell выровнен с cmd_run (host-gateway + caps).
- Dockerfile: LABEL дополнен (licenses, source) — TODO задачи 3 закрыт.
- Проверка секретов: история и дерево чисты (grep-паттерны sk-*).
- Финальный прогон smoke: PASS (N проверок; 1 KNOWN-ISSUE — R15 caps,
  критерий приёмки правки entrypoint из задачи 8).
- «Тест на коллеге»: <время> мин, спотыкания: <список или "нет">.
- Тег: v1.0.0.

Проект по плану задач 1–9 завершён.
```

---

## 8. ✅ Критерии готовности

- [ ] `README.md` содержит все 9 разделов плана (что/зачем, требования, быстрый старт, использование, окружения, модели, безопасность, troubleshooting, разработка) + лицензия
- [ ] «Тест на коллеге» пройден: развёртывание только по README ≤10 минут
- [ ] `LICENSE` (MIT) и `CHANGELOG.md` существуют; плейсхолдеры имени/URL заменены
- [ ] Версии синхронны: `run.sh` = `install.sh` = `1.0.0`; smoke **C2 зелёный**
- [ ] `PIBOX_IMAGE` работает: `PIBOX_IMAGE=pibox:test pibox --dry-run` подставляет тег
- [ ] Dockerfile LABEL без TODO; `docker inspect pibox:latest` показывает licenses/source
- [ ] Проверка секретов чиста (история + дерево + REPLACE_ME в models.json)
- [ ] `./tests/smoke.sh` — PASS после релизных правок; shellcheck чист; CI зелёный
- [ ] `git tag v1.0.0` создан и запушен
- [ ] `docs/NOTES.md` — раздел 13 заполнен (включая результат теста на коллеге)
- [ ] В README нет обещаний, которых код не выполняет (заглушки задокументированы как заглушки)

---

## 9. ⚠️ Подводные камни

| # | Проблема | Митигация |
|---|---|---|
| 1 | **Версия в 3 местах** (run.sh, install.sh, smoke C2) — рассинхрон красит C2 | Правки 4.1+4.2 в одном коммите; релизный чеклист: `grep -r '0\.1\.0'` перед тегом |
| 2 | **README обещает больше кода** (например, «pibox update обновит») — доверие к документации умирает | Все заглушки помечены; реальный путь обновления (`install --force`) документирован явно |
| 3 | **Плейсхолдеры в релизе** (`YOUR-USER`, `<ИМЯ ВЛАДЕЛЬЦА>`, дата в CHANGELOG) | Проверка `grep -rn "YOUR-USER\|ИМЯ ВЛАДЕЛЬЦА" --exclude-dir=.git .` перед тегом |
| 4 | **CI-бейдж с несуществующим URL** | Бейдж не включён в README; если добавляете — только на существующий workflow |
| 5 | **Тег до зелёного smoke** | Тег = обещание `git checkout v1.0.0 && ./tests/smoke.sh` проходит; прогонять до `git tag` |
| 6 | **CRLF ломает «тест на коллеге» на Windows** | `.gitattributes` из задачи 2 + `git add --renormalize .`; проверить `git ls-files --eol` |
| 7 | **Секреты в истории, не в дереве** | Проверяется именно `git log -p`; при находке — переписывание истории (filter-repo) до тега, не после |
| 8 | **LABEL-патч ломает сборку** (кавычки/переносы) | Проверка `docker build` входит в 5.2; CI-джоба build ловит |
| 9 | **Английская аудитория не прочитает русский README** | Осознанное решение (решение №1); README.en.md — post-release contribution, не блокер |
| 10 | **`pibox --version` после install отличается от `./run.sh --version`** | Не отличается: install копирует run.sh с подстановкой, VERSION — константа в файле; но после апгрейда репо без `install --force` будет рассинхрон — отражено в разделе «Обновление» |

---

## 10. 🎉 Итог: задачи 1–9 завершены

| # | Задача | Ключевой артефакт | Состояние |
|---|---|---|---|
| 1 | Ревизия зависимостей | `docs/NOTES.md` — версии Pi/Node/mise, пакеты, docker-факты | ✅ |
| 2 | Каркас репозитория | структура, `.gitattributes`/`.gitignore`, CI, конвенции | ✅ |
| 3 | Dockerfile | `pibox:latest` — multi-stage, `/opt/skel`, глобальные установки | ✅ |
| 4 | env-template | шаблон `/home/pi`: конфиги Pi, dot-файлы, mise/npm | ✅ |
| 5 | entrypoint.sh | UID/GID, skel-merge с маркером, `gosu`+`tini`, отказ от root | ✅ |
| 6 | run.sh → CLI | `run`/`build`/`env`/`shell`, изоляция workspace, `-p`/`-E`, лимиты | ✅ |
| 7 | install.sh | идемпотентная установка, `--force`-обновление, PATH-guard | ✅ |
| 8 | Тестирование | `smoke.sh` (~90 проверок) + `ACCEPTANCE.md`; найдены и закрыты регрессии | ✅ |
| 9 | README и релиз | документация, MIT, v1.0.0, тег | ✅ |

**Готовый пользовательский путь (то, что проверено smoke-тестами и ручной приёмкой):**

```bash
git clone … && ./install.sh    →  pibox build  →  cd ~/project && pibox
```

— агент в контейнере, файлы принадлежат пользователю, сессии и тулчейны
персистентны, конфиги pibox защищены от самого агента.

**Открытые направления после 1.0.0** (задокументированы, не блокируют релиз):
`pibox doctor`/`update` как полноценные команды; caps-патч entrypoint (`setpriv
--ambient-caps`, критерий приёмки — R15 зелёный); передача массива аргументов без
`eval` в run.sh; английский README.