# PIBOX — CLI для безопасного запуска Pi Coding Agent в Docker.
# shellcheck disable=SC2034  # константы общие между модулями (после source)
# shellcheck shell=bash
#
# Подкоманды:
#   run (дефолт)   запуск агента в контейнере
#   webui          агент с браузерным UI (pi-web-ui): порт 8787, зелёная
#                   ссылка, в консоли — логи агента; Ctrl+C — остановка
#   build          сборка Docker-образа
#   env            управление окружениями (list, create, remove)
#   shell          отладочная оболочка в контейнере
#   update         обновление установки (пока заглушка)
#   doctor         диагностика окружения (аудит + --fix)
#   extensions     установка расширений из манифеста template/extensions.txt
#   user           слои шаблона: push (user→env) / pull (env→user)
#
# Опции запуска:
#   -e, --env NAME         окружение (по умолчанию default)
#   -p, --publish SPEC     проброс порта (повторяемая)
#   -E, --pass-env VAR     проброс переменной окружения (повторяемая)
#       --env-file FILE    файл с переменными окружения
#       --memory LIMIT     лимит памяти (напр. 4g)
#       --cpus N           лимит CPU
#       --pids-limit N     лимит процессов
#       --git-safe         git safe.directory для workspace
#       --keep             оставить контейнер после выхода (для отладки)
#       --dry-run          напечатать команду docker run и выйти
#       --name NAME        имя контейнера (по умолчанию pibox-<env>)
#   -h, --help             эта справка
#   -V, --version          версия
#
# Контракт с docker/entrypoint.sh — негласная связь: pibox CLI передаёт в
# контейнер три переменные через docker run -e (см. build_docker_run_cmd в
# docker-cmd.sh), а entrypoint.sh при старте их читает:
#   HOST_UID, HOST_GID     — UID/GID хост-пользователя; entrypoint заводит
#                            в контейнере юзера pi с этими UID/GID, чтобы
#                            файлы в bind-mount имели хозяина с хоста;
#   PIBOX_GIT_SAFE         — 1 = включить git safe.directory для workspace.
# Переименуешь переменные в одной из сторон (здесь или в entrypoint.sh) —
# ошибка не возникнет: entrypoint просто не увидит значения и молча возьмёт
# дефолты (UID=1000, git safe выключен). Подробности — docs/PROJECT.md,
# раздел «Контракты между компонентами».
# ============================================================================

# --- Константы ----------------------------------------------------------------

VERSION="0.1.0"
DEFAULT_ENV="default"
# Имя образа можно переопределить (smoke-тесты используют это для проверки
# поведения при отсутствии образа); по умолчанию — pibox:latest
IMAGE_NAME="${PIBOX_IMAGE:-pibox:latest}"

# PIBOX_DIR задаётся в bin/pibox (корень = bin/..) и экспортируется до
# source модулей; здесь — только страховочный fallback для прямого source
# lib/ (тесты, отладка).
PIBOX_DIR="${PIBOX_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- Хелперы -------------------------------------------------------------------

# \r\n: docker run -t переводит хостовый TTY в raw-режим (ONLCR отключён),
# поэтому «голый» \n даёт съехавшие отступы. В cooked-режиме лишний \r
# безвреден (терминал схлопывает \r\r\n).
err() { printf '%s\r\n' "pibox: error: $*" >&2; }
warn() { printf '%s\r\n' "pibox: warn:  $*" >&2; }
log() { printf '%s\r\n' "==> pibox: $*" >&2; }
die() {
    err "$*"
    exit 1
}

version() {
    echo "pibox ${VERSION}"
}

usage() {
    cat <<'EOF'
pibox — запуск Pi Coding Agent в изолированном Docker-контейнере

Использование:
    pibox [run] [OPTIONS] [--] [PI_ARGS...]

Подкоманды:
    run                        запуск агента (по умолчанию)
    webui [OPTS] [--port N]    агент с браузерным UI (pi-web-ui вшит
                               в образ): пробрасывает порт (по умолчанию
                               8787:8787), печатает зелёную ссылку,
                               дальше в консоль идут логи агента;
                               Ctrl+C — остановка. Опции как у run
                               (-e, -p, -E, --memory, ...); --port N —
                               другой порт (host и container)
    tg [OPTS]                  контейнер в режиме Telegram-моста: RPC-демон
                               pi + @llblab/pi-telegram — задания и отчёты
                               через бота. Нужен токен в
                               ~/.pi/agent/telegram.json (шаблон —
                               template/user). Без TTY/TUI; Ctrl+C —
                               остановка. Опции как у run (кроме
                               аргументов pi после --)
    build [--no-cache]         сборка Docker-образа
    env list|create|remove     управление окружениями
    env upgrade NAME [-n]      довести продуктовый каркас окружения до
                               актуального template/common (после обновления
                               pibox); -n — только показать, что изменится
    shell [-e NAME]            отладочная оболочка в контейнере
    status                     контейнеры pibox: запущенные (имя, env,
                               режим, статус) и остановленные
    update                     обновление установки
    doctor [-e NAME] [--fix]   диагностика окружения (аудит + --fix)
    extensions install         установка расширений из манифеста
                               template/extensions.txt (см. ниже)
    extensions list [-e NAME]  что установлено в окружении и состояние
                               относительно манифеста (см. ниже)
    user push|pull [-e NAME]   слой template/user: push — применить к
                               окружению (как при старте); pull [-n] —
                               сохранить правки агента из окружения
                               в template/user (переживут пересоздание env)

Опции extensions:
    pibox extensions install [-e NAME]
                               установить набор расширений в окружение NAME
                               (по умолчанию default). Окружение должно
                               существовать: pibox env create NAME. Ставит
                               недостающее/обновляет расхождение с манифестом;
                               уже установленное совпадающей версии пропускает.
                               При выполнении npm-установок агент НЕ запускается —
                               используется одноразовый контейнер.
    pibox extensions list [-e NAME]
                               что установлено в окружении NAME (по умолчанию
                               default): версии из манифеста и окружения,
                               состояние (актуален / устарел / не установлен /
                               не подключён) и ручные расширения, которых нет
                               в манифесте. Читает только файлы окружения —
                               docker не нужен.

Опции запуска:
    -e, --env NAME             окружение (по умолчанию default)
    -p, --publish SPEC         проброс порта (повторяемая)
    -E, --pass-env VAR         проброс переменной окружения (повторяемая)
        --env-file FILE        файл с переменными окружения
        --memory LIMIT         лимит памяти (напр. 4g)
        --cpus N               лимит CPU
        --pids-limit N         лимит процессов
        --git-safe             git safe.directory для workspace
        --keep                 оставить контейнер после выхода (для отладки)
        --dry-run              напечатать команду docker run и выйти
        --name NAME            имя контейнера (по умолчанию pibox-<env>)
    -h, --help                 эта справка
    -V, --version              версия

Dev-порт:
    Порт 3000 контейнера пробрасывается по умолчанию (-p 3000:3000):
    агент может поднимать тестовые серверы, доступные с хоста. Хост-порт
    передаётся агенту переменной PIBOX_DEV_PORT. Свой -p ХОСТ:3000
    заменяет авто-маппинг, -p 0:3000 отключает проброс; порт 3000
    в другой роли (-p 3000:8080) не конфликтует.

Примеры:
    pibox                      # запуск в default окружении
    pibox webui                # браузерный UI: http://localhost:8787
    pibox webui --port 9000    # то же на порту 9000
    pibox tg                   # Telegram-мост: задания/отчёты через бота
    pibox -e php8              # запуск в окружении php8
    pibox -p 8080:80           # проброс порта 8080 на 80
    pibox -- pi -p "test"      # передача аргументов pi
    pibox shell -e php8        # оболочка в окружении php8
    pibox status               # какие контейнеры pibox запущены
    pibox --keep               # оставить контейнер после выхода
    pibox extensions install   # эталонный набор расширений в default
    pibox user pull            # забрать правки агента в template/user

EOF
}

# --- Схема монтирования проекта -------------------------------------------------

# Проект монтируется НЕ в корень /home/pi/workspace, а в подкаталог по имени
# (basename) каталога, из которого запущен pibox:
#   /.../ProjectA  ->  /home/pi/workspace/ProjectA
#   /.../ProjectB  ->  /home/pi/workspace/ProjectB
# Рабочий каталог контейнера (docker run -w) — тот же подкаталог, так что
# агент стартует прямо в корне проекта (как раньше).
# Зачем: путь проекта в контейнере становится уникальным для каждого проекта
# (git toplevel = /home/pi/workspace/<имя>), что важно для инструментов,
# ключающих хранилище от пути проекта (pi-memory хэширует git toplevel/cwd).
# Известное ограничение: два разных хост-проекта с одинаковым именем каталога
# получат один путь (и одну память) — как и раньше, но только в этом случае.
workspace_name() {
    local name
    name="$(basename "$(pwd)")"
    # pwd = "/" -> basename даёт "/"; деградация к фиксированному имени
    [[ -n "$name" && "$name" != "/" ]] || name="project"
    printf '%s' "$name"
}

# Путь проекта внутри контейнера
workspace_path() {
    printf '/home/pi/workspace/%s' "$(workspace_name)"
}

# Очистка фантомных точек монтирования: mkdir -p перед запуском создаёт
# env/<имя>/workspace/<проект>, и после выхода контейнера пустой каталог
# остался бы навсегда (копятся с каждым новым проектом). Удаляем ТОЛЬКО
# пустые каталоги верхнего уровня workspace: непустые (agent писал мимо
# bind-mount, или каталог смонтирован в живом контейнере — rmdir даст
# EBUSY) не трогаем. Ошибки глушим: нет каталога — нет работы.
cleanup_workspace_mounts() {
    local env_name="$1"
    find "$PIBOX_DIR/env/$env_name/workspace" -mindepth 1 -maxdepth 1 \
        -type d -empty -exec rmdir {} + 2>/dev/null || true
}

# --- Проверки -------------------------------------------------------------------

# Проверка, что docker установлен и работает
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"
    fi

    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon не отвечает. Проверьте статус: systemctl status docker"
    fi
}

# Проверка имени окружения
validate_env_name() {
    local env_name="$1"
    if [[ ! "$env_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        die "Недопустимое имя окружения: '$env_name'. Разрешены буквы, цифры, точки, дефисы и подчёркивания."
    fi
}

# Проверка, что workspace не совпадает с PIBOX_DIR и не вложен в него
check_workspace_isolation() {
    local ws
    ws="$(pwd)"
    local ws_real
    local pibox_real

    # Получаем абсолютные пути без symlink'ов
    ws_real="$(realpath "$ws")"
    pibox_real="$(realpath "$PIBOX_DIR")"

    # Проверяем вложенность
    if [[ "$ws_real" == "$pibox_real" || "$ws_real" == "$pibox_real"/* ]]; then
        die "Workspace ($ws) находится внутри PIBOX_DIR ($PIBOX_DIR). Это запрещено."
    fi

    if [[ "$pibox_real" == "$ws_real"/* ]]; then
        die "PIBOX_DIR ($PIBOX_DIR) находится внутри workspace ($ws). Это запрещено."
    fi
}
