# PIBOX — описание проекта (для агента)

## Суть

PIBOX — обвязка вокруг [Pi Coding Agent](https://pi.dev/) (npm: `@earendil-works/pi-coding-agent`),
запускающая его в изолированном Docker-контейнере с сохранением состояния между запусками.
Три ключевые задачи:

1. **Изоляция** — агент видит только два bind-mount: рабочий проект (`/home/pi/workspace`)
   и своё окружение (`/home/pi` ← `~/pibox/env/<имя>` на хосте). UID/GID агента динамически
   подстраивается под пользователя хоста (файлы создаются не от root).
2. **Персистентность** — сессии, конфиги, расширения и тулчейны (mise) живут в каталоге
   окружения на хосте и переживают перезапуск. Несколько изолированных окружений
   (`default`, `php8`, `rust`…) через `pibox -e ИМЯ`.
3. **Компактный образ** — multi-stage сборка (~0.7 ГБ): Ubuntu 24.04 + Node 22 + Pi + mise.
   Тяжёлые тулчейны агент ставит сам через mise в `~/.local` (персистентно).

## Ключевые компоненты репозитория

| Файл | Назначение |
|---|---|
| `Dockerfile` | multi-stage: ubuntu 24.04 + node 22 + pi + mise; ARG-версии пинуются |
| `entrypoint.sh` | от root: подстановка UID/GID хост-юзера → skel-merge (1-й запуск) → gosu → tini → pi |
| `run.sh` | исходник CLI `pibox` (после install — `~/pibox/bin/pibox`); подкоманды: run/build/env/shell |
| `install.sh` | установщик: создаёт `~/pibox`, bin в PATH, блок `>>> pibox installer >>>` в rc-файле |
| `models.json` | шаблон конфига моделей (локальный OpenAI-совместимый сервер по умолчанию) |
| `env/.template/` | шаблон `/home/pi` для новых окружений + стартовые знания агента (`.pi/agent/AGENTS.md`, скиллы `install-languages`, `workspace-hygiene`, `networking`) |
| `tests/smoke.sh` | ~90 автопроверок: install → build → CLI → runtime; флаги `--offline/--keep/--rebuild` |
| `agent/glm/` | план разработки и постановки задач (task1..task9) — история, не runtime-код |

Каталога `docs/` в репо пока нет (упоминается в README, но не создан).

## Контракты между компонентами (важно при правках)

- entrypoint ↔ Dockerfile: `/opt/skel`, переменные `HOST_UID`/`HOST_GID`, юзер `pi`, маркер инициализации.
- run.sh/install.sh → шаблон: `PIBOX_DIR/env/<name>`, `PIBOX_DIR/models.json`, `PIBOX_DIR/env/.template/`.
- install.sh: копирует `run.sh` → `~/pibox/bin/pibox`, build-контекст → `~/pibox/docker/`.
- Модель API с хоста доступна из контейнера как `http://host.docker.internal:8080`.

## Как проверять изменения

```bash
pibox build                    # или docker build
./tests/smoke.sh               # полный прогон ~2 мин; --offline / --keep / --rebuild
shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh   # так же в CI
```

CI (`.github/workflows/ci.yml`): shellcheck + проверка exec-битов + docker build.

## Правила и подводные камни

- **Прямой запуск `./run.sh` из чекаута создаёт окружения прямо в репо**
  (`env/<имя>`, дефолт PIBOX_DIR = каталог скрипта). Для экспериментов — либо
  `PIBOX_DIR=/tmp/pibox-test ./run.sh ...`, либо чистить env/ перед коммитом
  (git игнорирует env/*, мусор легко не заметить).

- Версии в Dockerfile: пиновать точные; Node builder (glibc) ≤ runtime (bookworm ≤ noble, не trixie).
- Файлы окружения (`env/*`, кроме шаблонов) при переустановке не затрагивать.
- Скрипты — LF-окончания (`.gitattributes` настроен, CRLF ломает `bad interpreter`).
- Безопасность: контейнер — НЕ полная песочница (сеть открыта, добавлены SYS_PTRACE и NET_RAW,
  код расширений выполняется с правами агента). API-ключи — через `-E VAR`/`--env-file`.
- Запуск pibox из самого `~/pibox` блокируется (защита от саморедактирования).
- Порты <1024 внутри контейнера недоступны (нет CAP_NET_BIND_SERVICE) — маппить наружу.
- Известные ограничения: capabilities сбрасываются после gosu (strace -p, tcpdump от pi),
  аргументы после `--` собираются в строку (пробелы искажаются).
- **Шаблон несёт стартовые знания агента** (`env/.template/.pi/agent/`): глобальный
  AGENTS.md и скиллы. Каждое новое окружение сразу «обучено». Копии: при изменении
  скиллов/инструкций обновлять в обоих местах — home текущего окружения
  (`~/.pi/agent/`) и шаблон в репо.

## Принятые решения

- **Знания агента живут в двух местах:** шаблон (`env/.template/.pi/agent/`) — для новых
  окружений, home текущего окружения (`~/.pi/agent/`) — рабочие копии, которые агент
  редактирует по ходу жизни. Синхронизация обратной стороны (env → шаблон) — вручную,
  осознанно: рабочие окружения пользователей не должны молча переучиваться при
  обновлении pibox.

## Статус

MVP готов (git: mvp + fix test). Лицензия MIT. Целевая платформа — Linux + Docker ≥ 20.10;
macOS/Windows — экспериментально.


