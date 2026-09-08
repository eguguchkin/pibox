# Задача 5 — `entrypoint.sh`

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent: `/home/pi` контейнера подменяется bind-mount'ом окружения с хоста, текущий каталог пользователя становится `workspace`. Entrypoint выполняется от root при каждом запуске, до старта агента. |
| **Цель задачи** | Реализовать полный `entrypoint.sh`: подстройка UID/GID пользователя `pi` под хост-юзера, первичный skel-merge с маркером, опциональный git safe.directory, передача управления через `gosu pi:pi tini -- "$@"`. |
| **Зависимости** | Задача 3 (образ с `gosu`, `tini`, `/opt/skel`, ENV-контракт), задача 4 (env-template — канонические дотфайлы) |
| **Артефакты** | `entrypoint.sh` — полная реализация, заменяющая заглушку из задачи 3 |
| **Не входит в задачу** | CLI `run.sh` (задача 6), установщик (задача 7), тесты (задача 8) |

---

## 🏗️ Ключевые архитектурные решения

| # | Решение | Обоснование |
|---|---|---|
| 1 | **GID меняется до UID** | `groupmod` + `usermod` в этом порядке избегает временного состояния с рассинхронизированной группой |
| 2 | **`find -user $old_uid` — только при фактической смене UID** | На повторных запусках UID не меняется → `find` не выполняется → нет прохода по большому env |
| 3 | **Skel-merge: `cp -rn` + `find -user 0` для chown** | `cp -rn` (no-clobber) не затирает пользовательские файлы; после копирования от root чиним владельца только у root-owned файлов |
| 4 | **`exec gosu pi:pi tini -- "$@"`** | `gosu` меняет UID/GID, `tini` — PID 1 (signal forwarding, zombie reaping), `"$@"` — переопределяемая команда (дефолт: `pi` из CMD) |
| 5 | **`export HOME/USER/PATH` перед exec** | `gosu` НЕ переписывает env-переменные. Без явного экспорта Pi пишет в `/root/.pi`, а mise-шимы не найдутся |
| 6 | **Git safe.directory через `GIT_CONFIG_*` env** | Не пишет в файлы пользователя; работает через переменные окружения git-конфигурации |
| 7 | **Отказ от UID/GID = 0** | Защита от случайного маппинга агента на root хоста |

---

## 1. Контракт с задачей 3 (Dockerfile)

| Переменная / путь | Значение | Комментарий |
|---|---|---|
| `HOST_UID` | число (env) | UID хост-пользователя; дефолт `1000` (сборочный UID pi) |
| `HOST_GID` | число (env) | GID хост-пользователя; дефолт `1000` |
| `PIBOX_GIT_SAFE` | `0`/`1` (env) | Включить git safe.directory для workspace |
| `PIBOX_RESYNC_SKEL` | `0`/`1` (env) | Принудительный повторный skel-merge |
| `/opt/skel` | каталог | Эталонный home из Dockerfile (задача 3) |
| `/home/pi` | bind-mount | Окружение с хоста (env/<name>) |
| `gosu`, `tini` | `/usr/bin/` | Установлены в образе (задача 3) |
| ENV образа | `HOME=/home/pi`, PATH с шимами | Переэкспортируются в entrypoint (защита от очистки) |

---

## 2. `entrypoint.sh` — полная реализация

```bash
#!/usr/bin/env bash
# ============================================================================
# PIBOX — entrypoint контейнера.
#
# Выполняется от root при КАЖДОМ запуске, до старта агента:
#   1. Подстройка UID/GID пользователя pi под хост-пользователя
#      (файлы в workspace принадлежат хост-юзеру, а не root)
#   2. Первичная инициализация: merge /opt/skel -> /home/pi (cp -rn,
#      только недостающие файлы), маркер для идемпотентности
#   3. Опционально: git safe.directory для workspace
#   4. Экспорт окружения (HOME, USER, PATH с mise-шимами)
#   5. Передача управления: exec gosu pi:pi tini -- "$@"
#
# Контракт с Dockerfile (задача 3):
#   - ENTRYPOINT ["/entrypoint.sh"], CMD ["pi"]
#   - /opt/skel — эталонный home (фолбэк-дотфайлы)
#   - gosu, tini — в /usr/bin/
#   - ENV HOME=/home/pi, PATH с mise-шимами — переэкспортируются здесь
#
# Контракт с run.sh (задача 6):
#   - HOST_UID, HOST_GID — передаются через -e
#   - PIBOX_GIT_SAFE=1, PIBOX_RESYNC_SKEL=1 — опциональные флаги
# ============================================================================

set -euo pipefail

# --- Константы ---------------------------------------------------------------

readonly PI_USER="pi"
readonly PI_GROUP="pi"
readonly PI_HOME="/home/pi"
readonly SKEL_DIR="/opt/skel"
readonly MARKER_FILE="${PI_HOME}/.pibox_skel_initialized"
readonly WORKSPACE_DIR="${PI_HOME}/workspace"

# --- Хелперы -----------------------------------------------------------------

log()  { echo "==> pibox: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
err()  { echo "pibox: error: $*" >&2; }
die()  { err "$*"; exit 1; }

# --- 1. Чтение и валидация HOST_UID / HOST_GID -------------------------------

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Валидация: только положительные числа
if ! [[ "$HOST_UID" =~ ^[1-9][0-9]*$ ]]; then
    die "HOST_UID='${HOST_UID}' не является корректным UID (положительное число)"
fi
if ! [[ "$HOST_GID" =~ ^[1-9][0-9]*$ ]]; then
    die "HOST_GID='${HOST_GID}' не является корректным GID (положительное число)"
fi

# Отказ от root: агент не должен маппиться на root хоста
if [ "$HOST_UID" -eq 0 ] || [ "$HOST_GID" -eq 0 ]; then
    die "refusing to map container user to host root (UID/GID=0). \
Это дало бы агенту root-эквивалентные права на файлы хоста."
fi

# --- 2. Подстройка UID/GID пользователя pi -----------------------------------

adjust_uid_gid() {
    local cur_uid cur_gid

    cur_uid="$(id -u "$PI_USER")"
    cur_gid="$(id -g "$PI_USER")"

    # 2a. GID (меняем первым — usermod может завязываться на группу)
    if [ "$cur_gid" != "$HOST_GID" ]; then
        log "adjusting GID of '${PI_GROUP}': ${cur_gid} -> ${HOST_GID}"
        groupmod -o -g "$HOST_GID" "$PI_GROUP"

        # Чиним group-ownership файлов, созданных контейнером под старым GID.
        # Файлы из bind-mount уже имеют правильный GID хоста — их не трогаем.
        # find без -xdev: workspace — отдельный bind-mount внутри /home/pi.
        find "$PI_HOME" -group "$cur_gid" \
            -exec chown -h ":${HOST_GID}" {} + 2>/dev/null || true
    fi

    # 2b. UID
    if [ "$cur_uid" != "$HOST_UID" ]; then
        log "adjusting UID of '${PI_USER}': ${cur_uid} -> ${HOST_UID}"
        usermod -o -u "$HOST_UID" "$PI_USER"

        # Чиним ownership файлов, созданных контейнером под старым UID.
        # (сессии Pi, mise-тулчейны, npm-установки — всё, что pi создал ранее)
        find "$PI_HOME" -user "$cur_uid" \
            -exec chown -h "${HOST_UID}" {} + 2>/dev/null || true
    fi

    # 2c. Гарантия: сам каталог /home/pi принадлежит целевому UID:GID
    chown "${HOST_UID}:${HOST_GID}" "$PI_HOME"
}

# --- 3. Первичная инициализация (skel-merge) ----------------------------------

merge_skel() {
    # 3a. Принудительный повторный merge (флаг из run.sh)
    if [ "${PIBOX_RESYNC_SKEL:-0}" = "1" ]; then
        log "PIBOX_RESYNC_SKEL=1 — removing marker, will re-merge skel"
        rm -f "$MARKER_FILE"
    fi

    # 3b. Уже инициализировано — пропускаем
    if [ -e "$MARKER_FILE" ]; then
        return 0
    fi

    log "first run — merging ${SKEL_DIR} into ${PI_HOME}"

    # 3c. Проверка наличия skel (не фатально — env может не нуждаться)
    if [ ! -d "$SKEL_DIR" ]; then
        warn "skel directory ${SKEL_DIR} not found, skipping merge"
        touch "$MARKER_FILE"
        chown "${HOST_UID}:${HOST_GID}" "$MARKER_FILE"
        return 0
    fi

    # 3d. Копируем ТОЛЬКО недостающие файлы (cp -n = no-clobber).
    #     /. в конце — ОБЯЗАТЕЛЬНО: без него dot-файлы не копируются.
    #     cp выполняется от root → скопированные файлы принадлежат root.
    cp -rn "${SKEL_DIR}/." "${PI_HOME}/"

    # 3e. Чиним владельца ТОЛЬКО у root-owned файлов (только что скопированных).
    #     Файлы из bind-mount (env-template) уже принадлежат хост-юзеру.
    find "$PI_HOME" -user 0 \
        -exec chown -h "${HOST_UID}:${HOST_GID}" {} + 2>/dev/null || true

    # 3f. Создаём маркер (от root, затем чиним владельца)
    touch "$MARKER_FILE"
    chown "${HOST_UID}:${HOST_GID}" "$MARKER_FILE"

    log "skel merge complete, marker: ${MARKER_FILE}"
}

# --- 4. Git safe.directory (опционально) --------------------------------------

setup_git_safe() {
    if [ "${PIBOX_GIT_SAFE:-0}" = "1" ]; then
        log "git safe.directory enabled for ${WORKSPACE_DIR}"

        # Через переменные окружения git — не пишем в файлы пользователя.
        # git читает GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n.
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=safe.directory
        export GIT_CONFIG_VALUE_0="$WORKSPACE_DIR"
    fi
}

# --- 5. Подготовка окружения для exec -----------------------------------------

prepare_env() {
    # КРИТИЧНО: gosu меняет UID/GID, но НЕ переписывает env-переменные.
    # Без явного экспорта:
    #   - Pi пишет сессии в /root/.pi (не в /home/pi/.pi)
    #   - mise-шимы (~/.local/share/mise/shims) не находятся
    #   - npm prefix (~/.npmrc) не резолвится

    export HOME="$PI_HOME"
    export USER="$PI_USER"

    # PATH: user-local bin + mise shims + системные пути.
    # Дублируем ENV из Dockerfile — на случай, если что-то его очистило.
    export PATH="${PI_HOME}/.local/bin:${PI_HOME}/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# --- 6. Передача управления ----------------------------------------------------

exec_command() {
    # gosu pi:pi — смена UID/GID (exec, не fork — PID 1 сохраняется)
    # tini       — PID 1: проброс сигналов, reaping зомби
    # "$@"       — команда из CMD (дефолт: pi) или override (bash, pi -p ...)
    #
    # Процессная цепочка:
    #   PID 1: entrypoint.sh (bash)
    #     → exec gosu (PID 1, замена образа процесса)
    #       → gosu exec tini (PID 1)
    #         → tini fork → child: pi (не PID 1)
    #         → tini wait → signal forwarding, zombie reaping

    if [ "${PIBOX_DEBUG:-0}" = "1" ]; then
        log "exec: gosu ${PI_USER}:${PI_GROUP} tini -- $*"
        log "  HOME=$HOME"
        log "  USER=$USER"
        log "  PATH=$PATH"
        log "  UID=$(id -u $PI_USER) GID=$(id -g $PI_USER)"
    fi

    exec gosu "${PI_USER}:${PI_GROUP}" tini -- "$@"
}

# --- Main ----------------------------------------------------------------------

main() {
    # Проверяем, что мы root (entrypoint должен запускаться от root)
    if [ "$(id -u)" -ne 0 ]; then
        die "entrypoint must run as root (current UID: $(id -u)). \
Check Dockerfile ENTRYPOINT."
    fi

    # Проверяем, что пользователь pi существует
    if ! id "$PI_USER" >/dev/null 2>&1; then
        die "user '${PI_USER}' not found. Image is corrupted or misconfigured."
    fi

    adjust_uid_gid
    merge_skel
    setup_git_safe
    prepare_env
    exec_command "$@"
}

main "$@"
```

---

## 3. Разбор по секциям

### 3.1 Валидация HOST_UID/HOST_GID

```bash
HOST_UID="${HOST_UID:-1000}"  # дефолт из Dockerfile (сборочный UID pi)
HOST_GID="${HOST_GID:-1000}"
```

| Проверка | Причина |
|---|---|
| Число > 0 | `usermod`/`groupmod` требуют числовой UID/GID |
| ≠ 0 | Маппинг на root дал бы агенту root-права на файлы хоста — прямо противоречит цели проекта |

### 3.2 Подстройка UID/GID — почему в таком порядке

```
1. groupmod -o -g $HOST_GID pi     ← GID первым
2. usermod  -o -u $HOST_UID pi     ← UID вторым
```

**Причина:** `usermod` может пересоздать запись в `/etc/passwd` с привязкой к primary group. Если GID уже обновлён, `usermod` корректно подхватит новый GID.

**`find` для фикса ownership:**
```bash
find "$PI_HOME" -user "$cur_uid" -exec chown -h "$HOST_UID" {} +
```

- Выполняется **только при фактической смене** (на повторных запусках `cur_uid == HOST_UID` → skip)
- `-user "$cur_uid"` — фильтр по старому UID, не трогаем файлы хоста
- `-h` — менять symlink, не target
- `2>/dev/null || true` — файлы могут быть недоступны (read-only mount); это не фатально

### 3.3 Skel-merge — механика

```
Первый запуск:
  1. Маркера нет → cp -rn /opt/skel/. /home/pi/
  2. cp от root → скопированные файлы owned by root
  3. find -user 0 → chown на HOST_UID:HOST_GID
  4. touch маркер → chown маркер

Повторные запуски:
  1. Маркер есть → return 0 (ничего не делаем)

PIBOX_RESYNC_SKEL=1:
  1. rm маркер
  2. Далее как первый запуск (но cp -rn не перезапишет существующее)
```

**Почему `find -user 0`, а не `chown -R`:**
- `chown -R` затронул бы ВСЕ файлы, включая уже правильно owned (из bind-mount)
- `find -user 0` — только те, что скопировал root в этом запуске
- Безопасно даже если в env есть root-owned файлы хоста (их не тронем — они не `user 0` после mount)

### 3.4 Git safe.directory — почему через env

```bash
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0=/home/pi/workspace
```

Git ≥ 2.31 поддерживает конфигурацию через переменные окружения `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`. Это эквивалентно `git config --global safe.directory /path`, но:

- **Не пишет в файлы** пользователя (`.gitconfig` остаётся нетронутым)
- Действует только для текущего процесса (и его детей через exec)
- Чисто отключается: не выставили переменные → git работает стандартно

### 3.5 `prepare_env()` — почему критично

```
gosu pi:pi tini -- pi
     ↑
     gosu ВЫЗЫВАЕТ setuid()/setgid() и execvp()
     НО НЕ ТРОГАЕТ environment!
```

Если не экспортировать `HOME`:
- Pi ищет конфиг в `$HOME/.pi` → `$HOME` = `/root` (унаследован от root) → **сессии пишутся в `/root/.pi`**, невидимы для пользователя

Если не экспортировать `PATH` с шимами:
- `mise activate` в `.bashrc` работает только в интерактивных сессиях
- Неинтерактивный запуск `pi` не найдёт тулчейны в `~/.local/share/mise/shims/`

### 3.6 exec-цепочка

```
Container start:
  PID 1 = /entrypoint.sh (bash)
    |
    v exec (заменяет образ процесса, PID остаётся 1)
  PID 1 = gosu pi:pi tini -- pi
    |
    v gosu: setuid(1001), setgid(1001), execvp("tini", ["tini", "--", "pi"])
  PID 1 = tini -- pi
    |
    v tini: fork()
  PID 1 = tini (родитель: waitpid, signal forwarding, zombie reaping)
  PID N = pi (ребёнок: работа агента)
```

**Почему `tini` нужен:** без init-процесса PID 1 в контейнере не пробрасывает SIGTERM корректно. `docker stop` отправляет SIGTERM PID 1; без tini bash может его проигнорировать → контейнер убивается по timeout (SIGKILL) → потеря несохранённых данных.

---

## 4. Обновление заглушки → полная версия

Файл `entrypoint.sh` из задачи 3 (заглушка `exec "$@"`) **полностью заменяется** кодом из раздела 2.

```bash
# Проверка после замены:
shellcheck entrypoint.sh
# Ожидание: 0 замечаний

# Проверка синтаксиса:
bash -n entrypoint.sh
# Ожидание: без ошибок
```

---

## 5. Верификация (локальные тесты без Docker)

### 5.1 Подготовка тестового окружения

```bash
#!/bin/bash
# tests/entrypoint-local.sh — локальная проверка entrypoint без Docker

set -euo pipefail

TESTDIR=$(mktemp -d /tmp/pibox-entrypoint-test-XXXXXX)
FAKE_ENV="$TESTDIR/env"
FAKE_SKEL="$TESTDIR/skel"

trap 'rm -rf "$TESTDIR"' EXIT

# Имитация /opt/skel (как в Dockerfile задачи 3)
mkdir -p "$FAKE_SKEL"
cat > "$FAKE_SKEL/.bashrc" <<'EOF'
# skel bashrc
export TEST_SKEL=1
EOF
cat > "$FAKE_SKEL/.bash_logout" <<'EOF'
# skel bash_logout
EOF

# Имитация /home/pi (bind-mount из env-template задачи 4)
mkdir -p "$FAKE_ENV/.pi/agent/sessions"
cat > "$FAKE_ENV/.bashrc" <<'EOF'
# user bashrc (canonical, from env-template)
export TEST_USER=1
EOF

echo "=== Тестовое окружение создано ==="
echo "SKEL: $FAKE_SKEL"
echo "ENV:  $FAKE_ENV"
```

### 5.2 Тест сценариев

```bash
# Тест 1: UID/GID подстройка (в контейнере)
# (требует docker — см. раздел 6)

# Тест 2: skel-merge (симуляция)
# Копируем как в entrypoint
cp -rn "$FAKE_SKEL/." "$FAKE_ENV/"

# Проверяем: .bashrc НЕ перезаписан (user version)
grep -q "TEST_USER=1" "$FAKE_ENV/.bashrc" && echo "PASS: .bashrc не перезаписан"

# Проверяем: .bash_logout скопирован (из skel)
[ -f "$FAKE_ENV/.bash_logout" ] && echo "PASS: .bash_logout скопирован из skel"

# Тест 3: идемпотентность merge
BEFORE=$(stat -c %Y "$FAKE_ENV/.bashrc" 2>/dev/null || echo "0")
cp -rn "$FAKE_SKEL/." "$FAKE_ENV/"
AFTER=$(stat -c %Y "$FAKE_ENV/.bashrc" 2>/dev/null || echo "0")
[ "$BEFORE" = "$AFTER" ] && echo "PASS: повторный merge не изменяет существующие файлы"
```

---

## 6. Верификация в Docker

```bash
# 6.1 Подготовка: собрать образ (задача 3) с новым entrypoint
docker build -t pibox:latest .

# 6.2 Тест: базовый запуск
docker run --rm pibox:latest bash -c 'echo "OK: entrypoint works"'

# 6.3 Тест: UID/GID подстройка
docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  pibox:latest bash -c 'id'

# Ожидание: uid=<ваш_uid>(pi) gid=<ваш_gid>(pi)
# НЕ должно быть uid=1000 (сборочный дефолт)

# 6.4 Тест: skel-merge с bind-mount
mkdir -p /tmp/pibox-test-env /tmp/pibox-test-ws
echo "test" > /tmp/pibox-test-ws/testfile.txt

docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /tmp/pibox-test-env:/home/pi \
  -v /tmp/pibox-test-ws:/home/pi/workspace \
  pibox:latest bash -c '
    echo "=== Home contents ==="
    ls -la /home/pi/
    echo "=== Marker ==="
    ls -la /home/pi/.pibox_skel_initialized 2>/dev/null || echo "NO MARKER"
    echo "=== Workspace ==="
    cat /home/pi/workspace/testfile.txt
    echo "=== Ownership ==="
    stat -c "%u:%g %n" /home/pi/.bash_logout /home/pi/.pibox_skel_initialized 2>/dev/null
  '

# Ожидание:
#   - .bash_logout существует (из skel, owned by HOST_UID)
#   - .pibox_skel_initialized существует (owned by HOST_UID)
#   - testfile.txt читается

# 6.5 Тест: идемпотентность (второй запуск)
docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /tmp/pibox-test-env:/home/pi \
  pibox:latest bash -c 'ls /home/pi/.pibox_skel_initialized'

# Ожидание: файл существует (marker сохранился между запусками)

# 6.6 Тест: пользовательский файл не перезаписывается
echo "user content" > /tmp/pibox-test-env/.bashrc

docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /tmp/pibox-test-env:/home/pi \
  pibox:latest cat /home/pi/.bashrc

# Ожидание: "user content" (НЕ "skel bashrc")

# 6.7 Тест: workspace доступен
docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /tmp/pibox-test-env:/home/pi \
  -v /tmp/pibox-test-ws:/home/pi/workspace \
  pibox:latest bash -c 'echo "test from container" > /home/pi/workspace/container-test.txt'

# На хосте:
cat /tmp/pibox-test-ws/container-test.txt
stat -c "%u:%g" /tmp/pibox-test-ws/container-test.txt
# Ожидание: uid = ваш (не root!)

# 6.8 Тест: git safe.directory
docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -e PIBOX_GIT_SAFE=1 \
  -v /tmp/pibox-test-env:/home/pi \
  -v /tmp/pibox-test-ws:/home/pi/workspace \
  pibox:latest bash -c 'cd /home/pi/workspace && git init && git status'

# Ожидание: git не ругается на "dubious ownership"

# 6.9 Тест: HOME и PATH корректны
docker run --rm \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /tmp/pibox-test-env:/home/pi \
  pibox:latest bash -c '
    echo "HOME=$HOME"
    echo "USER=$USER"
    echo "PATH=$PATH" | tr ":" "\n" | head -5
    which mise
  '

# Ожидание:
#   HOME=/home/pi
#   USER=pi
#   PATH начинается с /home/pi/.local/bin и /home/pi/.local/share/mise/shims
#   mise находится

# 6.10 Очистка
rm -rf /tmp/pibox-test-env /tmp/pibox-test-ws
```

---

## 7. ✅ Критерии готовности

- [ ] `shellcheck entrypoint.sh` — 0 замечаний
- [ ] `bash -n entrypoint.sh` — без синтаксических ошибок
- [ ] `docker run --rm pibox:latest bash -c 'echo OK'` — работает
- [ ] `docker run --rm -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) pibox:latest id` — показывает хостовый UID/GID
- [ ] Skel-merge: первый запуск создаёт маркер + `.bash_logout` из skel
- [ ] Skel-merge: пользовательский `.bashrc` НЕ перезаписывается
- [ ] Skel-merge: второй запуск — маркер на месте, merge не повторяется
- [ ] Файл, созданный в workspace контейнером, принадлежит хост-пользователю (не root)
- [ ] `HOME=/home/pi`, `USER=pi`, `PATH` с mise-шимами — при запуске через entrypoint
- [ ] `PIBOX_GIT_SAFE=1` — git status в workspace без "dubious ownership"
- [ ] `PIBOX_RESYNC_SKEL=1` — маркер удаляется, merge выполняется повторно
- [ ] Отказ при `HOST_UID=0` или `HOST_GID=0` — понятная ошибка, exit 1
- [ ] Отказ при нечисловом `HOST_UID` — понятная ошибка, exit 1
- [ ] `exec gosu pi:pi tini -- "$@"` — работает с любыми аргументами (`bash`, `pi -p "test"`, etc.)

---

## 8. ⚠️ Подводные камни

| # | Проблема | Решение в реализации |
|---|---|---|
| 1 | **Забытый `export HOME`** — самая частая ошибка entrypoint'ов с gosu | Явный `export HOME=$PI_HOME` в `prepare_env()` + комментарий с объяснением |
| 2 | **`cp -rn` без `/.`** — dot-файлы не копируются | `"${SKEL_DIR}/."` — с явным `/.` в конце |
| 3 | **`chown -R` на каждый запуск** — медленно на больших env, портит mtimes | `find -user $cur_uid` только при смене UID; `find -user 0` только при skel-merge |
| 4 | **`usermod` с занятым UID** — конфликт с системным пользователем | `-o` (allow non-unique); конфликты с системными UID (33=www-data и т.д.) не критичны |
| 5 | **`gosu` не переписывает env** — HOME остаётся `/root` | Явный re-export всех критичных переменных перед exec |
| 6 | **`tini` как PID 1** — без него SIGTERM от `docker stop` теряется | `exec gosu pi:pi tini -- "$@"` — tini становится PID 1 через цепочку exec |
| 7 | **`find -xdev`** — может пропустить workspace bind-mount | Убран `-xdev`; `/home/pi` в контейнере не содержит проблемных mount'ов |
| 8 | **Символьные ссылки** — `chown` без `-h` меняет target, не link | `-h` во всех `chown` через `find -exec` |
| 9 | **Пустой `$@`** — `tini --` без команды | Docker всегда передаёт CMD (дефолт `pi`); пустой случай не встречается на практике |
| 10 | **Вход не от root** — entrypoint запущен обычным пользователем | Явная проверка `id -u != 0` → die с понятным сообщением |

---

## 9. 🔗 Контракты, зафиксированные задачей 5

### Входные переменные (env, устанавливаются `docker run -e`)

| Переменная | Дефолт | Валидация | Назначение |
|---|---|---|---|
| `HOST_UID` | `1000` | число > 0, ≠ 0 | UID хост-пользователя для маппинга pi |
| `HOST_GID` | `1000` | число > 0, ≠ 0 | GID хост-пользователя для маппинга pi |
| `PIBOX_GIT_SAFE` | `0` | `0`/`1` | Включить git safe.directory для workspace |
| `PIBOX_RESYNC_SKEL` | `0` | `0`/`1` | Принудительный повторный skel-merge |
| `PIBOX_DEBUG` | `0` | `0`/`1` | Verbose-вывод при exec |

### Состояние после выполнения

| Артефакт | Расположение | Назначение |
|---|---|---|
| Маркер инициализации | `/home/pi/.pibox_skel_initialized` | Флаг «первичный merge выполнен» |
| Dot-файлы из skel | `/home/pi/.bash_logout` (и др.) | Недостающие файлы, скопированные с `-n` |
| Владелец файлов | `HOST_UID:HOST_GID` | Все файлы в `/home/pi` и workspace |

### Выход (exec)

```bash
exec gosu pi:pi tini -- "$@"
# "$@" = команда из CMD (дефолт: "pi") или override из docker run
```

**Что получают следующие задачи:**

| Задача | Получает |
|---|---|
| **6 (run.sh)** | Контракт env-переменных: `HOST_UID`, `HOST_GID`, `PIBOX_GIT_SAFE`, `PIBOX_RESYNC_SKEL` — передаются через `-e` в `docker run` |
| **8 (тесты)** | Готовые сценарии проверки из раздела 6 как основу smoke-тестов |