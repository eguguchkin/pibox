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
  Окружений может быть несколько под разные проекты и стеки — имена произвольные
  (`default`, `php8`, `rust`…), переключение — одной опцией `-e ИМЯ`.
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
│  └ ...                    │              │  2. dotfiles-слои (всегда)    │
│                           │              │  3. gosu → tini → pi          │
│ Model API :8080           │◄─────────────│ host.docker.internal:8080     │
└───────────────────────────┘              └───────────────────────────────┘
```

## Требования

| Требование | Проверка |
| --- | --- |
| Linux + Docker Engine **≥ 20.10** | `docker --version` |
| Bash **≥ 3.2** | `bash --version` (дефолтный macOS bash подходит) |
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
${EDITOR:-vi} ~/pibox/models.json

# 3. Соберите образ
exec $SHELL -l                # перезагрузить PATH (или новый терминал)
pibox build                   # первый раз — несколько минут

# 4. Установите набор расширений (опционально; несколько минут)
pibox extensions install      # список — в ~/pibox/env/extensions.txt

# 5. Запустите агента в любом проекте
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
| --- | --- |
| `pibox [run] [ОПЦИИ] [--] [PI_ARGS…]` | Запуск агента (run — по умолчанию) |
| `pibox build [--no-cache]` | Сборка Docker-образа |
| `pibox env list` | Список окружений |
| `pibox env create ИМЯ` | Создать окружение из шаблона |
| `pibox env remove ИМЯ` | Удалить окружение (**без подтверждения**; `default` защищён) |
| `pibox extensions install [-e ИМЯ]` | Установить расширения из манифеста `env/extensions.txt`; окружение должно существовать (`env create`). Уже установленное совпадающей версии пропускается |
| `pibox shell [-e ИМЯ]` | Отладочная bash-оболочка в контейнере |
| `pibox doctor [-e ИМЯ] [--fix]` | Диагностика: docker, образ, каркас env, платформенные дубли расширений, npm-кэш, сверка расширений с манифестом; `--fix` удаляет дубли (только при живом gnu-твине) и восстанавливает каркас |
| `pibox --help` / `--version` | Справка / версия |

`pibox update` — заглушка. Обновление:

```bash
cd pibox && git pull && ./install.sh
```

`install.sh` перезаписывает CLI, `docker/` и `env/.template/` при каждом запуске;
`models.json`, `env/extensions.txt` и окружения (`env/*`) не трогаются.

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
pibox -e php8                  # отдельное окружение (создаётся пустым из шаблона —
                               # PHP появится, когда попросите агента поставить)
pibox -p 3000:3000             # dev-сервер в контейнере → localhost:3000
pibox -E ANTHROPIC_API_KEY     # ключ из окружения хоста
pibox --git-safe               # включить safe.directory для workspace
pibox shell -e php8            # оболочка для отладки окружения
pibox --dry-run -p 8080:8080   # посмотреть итоговую docker-команду
```

### Обновление и удаление

- **Обновление:** `git pull && ./install.sh` — CLI, build-контекст (`docker/`)
  и `env/.template/` перезаписываются **всегда**; `models.json` и окружения
  (`env/*`) не трогаются.
- **Полный сброс окружений:** `./install.sh --force` — удаляет **ВСЕ** окружения
  в `~/pibox/env/` (default пересоздаётся из свежего шаблона). Данные окружений
  будут потеряны.
- **Удаление:** `rm -rf ~/pibox` и удалить блок `>>> pibox installer >>>` из
  `~/.bashrc` / `~/.zshrc`.

## Окружения

### Жизненный цикл

- Запуск с несуществующим `-e ИМЯ` → окружение **создаётся автоматически** из
  `~/pibox/env/.template/`, в него копируется `models.json`.
- Новое окружение — это **пустой home из шаблона**: без предустановленных языков
  и фреймворков. Имя (`php8`, `rust`) — произвольная метка, а не готовый стек:
  нужный инструментарий агент ставит по вашей просьбе (см. «Тулчейны через
  mise» ниже), и он остаётся в этом окружении.
- Окружение = каталог `~/pibox/env/ИМЯ`, монтируемый как `/home/pi`. Всё, что
  агент ставит или меняет в home, живёт там.
- `env remove` удаляет окружение целиком.
- Расширения — по манифесту `~/pibox/env/extensions.txt`: `pibox extensions
  install` ставит/обновляет пакеты в конкретном окружении (сам его не создаёт);
  новые окружения стартуют без расширений. `doctor` сверяет окружение с
  манифестом и подсказывает команду.
- `install.sh` (без `--force`) **не трогает** существующие окружения;
  `--force` удаляет их все.

### Что хранится в окружении

| Путь | Содержимое |
| --- | --- |
| `.pi/agent/sessions/` | Древовидные сессии `.jsonl` |
| `.pi/agent/models.json` | Конфиг моделей (копия при первом запуске) |
| `.pi/agent/{extensions,skills,prompts,themes}/` | Кастомизации Pi |
| `.pi/agent/AGENTS.md` | Инструкции агенту для этого окружения |
| `.local/share/mise/` | **Тулчейны mise — персистентны** |
| `.local/lib/node_modules/` | Глобальные npm-пакеты (prefix `~/.local`) |
| `.bashrc` | Заглушка pibox — sources `.bashrc.pibox` (сток, обновляется) + `.bashrc.user` (правки пользователя) |
| `.profile` | Аналогично: `.profile.pibox` + `.profile.user` |
| `.gitconfig`, `.tmux.conf` | Dot-файлы (из шаблона/скелета, одноразовый merge) |

### Тулчейны через mise

Тяжёлых тулчейнов (gcc, rust, go, gdb, cmake…) **нет в образе**. Агент ставит их сам:

```bash
# внутри pibox shell — или просто попросите агента:
mise use -g php@8.3          # так в окружении появляется PHP
mise use -g golang@latest    # → ~/.local/share/mise
php -v; go version           # переживают перезапуск контейнера
```

## Модели и API-ключи

### models.json

Шаблон — `~/pibox/models.json`; при первом запуске окружения копируется в
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
| --- | --- |
| git: `detected dubious ownership` | Владелец workspace ≠ UID контейнера. Запускайте `pibox --git-safe` — включает `safe.directory`, не трогая ваши файлы |
| `bind: permission denied` на порту <1024 | У агента нет `CAP_NET_BIND_SERVICE`. Сервер внутри — на порт >1024, наружу любой: `-p 80:8080` |
| `host.docker.internal` не резолвится | Docker < 20.10 — обновите Docker |
| `strace -p PID` / `tcpdump` от pi падают | Известное ограничение: gosu сбрасывает capabilities при смене UID. `ping` и трассировка собственных потомков работают |
| `pibox: command not found` после install | PATH обновился — `exec $SHELL -l` или новый терминал |
| `bad interpreter: /usr/bin/env^M` | CRLF в скриптах: `git add --renormalize .` (`.gitattributes` настроен) |
| Файлы в workspace принадлежат root | Запускали `docker run` вручную без `-e HOST_UID`? Всегда через `pibox` |
| `pip install` падает (`externally-managed`) | PEP 668 в Ubuntu 24.04 — используйте venv: `python3 -m venv .venv && . .venv/bin/activate` |
| `npm install -g` и root? | Не нужен: `~/.npmrc` задаёт prefix `~/.local`. Без sudo |
| Первый запуск долгий | Норма: сборка образа + mise качает тулчейны. Дальше — из окружения |
| Медленный старт после смены юзера хоста | `find` по env чинит ownership при смене UID; на стабильном хосте не выполняется |

## Разработка

### Структура репозитория

```
pibox/
├── Dockerfile          # multi-stage: ubuntu 24.04 + node 24 + pi + mise
├── entrypoint.sh       # UID/GID, dotfiles-слои, gosu→tini→pi
├── bin/
│   └── pibox           # точка входа CLI: source lib/* → main
├── lib/                # модули CLI (source'ятся в фиксированном порядке)
│   ├── common.sh       # константы, хелперы вывода, usage, проверки
│   ├── env.sh          # окружения: create/copy_models_json/list
│   ├── docker-cmd.sh   # сборка docker run команды
│   ├── cmd-run.sh      # pibox run
│   ├── cmd-build.sh    # pibox build
│   ├── cmd-env.sh      # pibox env / pibox shell
│   ├── ext-manifest.sh # чтение манифеста расширений
│   ├── ext-progress.sh # TTY-визуализация установки расширений
│   ├── cmd-extensions.sh # pibox extensions install
│   ├── cmd-update.sh   # pibox update (заглушка)
│   ├── cmd-doctor.sh   # pibox doctor (D1–D9)
│   └── main.sh         # диспетчер подкоманд
├── install.sh          # установщик
├── models.json         # шаблон конфига моделей
├── env/
│   ├── .template/      # шаблон /home/pi для новых окружений (точка — glob '*' его не матчит)
│   └── <имя>/          # живые окружения (не коммитятся)
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

shellcheck install.sh entrypoint.sh bin/pibox lib/*.sh tests/smoke.sh tests/helpers.sh   # как в CI
shfmt -d -i 4 install.sh entrypoint.sh bin/pibox lib/*.sh tests/smoke.sh tests/helpers.sh  # стиль: 4 пробела, не табы
```

Ручная приёмка: `tests/ACCEPTANCE.md` — 7 сценариев (~30 мин).

### Обновление версий

В `Dockerfile` (ARG-параметры):

| ARG | Что | Правило |
| --- | --- | --- |
| `UBUNTU_VERSION` | базовый образ | пиновать LTS (`24.04`) |
| `NODE_IMAGE` | источник Node | мажор + distro; **glibc builder ≤ runtime** (bookworm ≤ noble — не trixie!) |
| `PI_VERSION` | `@earendil-works/pi-coding-agent` | точная версия |
| `MISE_VERSION` | mise | пиновать не требуется (ставится официальным инсталлером) |

После смены: `pibox build --no-cache` + прогон smoke-тестов.
