# PIBOX — описание проекта (для агента)

## Суть

PIBOX — обвязка вокруг [Pi Coding Agent](https://pi.dev/) (npm: `@earendil-works/pi-coding-agent`),
запускающая его в изолированном Docker-контейнере с сохранением состояния между запусками.
Три ключевые задачи:

1. **Изоляция** — агент видит только два bind-mount: рабочий проект
   (`/home/pi/workspace/<имя проекта>` — подкаталог по basename каталога запуска,
   агент стартует в нём) и своё окружение (`/home/pi` ← `~/pibox/env/<имя>` на хосте).
   UID/GID агента динамически подстраивается под пользователя хоста (файлы создаются
   не от root).
2. **Персистентность** — сессии, конфиги, расширения и тулчейны (mise) живут в каталоге
   окружения на хосте и переживают перезапуск. Несколько изолированных окружений
   (`default`, `php8`, `rust`…) через `pibox -e ИМЯ`.
3. **Компактный образ** — multi-stage сборка: Ubuntu 24.04 + Node 24 + Pi +
   pi-web-ui (браузерный UI, `pibox webui`) + mise + рантайм-зависимости
   pi-расширений (JRE, tesseract) + `make`/`g++`/`python3` для node-gyp +
   shellcheck/shfmt для самопроверки скриптов репо. Компилятор в runtime —
   осознанное исключение из инварианта №4: нативные зависимости расширений
   без prebuilds (tree-sitter у pi-codegraph и т.п.) иначе требуют
   mise-тулчейна (~70с скачивания) на каждую установку в новое окружение.
   Остальные тяжёлые тулчейны (rust, go, cmake) агент ставит сам через mise
   в `~/.local` (персистентно).

## Ключевые компоненты репозитория

| Файл | Назначение |
| --- | --- |
| `docker/` | build-контекст: `Dockerfile` — multi-stage: ubuntu 24.04 + node 24 + pi + pi-web-ui + mise; ARG-версии пинуются; pi и pi-web-ui ставятся одной npm-командой (общий SDK дедупится в один экземпляр), g++ для node-pty в builder и в runtime для нативных сборок расширений, стрипы платформенного жира; `entrypoint.sh` — от root: подстановка UID/GID хост-юзера → dotfiles-слои (заглушка + `.pibox`/`.user`) → gosu → tini → CMD (по умолчанию `pi`; из `pibox webui` — лаунчер `webui`; из `pibox tg` — `pi-telegram-bridge run`); `webui.sh` — лаунчер web-ui в контейнере: чистка control-сокета, зелёная строка-ссылка `http://localhost:<hp>` (+ `?token=` из URL-safe `PI_WEB_TOKEN`), `exec pi-web-ui --no-browser --host 0.0.0.0` — дальше штатные логи сервера/агента в консоль; ставится в `/usr/local/bin/webui`; `pi-telegram-bridge.sh` — RPC-демон pi с автоподключением Telegram-моста (`@llblab/pi-telegram`): run (foreground, команда контейнера `pibox tg`), start/stop/status/connect (фоновый демон; автостарт из entrypoint при настроенном `~/.pi/agent/telegram.json`, выключается `PIBOX_NO_TELEGRAM_BRIDGE=1`), логи в `.local/state/pi-bridge/`; ставится в `/usr/local/bin/pi-telegram-bridge`; `telegram-socks-preload.cjs` — preload-хук SOCKS5-прокси для Telegram (см. контракт cmd-tg ниже); ставится в `/usr/local/lib/pi-telegram/`; `.dockerignore` — контекст = только файлы сборки |
| `bin/pibox` + `lib/` | исходник CLI `pibox` (после install — `~/pibox/bin/pibox` + `~/pibox/lib/`); точка входа подгружает модули в фиксированном порядке: `common.sh` (константы, хелперы, usage, проверки) → `env.sh` (окружения) → `docker-cmd.sh` (сборка docker run + webui/tg-режимы) → `ext-manifest.sh` (манифест расширений) → `cmd-*.sh` (подкоманды; `cmd-run.sh` содержит общее ядро `launch_container`, его переиспользуют `cmd-webui.sh` и `cmd-tg.sh`) → `main.sh` (диспетчер). Зависимости только «вниз», циклов нет |
| `install.sh` | установщик: создаёт `~/pibox`, bin в PATH, блок `>>> pibox installer >>>` в rc-файле |
| `template/common/` | СЛОЙ 1: начальное состояние окружений — стартовые знания агента (`.pi/agent/AGENTS.md`, скиллы `install-languages`, `workspace-hygiene`, `networking`, `extension-hygiene`, `show-image`, расширения `terminal-probe`, `auto-commit` — авто-коммит после итерации агента, выключен по умолчанию) |
| `template/user/` | СЛОЙ 2: личные инварианты — `models.json`, `USER.md`, `telegram.json` (токен Telegram-моста; заглушка REPLACE_ME — мост отказывается стартовать с ней; шаблон-инструкция с allowedUserId — `telegram.json.example`), личные расширения (`selectel-thinking-off.ts`), конфиги (`pi-image-gen/`, `auto-commit.json` — конфиг авто-коммита); в репо — заглушки, реальные значения — в установке |
| `template/extensions.txt` | манифест расширений pi (`npm:имя@версия`); ставятся `pibox extensions install`, аудит — `doctor` (D9) |
| `tests/smoke.sh` + `tests/helpers.sh` | >100 автопроверок: install → build → CLI → runtime; флаги `--offline/--keep/--rebuild/--no-docker`; хелперы (счётчики, `expect_*`, `docker_pibox`, очистка) — в `helpers.sh`; docker-заглушка для прогонов в контейнере — `tests/docker-stub/`, см. `docs/TESTS.md` |

`docs/` содержит: `PROJECT.md` (этот файл), `TESTS.md` (как тестировать) и
`LAYERS.md` (дизайн двухслойного шаблона).

## Контракты между компонентами (важно при правках)

Контракт — негласная связь между файлами/компонентами: переданные глобальные
переменные, `-e`-переменные окружения контейнера, имена файлов или
поведенческие договорённости. Ничто не проверяет их автоматически: при
рассогласовании ошибок не будет — только молча сломанное поведение.
Правило: меняешь одну сторону контракта — синхронизируй вторую (или больше,
если сторон три). Те же списки продублированы комментариями «Контракт»
в шапках затронутых файлов.

+ entrypoint ↔ Dockerfile: `/opt/skel` (заглушки + `.pibox`-слои + прочие dot-файлы), маркер `PIBOX_SKELETON_V1` в заглушках, переменные `HOST_UID`/`HOST_GID`, юзер `pi`.
+ bin/pibox+lib/cmd-webui.sh ↔ webui.sh (в образе): CLI пробрасывает `-p hp:8787` + `-e PI_WEB_PORT/WEBUI_HOST_PORT`, командой контейнера задаёт `webui`; лаунчер печатает зелёную ссылку `http://localhost:<hp>` и exec'ит pi-web-ui в foreground. Ctrl+C (rc 130/143) — штатная остановка: контейнер тихо удаляется.
+ bin/pibox+lib/cmd-tg.sh ↔ pi-telegram-bridge.sh (в образе): CLI задаёт командой контейнера `pi-telegram-bridge run` (RPC-демон + /telegram-connect, foreground), имя контейнера `pibox-<env>-tg`, порты не публикует (мост ходит наружу к api.telegram.org). Ctrl+C (rc 130/143) — штатная остановка. docker/entrypoint.sh пропускает фоновый автостарт моста, когда команда контейнера — «pi-telegram-bridge» (иначе два демона дерутся за singleton-lock). Переменная хоста PIBOX_TELEGRAM_PROXY (socks5h://user:pass@host:port) автоматически пробрасывается `-e` — llblab ходит в Telegram мимо HTTP(S)_PROXY (сырой https.request), поэтому прокси подключает preload docker/telegram-socks-preload.cjs (перехват https к *.telegram.org в процессе pi; модуль socks-proxy-agent запечён в /usr/local/lib/pi-socks).
+ webui без рендера и прогрева: лаунчер печатает зелёную ссылку (хост-порт из `-e WEBUI_HOST_PORT`, токен из `-E PI_WEB_TOKEN[=v]` — только URL-safe — в `?token=`) и exec'ит pi-web-ui; логи сервера/агента идут в консоль напрямую. Ctrl+C (rc 130/143) — штатная остановка, контейнер тихо удаляется.
+ Dockerfile ↔ pi-web-ui: `ARG PI_WEB_UI_VERSION` пинует версию; pi и pi-web-ui ставятся ОДНОЙ npm-командой — общий `@earendil-works/pi-coding-agent` дедупится в единственный экземпляр (один и тот же SDK у TUI `pi` и webui; последовательные установки не дедупятся — не разносить на два RUN). При несовместимости пинов npm молча ставит вложенную копию — guard («вложенной копии быть не должно») роняет сборку. node-pty собирается в builder (g++/make/python3 apt-стадией) — в runtime только `build/Release/pty.node` + системные `libstdc++6`/`libgcc-s1`. Стрипы: `@esbuild` → одна нативная платформа, `node-pty/prebuilds` (win32) — прочь.
+ entrypoint ↔ файлы home (договор о владельце): весь `/home/pi` — bind-mount хоста, все файлы в нём считаются принадлежащими хост-юзеру (`HOST_UID:HOST_GID`); рекурсивный chown при старте НЕ делается. Владелец чинится только у файлов, копируемых из skel (точечные chown + одноразовый `find -user 0` с `-xdev` внутри первого merge под маркером `.pibox_other_skel_done`). Перенос env между машинами с разным UID — разовый `chown -R` на хосте.
+ bin/pibox+lib/install.sh → шаблон: `PIBOX_DIR/env/<name>`, `PIBOX_DIR/template/{common,user}`.
+ install.sh: копирует `bin/pibox` + `lib/` (каталог целиком, mirror-механизм как у `docker/`) → `~/pibox/`, build-контекст → `~/pibox/docker/`. Перезапись CLI+lib/docker/`template/common` — при каждом запуске; `template/user` — аддитивно (`additive_copy`: без перезаписи существующего; не через `cp -n` — BSD cp на macOS 15+ возвращает 1 при пропуске файла, под set -e это валило повторную установку), правки и ключи не трогаются; `--force` дополнительно удаляет ВСЕ окружения (`env/*`).
+ Модель API с хоста доступна из контейнера как `http://host.docker.internal:8080`.

## Как проверять изменения

```bash
pibox build                    # или docker build
./tests/smoke.sh               # полный прогон ~2 мин; --offline / --keep / --rebuild
./tests/smoke.sh --no-docker   # внутри контейнера pibox: CLI-фазы через tests/docker-stub, docker-фазы SKIP
shellcheck install.sh docker/entrypoint.sh docker/webui.sh docker/pi-telegram-bridge.sh bin/pibox lib/*.sh tests/*.sh tests/docker-stub/docker   # так же в CI
shfmt -d -i 4 install.sh docker/entrypoint.sh docker/webui.sh docker/pi-telegram-bridge.sh bin/pibox lib/*.sh tests/*.sh tests/docker-stub/docker  # стиль: 4 пробела, не табы
```

CI (`.github/workflows/ci.yml`): shellcheck + проверка exec-битов + docker build.

Подробно о режимах прогона и docker-заглушке — [docs/TESTS.md](TESTS.md).

## Правила и подводные камни

+ **Прямой запуск `bin/pibox` из чекаута создаёт окружения прямо в репо**
  (`env/<имя>`, дефолт PIBOX_DIR = каталог репо). Для экспериментов — либо
  `PIBOX_DIR=/tmp/pibox-test ./bin/pibox ...`, либо чистить env/ перед коммитом
  (git игнорирует env/*, мусор легко не заметить).

+ Версии в Dockerfile: пиновать точные (кроме mise — ставится официальным инсталлером,
  пиновка не требуется); Node builder (glibc) ≤ runtime (bookworm ≤ noble, не trixie).
  Исключений нет: npm-кэш живёт в `~/.npm` (персистентен в env).
+ **Рантайм-зависимости pi-расширений в образе** (не тулчейны для агента — инвариант №4
  не задет, через mise их не поставить): `default-jre-headless` — рантайм для
  `recheck.jar` из pi-mcp-adapter (быстрый аудит RegEx; без java — медленный JS-фолбэк);
  `tesseract-ocr` + eng/rus traineddata — встроенный OCR для pi-docparser;
  `make` + `g++` — тулчейн node-gyp для нативных зависимостей расширений без
  prebuilds (tree-sitter у pi-codegraph и т.п.); тяжёлые тулчейны (rust, go, cmake)
  остаются через mise. g++ в builder — для node-pty (терминал webui).
+ **npm-кэш — `~/.npm`, персистентен в env**: скачанное однажды не перекачивается,
  но кэш раздувается (~400 МБ при активных установках) — чистка `npm cache clean --force`.
  (Кэш в `/opt/npm-cache` пробовали — откатили: контейнерный слой эфемерен, записи
  о новых расширениях умирали с каждым перезапуском.)
+ **Мусорные дубли платформенных бинарей в env** можно чистить после установки
  расширений (контейнер glibc, arch = arch хоста):
  `find ~/.pi/agent/npm/node_modules -maxdepth 2 -name '*-musl' -exec rm -rf {} +`
  (−130 МБ: @lancedb и keyring тянут оба варианта, gnu+musl) и
  `rm ~/.pi/agent/npm/node_modules/@llamaindex/liteparse/liteparse.linux-x64-gnu.node`
  (на arm64-хосте; на amd64 он наоборот рабочий — сверяться с `uname -m`).
+ **Расширения pi дистрибутируются манифестом, не бинарниками**: в репо —
  только `template/extensions.txt` (список `npm:имя@точно-заплиненная-версия`;
  копируется инсталлером в `~/pibox/env/`, там пользователь может править
  свой набор). Установка — `pibox extensions install [-e ИМЯ]`: одноразовый
  контейнер с примонтированным env, по одному `pi install` на пакет;
  уже установленное совпадающей версии пропускается. Команда НЕ создаёт
  окружение (строгий контракт: сначала `pibox env create`). Установщики
  получают переменную `npm_config_dangerously_allow_all_scripts=true`:
  npm 11.19+ без одобрения молча пропускает install-скрипты — у нативных
  пакетов без пребилдов (better-sqlite3 для context-mode) тогда не
  появляется рабочий бинарь. Переменная действует ТОЛЬКО в установке
  из манифеста (кураторский набор); ручной `pi install` внутри окружения
  остаётся под гейтом npm (pending-варнинги, `npm install-scripts approve`).
  Настройка pi
  (settings.json "packages") дополняется записями "npm:имя" без версий;
  Прогресс установки: в TTY — постоянная область в стиле docker build (зелёная
  строка статуса с секундомером + серое скользящее окно последних N строк
  вывода; N настраивается `PIBOX_EXT_WINDOW` (по умолчанию 10), частота
  перерисовки — `PIBOX_EXT_TICK` в секундах (по умолчанию 0.5, т.е. 2 раза в
  секунду)). Итог каждого пакета («✓ …»/«✗ …») фиксируется навсегда в
  скроллбэке, следующий пункт добавляется ниже; курсор на время установки
  скрыт. План не печатается заранее — строки появляются по мере прохода
  (пропуски «уже установлен» — на месте, в порядке манифеста). Вне TTY —
  построчный вывод. Сломанные установки показывают ✗ и хвост журнала.
  `doctor` (D9) сверяет окружение с манифестом. Почему не вендорить
  node_modules в шаблон: ~500 МБ чужого кода в git + платформенные бинарники
  в коммите теряют портируемость репо.
+ Файлы окружения (`env/*`, кроме шаблонов) при переустановке не затрагивать.
+ **Расширение auto-commit** (`~/.pi/agent/extensions/`, слой `template/common`): после
  каждой завершённой итерации агента (`agent_settled`) делает git-коммит изменений
  рабочей папки: тема — текущая модель сессии (запрос + ответ + дифф на входе), тело —
  запрос пользователя, ответ агента и список файлов. Выключен по умолчанию; конфиг —
  `~/.pi/agent/auto-commit.json` (слой user) с пер-проектным override `<проект>/.pi/auto-commit.json`;
  переключение — `/autocommit [on|off|status]`. Детали —
  `template/common/.pi/agent/extensions/auto-commit.md`.

+ **Расширение terminal-probe** (в `.pi/extensions/` проекта, `~/.pi/agent/extensions/`
  и `template/common/.pi/agent/extensions/` шаблона): инструмент `terminal_probe` —
  запускает консольную команду под настоящим pty (через системный `script`, без
  нативных модулей), эмулирует терминал и пишет текстовые снимки экрана по кадрам
  (`frames/NNNN_<сек>s.txt`: сетка символов, ANSI-цвета, шапка с курсором/alt-screen;
  дубли кадров по sha256 — маркеры `SAME AS PREVIOUS`). Действия: `run` / `list` / `read`.
  Ассертов нет — оценку визуального вывода (перерисовки, цвета, «осталось ли мусор
  на экране») агент делает сам, читая снимки. См. `.pi/extensions/terminal-probe.md`.
+ Скрипты — LF-окончания (`.gitattributes` настроен, CRLF ломает `bad interpreter`).
+ Безопасность: контейнер — НЕ полная песочница (сеть открыта, добавлены SYS_PTRACE и NET_RAW,
  код расширений выполняется с правами агента). API-ключи — через `-E VAR`/`--env-file`.
+ Запуск pibox из самого `~/pibox` блокируется (защита от саморедактирования).
+ Порты <1024 внутри контейнера недоступны (нет CAP_NET_BIND_SERVICE) — маппить наружу.
+ Известные ограничения: capabilities сбрасываются после gosu (strace -p, tcpdump от pi).
+ **Шаблон двухслойный** (`template/`, см. LAYERS.md): слой 1 `common` — продукт
  (`.pi/agent/AGENTS.md`, скиллы), применяется при создании окружения;
  слой 2 `user` — личные инварианты (ключи, `USER.md`, личные расширения,
  токен Telegram-моста),
  применяется при каждом запуске (`apply_user_layer` в lib/layers.sh).
  Каждое новое окружение сразу «обучено»; правки из env забираются
  осознанно: `pibox user pull`.

## Принятые решения

+ **Знания агента живут в двух местах:** шаблон (`template/{common,user}/.pi/agent/`) — для новых
  окружений, home текущего окружения (`~/.pi/agent/`) — рабочие копии, которые агент
  редактирует по ходу жизни. Синхронизация обратной стороны (env → шаблон) — вручную,
  осознанно: рабочие окружения пользователей не должны молча переучиваться при
  обновлении pibox.

+ **Проект монтируется в подкаталог** `/home/pi/workspace/<basename каталога запуска>`,
  а не в корень `/home/pi/workspace` (docker run: `-v $(pwd):…` + `-w …`). Причина:
  расширения вроде pi-memory ключат хранилище по git-toplevel/cwd — при старом
  монтаже все проекты видели один и тот же путь `/home/pi/workspace` и их память
  перемешивалась. Теперь путь (а значит и память) уникален по имени каталога.
  Известное ограничение: два разных хост-проекта с одинаковым именем каталога
  получают один путь; точка монтирования (`env/<имя>/workspace/<проект>`) создаётся
  CLI от хост-юзера до `docker run`, чтобы docker не делал её от root. Пустые
  точки монтирования от завершённых запусков («фантомы» прошлых проектов)
  подчищаются `cleanup_workspace_mounts` (common.sh) до запуска и после штатного
  удаления контейнера; непустые каталоги не трогаются никогда.

+ **Слоёные dot-файлы вместо одноразового skel-merge**:
  `~/.bashrc`/`~/.profile` — заглушки с маркером `PIBOX_SKELETON_V1`, которые
  source-ят два слоя: `.<f>.pibox` (сток pibox, обновляется при каждом запуске контейнера)
  и `.<f>.user` (пользовательские правки; миграция из старого монолитного `.bashrc` —
  автоматически при первом запуске нового entrypoint, при коллизии — `.bak.TIMESTAMP`).
  Единственный источник правды — skel (собирается в Dockerfile): entrypoint только
  синхронизирует заглушку и сток в home (`cmp`-проверка — без перезаписи при совпадении)
  и мигрирует наследие. Вход в слоёную обработку — только если в skel-заглушке есть
  маркер (защита от миграции-зацикливания при ошибке в Dockerfile). Прочие skel-файлы —
  прежний одноразовый `cp -rn` (маркер `.pibox_other_skel_done`).

## Статус

MVP готов (git: mvp + fix test). Лицензия MIT. Целевая платформа — Linux + Docker ≥ 20.10;
macOS/Windows — экспериментально.
