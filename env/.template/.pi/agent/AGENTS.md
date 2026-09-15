# AGENTS.md — глобальные инструкции для агента в pibox

Ты запущен внутри Docker-контейнера pibox: Ubuntu 24.04, архитектура как у хоста
(arm64/amd64); ресурсы лимитируются pibox (по умолчанию 4 ГБ RAM, 2 CPU, 512 pids).

## Критические ограничения

- **Нет root и sudo** — ты работаешь от `pi` (UID/GID = хост-юзеру). `apt install` недоступен.
- **Персистентны только `$HOME` (/home/pi) и /home/pi/workspace** — bind-mounts с хоста.
  Всё остальное (включая /usr, /etc и установленные apt-пакеты) сбрасывается при перезапуске.
- `/home/pi/workspace` — каталог пользователя на хосте, ЕДИНСТВЕННОЕ место с его данными.
  Не удалять без явной просьбы. Подробности — скилл workspace-hygiene.
- Файлы, которые ты создаёшь, принадлежат пользователю хоста — chown не нужен.

## Установка языков и тулчейнов

Только в $HOME (персистентно): mise (языки/версии), npm -g (prefix ~/.local),
python venv (PEP 668). Детали — скилл install-languages (загрузи при первой установке).

## Git

- git есть, но `~/.gitconfig` НЕТ → первый коммит упадёт («Please tell me who you are»).
  Фикс: спроси у пользователя имя/email → `git config --global user.name/user.email`
  (персистентно в окружении) или `--local` в проекте.
- «detected dubious ownership» — не чинить chown'ом; пользователю — флаг запуска
  `pibox --git-safe`.
- Секреты (API-ключи, `.env`, `models.json` с ключами) не коммитить и не выводить в логи.

## Сеть

Скилл networking (dev-серверы, порты, host.docker.internal, диагностика). Кратко:
- порт <1024 внутри не открыть; серверы слушать на 0.0.0.0;
- хост-сервисы — `host.docker.internal` (локальная модель API на хосте —
  `http://host.docker.internal:PORT/v1`).

## Известные особенности

- Системный pip заблокирован (PEP 668, `externally-managed-environment`) — только venv.
- `~/.npmrc` нет по умолчанию → первый `npm install -g` может упасть с EACCES —
  `npm config set prefix ~/.local` (см. скилл install-languages).
- Сеть открыта (если хост не ограничил): curl/wget/git работают.
- Инструменты: есть curl, dig, nslookup, ss; нет nc, telnet, traceroute, sudo.
- Capabilities сбрасываются: strace чужих процессов и tcpdump не работают.
- Долгие команды (сборки, загрузки mise ~100–200 МБ) — норма, не обрывай раньше времени.
- Неинтерактивные флаги (-y, CI=1) — TTY может отсутствовать.
- `/tmp` не персистентен — годится для scratch в рамках сессии, не для важного.

## Конфигурация агента

- Сессии: `~/.pi/agent/sessions/` (персистентны).
- Модели: `~/.pi/agent/models.json` (копия `PIBOX_DIR/models.json` при первом запуске).
- Скиллы: `~/.pi/agent/skills/` (персистентны).
- Этот файл — глобальный AGENTS.md окружения; правки переживут перезапуск.
