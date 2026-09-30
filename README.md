# PIBOX

> **[Pi Coding Agent](https://pi.dev/) в изолированном Docker-контейнере** —
> с сохранением сессий, конфигов и тулчейнов между запусками.

**Что вы получаете:** AI-агента, который пишет и запускает код в вашем проекте,
но живёт в контейнере и не может дотянуться до остальной системы. Вы работаете
с ним в терминале, браузере или — прямо из Telegram.

---

## Зачем это нужно

Pi Coding Agent — минималистичный терминальный AI-агент для разработки: четыре
инструмента (`read`, `write`, `edit`, `bash`), древовидные сессии, расширения и
скиллы. Он полезен ровно настолько, насколько ему можно доверять файловую
систему и API-ключи. Дать агенту прямой доступ к хосту — риск: одна неудачная
команда `bash` может стоить данных, утёкший ключ — денег.

PIBOX убирает этот риск, не убирая удобства:

- **Изоляция.** Агент видит только два каталога: ваш проект и его собственное
  окружение. Остальная файловая система для него не существует. UID/GID агента
  подстраиваются под вас: файлы, созданные агентом, принадлежат вам, а не root.
- **Персистентность.** «Дом» агента (`/home/pi`) — это обычный каталог на
  хосте. Сессии, конфиги, расширения, установленные языки — всё переживает
  перезапуск контейнера. Как обычная папка — потому что это обычная папка.
- **Окружения под задачи.** Хотите отдельное окружение для PHP-проекта, для
  Rust-экспериментов, для «грязных» проб? `pibox -e php8` — и у агента чистый
  дом с собственной историей.
- **Три интерфейса.** Терминал (`pibox`), браузер (`pibox webui`) и Telegram
  (`pibox tg`) — работают с одними и теми же сессиями и моделями.

### Как выглядит изнутри

```text
ХОСТ-МАШИНА                                КОНТЕЙНЕР pibox:latest
┌───────────────────────────┐              ┌───────────────────────────────┐
│ ~/my-project              │  bind-mount  │ /home/pi/workspace/my-project │
│ (текущий каталог)         │─────────────►│  агент стартует здесь         │
│                           │              │                               │
│ ~/pibox/env/<name>        │  bind-mount  │ /home/pi (весь home)          │
│  ├ .pi/agent/sessions/    │─────────────►│  сессии, конфиги, скиллы      │
│  ├ .pi/agent/models.json  │              │                               │
│  ├ .local/share/mise/     │              │ entrypoint (от root):         │
│  ├ .bashrc  .gitconfig    │              │  1. UID/GID pi ← хост-юзер    │
│  └ ...                    │              │  2. dotfiles-слои (всегда)    │
│                           │              │  3. gosu → tini → pi          │
│ Model API :8080           │◄─────────────│ host.docker.internal:8080     │
└───────────────────────────┘              └───────────────────────────────┘
```

Образ компактный (~1.5 ГБ, multi-stage): только Pi, Node.js и базовые утилиты.
Тяжёлые тулчейны агент ставит сам через [mise](https://mise.jdx.dev/) — прямо
в своё окружение, где они и сохраняются.

---

## Сценарии использования

### Сценарий 1. «Поработать с агентом над проектом» — терминал

```bash
cd ~/my-project
pibox                    # TUI агента; окружение default создаётся само
```

Вы внутри привычного проекта: агент читает и правит файлы, запускает тесты,
поднимает dev-сервер. Всё, что он создал, сразу лежит на хосте с вашим
владельцем. Вышли (`/exit`) — контейнер удалился, проект и сессии остались.

Проверить, что всё работает, можно за минуту: в запущенном Pi выполните `ls` —
видны файлы проекта; создайте файл — на хосте он появится с вашим владельцем,
не root.

### Сценарий 2. «Те же сессии, но с телефона/планшета» — браузер

```bash
pibox webui               # откроет http://localhost:8787 в браузере
```

Браузерный UI ([pi-web-ui](https://github.com/xing-shuyin/pi-web-ui), вшит в
образ) показывает те же сессии и модели, что и TUI — переключайтесь между
терминалом и браузером когда угодно. Логи агента идут в консоль, `Ctrl+C` —
остановка. Из локальной сети — с токеном (см. «Решение проблем»).

### Сценарий 3. «Поставить задачу из метро и забрать отчёт» — Telegram

```bash
# однажды: создайте бота у @BotFather и впишите токен
vi ~/pibox/template/user/.pi/agent/telegram.json

# и запускайте мост:
pibox tg                  # агент без TUI: задания и отчёты через бота
```

Контейнер поднимает RPC-демон pi с включённым Telegram-мостом
(`@llblab/pi-telegram`): вы пишете боту задание с телефона — агент работает в
проекте, стримит прогресс и присылает результат; файлы (отчёты, скриншоты,
скрипты) приходят вложениями. Порт не публикуется — мост сам ходит наружу.

Если провайдер закрывает `api.telegram.org` — добавьте SOCKS5-прокси, он
подхватится автоматически:

```bash
PIBOX_TELEGRAM_PROXY='socks5h://user:pass@host:1080' pibox tg
```

На сервере удобно держать мост постоянно: он живёт, пока жив контейнер, а после
падения контейнера достаточно его перезапустить — мост восстановит сессию и
очередь заданий сам.

### Сценарий 4. «Эксперименты — отдельно, проект — отдельно» — окружения

```bash
pibox -e rust             # чистое окружение под именем rust
pibox shell -e rust       # заглянуть внутрь руками
```

Окружение — это просто каталог `~/pibox/env/ИМЯ`, монтируемый как `/home/pi`.
Имя — произвольная метка, а не готовый стек: скажете агенту «поставь PHP» —
он поставит (через mise) и инструмент останется в этом окружении навсегда.
Сессии, память и расширения у окружений не пересекаются.

### Сценарий 5. «Агенту нужен доступ к локальному API/БД»

Локальный сервис на хосте (LM Studio, Ollama, БД) агенту виден как
`host.docker.internal:PORT`:

```bash
# сервер на localhost:8080 хоста → из контейнера:
curl http://host.docker.internal:8080/v1/models
```

А если агент поднимает dev-сервер — опубликуйте порт наружу:
`pibox -p 3000:3000` → `localhost:3000` на хосте.

---

## Установка

Требования: Linux + Docker Engine ≥ 20.10, bash ≥ 3.2, пользователь в группе
`docker`, ~1.5 ГБ на образ. Node.js и тулчейны на хосте **не нужны** — всё
внутри контейнера. macOS/Windows (Docker Desktop) — экспериментально:
механика UID/GID рассчитана на Linux.

```bash
# 1. Установка
git clone https://github.com/eguguchkin/pibox.git
cd pibox
./install.sh                  # создаёт ~/pibox, добавляет bin в PATH

# 2. Настройте модели (ключ или адрес локального сервера)
${EDITOR:-vi} ~/pibox/template/user/.pi/agent/models.json

# 3. Соберите образ
exec $SHELL -l                # перезагрузить PATH (или новый терминал)
pibox build                   # первый раз — несколько минут

# 4. Установите набор расширений (опционально; несколько минут)
pibox extensions install      # список — в ~/pibox/template/extensions.txt

# 5. Запустите агента в любом проекте
cd ~/my-project
pibox
```

Если ключ не настроен — пройдите `/login` внутри Pi (OAuth-подписки
Anthropic/OpenAI/Copilot). Каталог установки по умолчанию `~/pibox`;
переопределяется `PIBOX_DIR` или `install.sh -d ПУТЬ`.

### Модели и API-ключи

- **Через переменные окружения** (рекомендуется): `pibox -E ANTHROPIC_API_KEY`
  или `--env-file .env` — ключи не оседают в файлах окружения.
  Распространённые: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`,
  `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`.
- **Через `models.json`** (шаблон в `~/pibox/template/user/.pi/agent/`,
  применяется при каждом запуске) — для локальных серверов и кастомных
  провайдеров. Пример локального OpenAI-совместимого сервера:

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

- **OAuth-подписки:** `pibox` → `/login`.

---

## Справочник команд

### Основные

| Команда | Описание |
| --- | --- |
| `pibox [run] [ОПЦИИ] [--] [PI_ARGS…]` | Запуск агента в TUI (run — по умолчанию) |
| `pibox webui [ОПЦИИ] [--port N]` | Агент с браузерным UI: пробрасывает порт (по умолчанию `8787:8787`), сам открывает страницу (готовность порта ждёт фоновый waiter; `--no-open` отключает), печатает зелёную ссылку; логи агента — в консоль. Опции как у run; `--port N` — другой порт (хост и контейнер) |
| `pibox tg [ОПЦИИ]` | Контейнер в режиме Telegram-моста: RPC-демон pi без TUI, задания и отчёты через бота. Нужен токен в `template/user/.pi/agent/telegram.json`. Сеть режет провайдер — `PIBOX_TELEGRAM_PROXY='socks5h://user:pass@host:port' pibox tg` (пробрасывается автоматически). Опции как у run, кроме аргументов pi; Ctrl+C — остановка |
| `pibox build [--no-cache]` | Сборка Docker-образа |
| `pibox shell [-e ИМЯ]` | Отладочная bash-оболочка в контейнере |

### Окружения и шаблоны

| Команда | Описание |
| --- | --- |
| `pibox env list` | Список окружений |
| `pibox env create ИМЯ` | Создать окружение из шаблона |
| `pibox env remove ИМЯ` | Удалить окружение (**без подтверждения**; `default` защищён) |
| `pibox extensions install [-e ИМЯ]` | Установить расширения из манифеста `template/extensions.txt`; окружение должно существовать. Уже установленное совпадающей версии пропускается |
| `pibox user push \| pull [-e ИМЯ]` | Слой `template/user`: `push` — применить к окружению (как при старте); `pull [-n]` — сохранить правки агента из окружения в `template/user` |
| `pibox doctor [-e ИМЯ] [--fix]` | Диагностика: docker, образ, каркас env, платформенные дубли расширений, npm-кэш, сверка расширений с манифестом; `--fix` удаляет дубли (только при живом gnu-твине) и восстанавливает каркас |

`pibox update` — заглушка. Обновление: `cd pibox && git pull && ./install.sh`.

### Опции запуска

| Опция | По умолчанию | Описание |
| --- | --- | --- |
| `-e, --env ИМЯ` | `default` | Окружение; создаётся автоматически при отсутствии |
| `-p, --publish SPEC` | — | Проброс порта, повторяемая (`-p 3000:3000`) |
| `-E, --pass-env VAR` | — | Проброс переменной окружения, повторяемая |
| `--env-file FILE` | — | Файл переменных окружения |
| `--memory LIMIT` | `4g` | Лимит памяти контейнера |
| `--cpus N` | `2` | Лимит CPU |
| `--pids-limit N` | `512` | Лимит процессов |
| `--git-safe` | выкл | `git safe.directory` для workspace |
| `--keep` | выкл | Оставить контейнер после выхода (для отладки) |
| `--dry-run` | — | Напечатать `docker run` без запуска |
| `--name ИМЯ` | auto | Имя контейнера |

Всё после `--` передаётся Pi: `pibox -- pi -p "объясни этот код"`.

### Примеры

```bash
pibox                          # default-окружение в текущем проекте
pibox webui                    # браузерный UI агента: http://localhost:8787
                               # (те же сессии/модели, что у TUI; Ctrl+C — стоп)
pibox webui --port 9000        # то же, но порт 9000 (занят 8787 и т.п.)
pibox tg                       # Telegram-мост: задания/отчёты через бота
PIBOX_TELEGRAM_PROXY='socks5h://u:p@1.2.3.4:1080' pibox tg
                               # то же через SOCKS5-прокси
pibox -e php8                  # отдельное окружение (создаётся пустым из шаблона —
                               # PHP появится, когда попросите агента поставить)
pibox -p 3000:3000             # dev-сервер в контейнере → localhost:3000
pibox -E ANTHROPIC_API_KEY     # ключ из окружения хоста
pibox --git-safe               # включить safe.directory для workspace
pibox shell -e php8            # оболочка для отладки окружения
pibox --dry-run -p 8080:8080   # посмотреть итоговую docker-команду
```

---

## Как это устроено

### Окружения и двухслойный шаблон

Окружение = каталог `~/pibox/env/ИМЯ`, монтируемый как `/home/pi`. Собирается
из двух слоёв (подробно — `template/README.md` и `docs/LAYERS.md`):

| | `template/common` | `template/user` |
| --- | --- | --- |
| Смысл | продукт: начальное состояние | личные инварианты (ключи, `USER.md`, личные расширения/конфиги, `telegram.json`) |
| Применяется | один раз, при создании окружения | при каждом запуске |
| `install.sh` | перезаписывает всегда | аддитивно, правки не трогает |

Файл из `user` с тем же путём перекрывает `common`. Окружение — не
производная: сессии, память, доустановленные расширения живут в нём и
слоями не удаляются. Правки агента, которые хотите сохранить себе:
`pibox user pull` (обратная синхронизация env → template/user).

Жизненный цикл:

- Запуск с несуществующим `-e ИМЯ` → окружение **создаётся автоматически**.
- Новое окружение — **пустой home из шаблона**: без предустановленных языков
  и фреймворков. Нужный инструментарий агент ставит по просьбе — и он остаётся.
- `env remove` удаляет окружение целиком.
- Расширения — по манифесту `~/pibox/template/extensions.txt`: `pibox extensions
  install` ставит/обновляет пакеты в конкретное окружение (сам его не создаёт);
  новые окружения стартуют без расширений. `doctor` сверяет и подсказывает.
- `install.sh` (без `--force`) **не трогает** существующие окружения.

### Что хранится в окружении

| Путь | Содержимое |
| --- | --- |
| `.pi/agent/sessions/` | Древовидные сессии `.jsonl` |
| `.pi/agent/models.json` | Конфиг моделей (из слоя `template/user`, при каждом запуске) |
| `.pi/agent/telegram.json` | Токен Telegram-моста (из слоя `template/user`) |
| `.pi/agent/{extensions,skills,prompts,themes}/` | Кастомизации Pi |
| `.pi/agent/AGENTS.md` | Инструкции агенту для этого окружения |
| `.local/share/mise/` | **Тулчейны mise — персистентны** |
| `.local/lib/node_modules/` | Глобальные npm-пакеты (prefix `~/.local`) |
| `.bashrc` | Заглушка pibox — sources `.bashrc.pibox` (сток, обновляется) + `.bashrc.user` (правки пользователя) |
| `.profile` | Аналогично: `.profile.pibox` + `.profile.user` |
| `.gitconfig`, `.tmux.conf` | Dot-файлы (из шаблона/скелета, одноразовый merge) |

### Тулчейны через mise

Тяжёлых тулчейнов (gcc, rust, go, gdb, cmake…) **нет в образе**. Агент ставит
их сам — в своё окружение, где они переживают перезапуск:

```bash
# внутри pibox shell — или просто попросите агента:
mise use -g php@8.3          # так в окружении появляется PHP
mise use -g golang@latest    # → ~/.local/share/mise
php -v; go version           # переживают перезапуск контейнера
```

### Обновление и удаление

- **Обновление:** `git pull && ./install.sh` — CLI, build-контекст (`docker/`)
  и `template/common/` перезаписываются **всегда**; `template/user/`
  копируется аддитивно (правки и ключи не трогаются); окружения (`env/*`)
  не трогаются.
- **Полный сброс окружений:** `./install.sh --force` — удаляет **ВСЕ** окружения
  в `~/pibox/env/` (default пересоздаётся из свежего шаблона). Данные окружений
  будут потеряны.
- **Удаление:** `rm -rf ~/pibox` и удалить блок `>>> pibox installer >>>` из
  `~/.bashrc` / `~/.zshrc`.

---

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

---

## Решение проблем

| Симптом | Решение |
| --- | --- |
| git: `detected dubious ownership` | Владелец workspace ≠ UID контейнера. Запускайте `pibox --git-safe` — включает `safe.directory`, не трогая ваши файлы |
| `bind: permission denied` на порту <1024 | У агента нет `CAP_NET_BIND_SERVICE`. Сервер внутри — на порт >1024, наружу любой: `-p 80:8080` |
| `host.docker.internal` не резолвится | Docker < 20.10 — обновите Docker |
| `pibox webui`: порт 8787 занят на хосте | `pibox webui --port 9000` или свой маппинг `pibox webui -p 19000:8787` |
| `pibox webui`: образ без pi-web-ui (собран до этой фичи) | Пересоберите: `pibox build` (версии пинуются в Dockerfile) |
| web-ui нужен из LAN | `pibox webui -p 0.0.0.0:8787:8787` + токен: `PI_WEB_TOKEN=секрет pibox webui -E PI_WEB_TOKEN`, вход `http://host:8787/?token=секрет`. **Без токена в LAN не пускать**; при `-E PI_WEB_TOKEN` автооткрытие подставит токен в ссылку само |
| `pibox tg`: бот не отвечает | Проверьте токен в `template/user/.pi/agent/telegram.json` (заглушка `REPLACE_ME` не даст стартовать); нет сети до `api.telegram.org` — добавьте `PIBOX_TELEGRAM_PROXY`. Логи моста: `docker logs <контейнер>` и `~/.local/state/pi-bridge/` внутри окружения |
| `strace -p PID` / `tcpdump` от pi падают | Известное ограничение: gosu сбрасывает capabilities при смене UID. `ping` и трассировка собственных потомков работают |
| `pibox: command not found` после install | PATH обновился — `exec $SHELL -l` или новый терминал |
| `bad interpreter: /usr/bin/env^M` | CRLF в скриптах: `git add --renormalize .` (`.gitattributes` настроен) |
| Файлы в workspace принадлежат root | Запускали `docker run` вручную без `-e HOST_UID`? Всегда через `pibox` |
| `pip install` падает (`externally-managed`) | PEP 668 в Ubuntu 24.04 — используйте venv: `python3 -m venv .venv && . .venv/bin/activate` |
| `npm install -g` и root? | Не нужен: `~/.npmrc` задаёт prefix `~/.local`. Без sudo |
| Первый запуск долгий | Норма: сборка образа + mise качает тулчейны. Дальше — из окружения |
| Медленный старт после смены юзера хоста | `find` по env чинит ownership при смене UID; на стабильном хосте не выполняется |

---

## Разработка

### Структура репозитория

```text
pibox/
├── docker/             # build-контекст (копируется install.sh в $PIBOX_DIR/docker)
│   ├── Dockerfile      # multi-stage: ubuntu 24.04 + node 24 + pi + pi-web-ui + mise
│   ├── entrypoint.sh   # UID/GID, dotfiles-слои, gosu→tini→CMD (pi | webui | pi-telegram-bridge run)
│   ├── webui.sh        # лаунчер web-ui в контейнере (→ /usr/local/bin/webui)
│   ├── pi-telegram-bridge.sh  # RPC-демон pi + Telegram-мост (→ /usr/local/bin/pi-telegram-bridge)
│   ├── telegram-socks-preload.cjs  # SOCKS5-прокси для Telegram (PIBOX_TELEGRAM_PROXY)
│   └── .dockerignore   # контекст = только файлы сборки
├── bin/
│   └── pibox           # точка входа CLI: source lib/* → main
├── lib/                # модули CLI (source'ятся в фиксированном порядке)
│   ├── common.sh       # константы, хелперы вывода, usage, проверки
│   ├── env.sh          # окружения: create (слой 1+2)/list
│   ├── layers.sh       # слои шаблона: apply_user_layer/push/pull
│   ├── docker-cmd.sh   # сборка docker run команды (+webui/tg-режимы)
│   ├── cmd-run.sh      # pibox run + общее ядро launch_container
│   ├── cmd-webui.sh    # pibox webui
│   ├── cmd-tg.sh       # pibox tg (переиспользует launch_container)
│   ├── cmd-build.sh    # pibox build
│   ├── cmd-env.sh      # pibox env / pibox shell
│   ├── cmd-user.sh     # pibox user push/pull
│   ├── ext-manifest.sh # чтение манифеста расширений
│   ├── ext-progress.sh # TTY-визуализация установки расширений
│   ├── cmd-extensions.sh # pibox extensions install
│   ├── cmd-update.sh   # pibox update (заглушка)
│   ├── cmd-doctor.sh   # pibox doctor (D1–D9)
│   └── main.sh         # диспетчер подкоманд
├── install.sh          # установщик
├── template/
│   ├── common/         # СЛОЙ 1: начальное состояние окружений (продукт)
│   ├── user/           # СЛОЙ 2: личные инварианты (models.json, USER.md, telegram.json, …)
│   ├── extensions.txt  # манифест расширений
│   └── README.md       # описание двухслойной схемы
├── env/                # живые окружения (не коммитятся)
├── tests/
│   ├── smoke.sh        # >100 автопроверок: install→build→CLI→runtime
│   └── helpers.sh      # счётчики, expect_*, docker_pibox, очистка
├── docs/
│   ├── PROJECT.md      # описание проекта, контракты, подводные камни
│   ├── TESTS.md        # как тестировать pibox
│   └── LAYERS.md       # дизайн двухслойного шаблона
└── .github/workflows/ci.yml  # shellcheck + exec-биты + docker build
```

### Тесты

```bash
./tests/smoke.sh              # полный прогон (~2 мин при готовом образе)
./tests/smoke.sh --offline    # без интернет-проверок
./tests/smoke.sh --keep       # сохранить артефакты при FAIL
./tests/smoke.sh --rebuild    # пересобрать образ
PIBOX_IMAGE=pibox:test ./tests/smoke.sh

shellcheck install.sh docker/entrypoint.sh docker/webui.sh docker/pi-telegram-bridge.sh bin/pibox lib/*.sh tests/smoke.sh tests/helpers.sh   # как в CI
shfmt -d -i 4 install.sh docker/entrypoint.sh docker/webui.sh docker/pi-telegram-bridge.sh bin/pibox lib/*.sh tests/smoke.sh tests/helpers.sh  # стиль: 4 пробела, не табы
```

### Обновление версий

В `Dockerfile` (ARG-параметры):

| ARG | Что | Правило |
| --- | --- | --- |
| `UBUNTU_VERSION` | базовый образ | пиновать LTS (`24.04`) |
| `NODE_IMAGE` | источник Node | мажор + distro; **glibc builder ≤ runtime** (bookworm ≤ noble — не trixie!) |
| `PI_VERSION` | `@earendil-works/pi-coding-agent` | точная версия |
| `MISE_VERSION` | mise | пиновать не требуется (ставится официальным инсталлером) |

После смены: `pibox build --no-cache` + прогон smoke-тестов.
