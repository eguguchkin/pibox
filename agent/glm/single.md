# Реализация PIBOX

Ниже — полная реализация проекта: все скрипты, шаблоны и документация, готовые к копированию в репозиторий. Перед кодом — краткая сводка принятых инженерных решений (включая места, где спецификацию пришлось «доработать напильником», чтобы она работала на практике).

## Ключевые решения и уточнения к ТЗ

| Вопрос | Решение |
|---|---|
| Точка входа | `run.sh` в репозитории — это и есть CLI `pibox`; `install.sh` копирует его в `PIBOX_DIR/bin/pibox`. Расположение `PIBOX_DIR` определяется по месту скрипта (работает и из репозитория, и после установки) |
| Установка Pi | Pi ставится в образ глобально через npm (`@mariozechner/pi`, переопределяется build-arg `PI_PACKAGE`). Поверх apt-версии Node 18 в `/usr/local` ставится актуальный Node 22 — иначе современные npm-пакеты агента могут не запуститься |
| `cat`, `xargs` | Отдельных apt-пакетов не существует (это coreutils/findutils, уже в базовом образе) — прокомментировано в Dockerfile, чтобы не ломать `apt-get install` |
| Тяжёлые тулчейны | `cmake`, `golang`, `rust/cargo` действительно ставятся агентом через `mise` в `~/.local` (персистентно в env). Но `gdb`, `valgrind`, `strace`, `tcpdump`, `sysstat`, `iotop` через mise поставить **нельзя** — для них добавлен механизм `~/.pibox/apt-packages.txt`: пакеты ставятся в контейнер при старте (root, из entrypoint), скачанные `.deb` кэшируются в env. Управление: `pibox env pkg add/rm/...` |
| pip в Ubuntu 24.04 | PEP 668: в образ пишется `/etc/pip.conf` с `break-system-packages`, чтобы агент мог ставить пакеты в `~/.local` |
| npm-пакеты агента | `~/.npmrc` с `prefix=${HOME}/.local` — `npm i -g` агентом попадает в env и переживает перезапуски |
| `git safe.directory` | Опция `--git-safe` (по умолчанию выключена); внутри контейнера пишется `safe.directory=*` в system-конфиг — иначе git ругается на вложенные репозитории/сабмодули в workspace |
| yq | В Ubuntu это python-обёртка (jq-синтаксис), не mikefarah/go-yq — поведение отличается, отмечено в README |
| Модели | `models.json` — явно шаблон с `_readme`-комментариями; точную схему нужно сверить с документацией pi.dev. Ключи API пробрасываются переменными окружения |
| Доп. безопасность | `--security-opt no-new-privileges`, `--pids-limit` (по умолчанию 1024), никаких монтирований docker.sock |
| Команды CLI | `run`, `shell`, `exec`, `build`, `env (list/create/remove/reset/path/pkg)`, `ps`, `doctor`, `help`, `version`; авто-сборка образа при первом запуске; `--dry-run` для отладки |

## Структура репозитория

```
pibox/                              ← корень репозитория
├── run.sh                          ← CLI «pibox» (аналог из ТЗ; ставится как bin/pibox)
├── install.sh                      ← установщик на хост
├── Dockerfile                      ← multi-stage сборка образа
├── entrypoint.sh                   ← инициализация контейнера
├── models.json                     ← шаблон для PIBOX_DIR/env/models.json
├── .gitignore
├── README.md
└── env-template/                   ← шаблон /home/pi для новых окружений
    ├── .bashrc
    ├── .profile
    ├── .inputrc
    ├── .gitconfig
    ├── .npmrc
    ├── .tmux.conf
    ├── .pi/
    │   └── agent/
    │       ├── AGENTS.md
    │       ├── extensions/README.md
    │       ├── prompts/README.md
    │       ├── sessions/.gitkeep
    │       └── skills/
    │           ├── README.md
    │           └── pibox-toolchains/SKILL.md
    └── .pibox/
        └── apt-packages.txt
```

После установки (`~/pibox`): `bin/pibox`, `docker/{Dockerfile,entrypoint.sh}` (маленький build-контекст, чтобы `env/` с тулчейнами не попадал в docker-контекст), `env-template/`, `env/{models.json,default/}`.

---

## `run.sh` — CLI `pibox`

```bash
#!/usr/bin/env bash
# ============================================================================
#  pibox — безопасный запуск Pi Coding Agent (https://pi.dev/) в Docker.
#
#  Единственная точка входа (подкоманды). install.sh копирует этот файл в
#  $PIBOX_DIR/bin/pibox; скрипт также работает прямо из репозитория.
#
#  Требования: bash >= 4.4, docker >= 20.10, coreutils.
# ============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="pibox"

# ----------------------------------------------------------------------------
# Вывод
# ----------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_OK=$'\e[1;32m' C_WARN=$'\e[1;33m' C_ERR=$'\e[1;31m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
    C_OK='' C_WARN='' C_ERR='' C_DIM='' C_OFF=''
fi

info() { printf '%s\n' "${C_OK}${PROG}${C_OFF} $*" >&2; }
warn() { printf '%s\n' "${C_WARN}${PROG}: предупреждение${C_OFF} $*" >&2; }
die()  { printf '%s\n' "${C_ERR}${PROG}: ошибка${C_OFF} $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# PIBOX_DIR: переменная окружения -> расположение скрипта -> ~/pibox
# ----------------------------------------------------------------------------
if [ -z "${PIBOX_DIR:-}" ]; then
    _self="${BASH_SOURCE[0]}"
    case $_self in */*) ;; *) _self="$(command -v "$_self" || true)" ;; esac
    if command -v readlink >/dev/null 2>&1 && readlink -f "$_self" >/dev/null 2>&1; then
        _self="$(readlink -f "$_self")"
    fi
    _d="$(dirname -- "$_self")"
    if [ -d "$_d/env-template" ]; then
        PIBOX_DIR="$_d"
    elif [ -d "${_d%/*}/env-template" ]; then
        PIBOX_DIR="${_d%/*}"
    else
        PIBOX_DIR="$HOME/pibox"
    fi
    unset _self _d
fi
# docker требует абсолютные пути для bind-mount'ов
if [ -d "$PIBOX_DIR" ]; then PIBOX_DIR="$(cd "$PIBOX_DIR" && pwd -P)"; fi

# ----------------------------------------------------------------------------
# Значения по умолчанию (переопределяются переменными окружения и опциями)
# ----------------------------------------------------------------------------
OPT_IMAGE="${PIBOX_IMAGE:-pibox:latest}"
DEFAULT_ENV="${PIBOX_ENV:-default}"
OPT_CPUS="${PIBOX_CPUS:-2}"
OPT_MEM="${PIBOX_MEMORY:-4g}"
OPT_PIDS="${PIBOX_PIDS:-1024}"
OPT_GIT_SAFE="${PIBOX_GIT_SAFE:-0}"

# Переменные, автоматически пробрасываемые в контейнер (если заданы на хосте)
PASS_KEYS=(
    ANTHROPIC_API_KEY OPENAI_API_KEY GROQ_API_KEY OPENROUTER_API_KEY
    GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY
    MISTRAL_API_KEY XAI_API_KEY DEEPSEEK_API_KEY TOGETHER_API_KEY
    HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy
)

OPT_ENV=''
OPT_CDIR=''
OPT_NAME=''
OPT_OFFLINE=0
OPT_DRY_RUN=0
OPT_NO_BUILD=0
OPT_NO_CACHE=0
OPT_PULL=0
PORTS=()
PASS_ENV_VARS=()
BUILD_ARGS=()

# ----------------------------------------------------------------------------
# Вспомогательные функции
# ----------------------------------------------------------------------------

# realpath существующего пути; при отсутствии realpath — python3 (macOS и т.п.)
rp() {
    local p="$1" out
    if out="$(realpath -e "$p" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, sys
p = sys.argv[1]
sys.exit(0 if os.path.exists(p) else 1)
print(os.path.realpath(p))' "$p"
        return
    fi
    return 1
}

require_pibox_dir() {
    [ -d "$PIBOX_DIR" ] || die "PIBOX_DIR не существует: $PIBOX_DIR — выполните install.sh"
    [ -d "$PIBOX_DIR/env-template" ] || die "$PIBOX_DIR/env-template не найден — переустановите pibox"
    if [ ! -d "$PIBOX_DIR/env" ]; then
        mkdir -p "$PIBOX_DIR/env" || die "не удалось создать $PIBOX_DIR/env"
    fi
}

require_docker() {
    command -v docker >/dev/null 2>&1 \
        || die "docker не установлен: https://docs.docker.com/engine/install/"
    docker info >/dev/null 2>&1 \
        || die "docker-демон недоступен (Docker запущен? пользователь в группе docker?)"
}

# Docker >= 20.10 — поддержка --add-host host.docker.internal:host-gateway
docker_supports_host_gateway() {
    local v maj rest min
    v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    [ -n "$v" ] || return 1
    maj="${v%%.*}"
    rest="${v#*.}"
    if [ "$rest" = "$v" ]; then min=0; else min="${rest%%.*}"; fi
    case "$maj" in ''|*[!0-9]*) return 1 ;; esac
    case "$min" in ''|*[!0-9]*) min=0 ;; esac
    if [ "$maj" -lt 20 ]; then return 1; fi
    if [ "$maj" -eq 20 ] && [ "$min" -lt 10 ]; then return 1; fi
    return 0
}

valid_env_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# models.json копируется в окружение только если его там ещё нет
copy_models_into_env() {
    local env_dir="$1"
    if [ ! -f "$env_dir/.pi/agent/models.json" ] && [ -f "$PIBOX_DIR/env/models.json" ]; then
        mkdir -p "$env_dir/.pi/agent"
        cp "$PIBOX_DIR/env/models.json" "$env_dir/.pi/agent/models.json"
        info "models.json скопирован в $env_dir/.pi/agent/models.json"
    fi
}

# Создание окружения при необходимости + models.json
ensure_env() {
    local name="$1"
    local env_dir="$PIBOX_DIR/env/$name"
    valid_env_name "$name" \
        || die "недопустимое имя окружения: '$name' (допустимы буквы, цифры и . _ -)"
    if [ ! -d "$env_dir" ]; then
        info "Окружение '$name' не найдено — создаю из шаблона ($PIBOX_DIR/env-template)"
        cp -a "$PIBOX_DIR/env-template" "$env_dir" \
            || { rm -rf "$env_dir"; die "не удалось создать окружение '$name'"; }
    fi
    copy_models_into_env "$env_dir"
}

# Запрет: workspace не должен совпадать с PIBOX_DIR, быть его потомком или предком
check_workspace() {
    local ws="$1"
    local ws_real pibox_real
    ws_real="$(rp "$ws")" || die "не удалось определить абсолютный путь workspace: $ws"
    pibox_real="$(rp "$PIBOX_DIR")" || die "не удалось определить абсолютный путь PIBOX_DIR"
    if [ "$ws_real" = "$pibox_real" ]; then
        die "рабочая директория совпадает с PIBOX_DIR ($pibox_real) — запуск запрещён"
    fi
    if [[ "$ws_real/" == "$pibox_real/"* ]]; then
        die "рабочая директория ($ws_real) внутри PIBOX_DIR ($pibox_real) — запуск запрещён"
    fi
    if [[ "$pibox_real/" == "$ws_real/"* ]]; then
        die "PIBOX_DIR ($pibox_real) внутри рабочей директории ($ws_real) — запуск запрещён"
    fi
}

ensure_image() {
    if [ "$OPT_NO_BUILD" = "1" ]; then return 0; fi
    if docker image inspect "$OPT_IMAGE" >/dev/null 2>&1; then return 0; fi
    info "Образ $OPT_IMAGE не найден — собираю (первая сборка занимает несколько минут)"
    cmd_build
}

usage() {
    cat <<EOF
pibox $VERSION — безопасный запуск Pi Coding Agent (pi.dev) в Docker

Использование:
  pibox [ОПЦИИ] [-- АРГУМЕНТЫ_PI]       запустить pi в текущей директории
  pibox run  [ОПЦИИ] [-- АРГУМЕНТЫ_PI]  то же самое
  pibox shell [ОПЦИИ]                    bash внутри контейнера
  pibox exec [ОПЦИИ] КОМАНДА [АРГ...]    выполнить команду внутри контейнера
  pibox build [ОПЦИИ_СБОРКИ]             собрать Docker-образ
  pibox env  ПОДКОМАНДА ...              управление окружениями
  pibox ps                               список контейнеров pibox
  pibox doctor                           диагностика
  pibox help | version

Опции запуска (run/shell/exec):
  -e, --env ИМЯ           окружение (по умолчанию: \${PIBOX_ENV:-default})
  -p, --port ПОРТ          проброс порта: "3000" => 3000:3000;
                          "127.0.0.1:3000:8080" передаётся как есть (можно несколько)
  -n, --name ИМЯ           имя контейнера
  -C, --cd ПУТЬ            использовать ПУТЬ как workspace (вместо текущего каталога)
  -E, --env-var КЛЮЧ[=ЗН]  передать переменную окружения в контейнер
                          (без =ЗН значение берётся из окружения хоста)
      --cpus N             лимит CPU (по умолчанию: 2; 0 — без лимита)
      --mem РАЗМЕР         лимит памяти (по умолчанию: 4g; 0 — без лимита)
      --pids N             лимит процессов (по умолчанию: 1024; unlimited — без лимита)
      --git-safe           включить git safe.directory внутри контейнера
      --no-git-safe        выключить (по умолчанию выключен)
      --offline            запустить контейнер без сети (--network none)
      --image ТЕГ          образ (по умолчанию: \${PIBOX_IMAGE:-pibox:latest})
      --no-build           не собирать образ автоматически
      --dry-run            напечатать команду docker и выйти

Опции сборки (build):
      --no-cache           пересобрать без кэша
      --pull               обновить базовый образ (docker build --pull)
      --build-arg К=З      передать build-arg (например --build-arg UBUNTU_VERSION=24.04)

Подкоманды env:
  list | create ИМЯ [--from ИМЯ|template] | remove ИМЯ [--yes]
  reset ИМЯ [--yes] | path [ИМЯ] | pkg list|add|rm|clear ИМЯ [ПАКЕТЫ...]

Переменные окружения:
  PIBOX_DIR      каталог установки (по умолчанию определяется автоматически)
  PIBOX_IMAGE    имя образа (pibox:latest)
  PIBOX_ENV      окружение по умолчанию (default)
  PIBOX_CPUS, PIBOX_MEMORY, PIBOX_PIDS, PIBOX_GIT_SAFE — значения по умолчанию
  PIBOX_PASS_ENV дополнительные имена переменных для проброски в контейнер

Примеры:
  pibox                          # pi в текущем каталоге, окружение default
  pibox -e php8 -p 8080          # окружение php8, порт 8080 -> 8080
  pibox -- --resume              # аргументы после '--' передаются самому pi
  pibox exec git status          # выполнить команду в том же окружении
  pibox env create rust
  pibox env pkg add default gdb strace
  pibox doctor
EOF
}

# ----------------------------------------------------------------------------
# Разбор аргументов
# ----------------------------------------------------------------------------
CMD=''
POSITIONAL=()
ARGS_ONLY=0

while [ $# -gt 0 ]; do
    if [ "$ARGS_ONLY" -eq 1 ]; then
        POSITIONAL+=("$1"); shift; continue
    fi
    case "$1" in
        --)
            shift
            while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done
            break
            ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "pibox $VERSION"; exit 0 ;;
        -e|--env)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            OPT_ENV="$2"; shift 2 ;;
        -p|--port)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            PORTS+=("$2"); shift 2 ;;
        -E|--env-var)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*(=.*)?$ ]] \
                || die "некорректное значение для --env-var: '$2'"
            PASS_ENV_VARS+=("$2"); shift 2 ;;
        -n|--name)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            OPT_NAME="$2"; shift 2 ;;
        -C|--cd)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            OPT_CDIR="$2"; shift 2 ;;
        --cpus)
            [ $# -ge 2 ] || die "опция '$1' требует значение"; OPT_CPUS="$2"; shift 2 ;;
        --mem|--memory)
            [ $# -ge 2 ] || die "опция '$1' требует значение"; OPT_MEM="$2"; shift 2 ;;
        --pids)
            [ $# -ge 2 ] || die "опция '$1' требует значение"; OPT_PIDS="$2"; shift 2 ;;
        --git-safe)     OPT_GIT_SAFE=1; shift ;;
        --no-git-safe)  OPT_GIT_SAFE=0; shift ;;
        --offline|--no-network) OPT_OFFLINE=1; shift ;;
        --dry-run)      OPT_DRY_RUN=1; shift ;;
        --no-build)     OPT_NO_BUILD=1; shift ;;
        --image)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            OPT_IMAGE="$2"; shift 2 ;;
        --no-cache) OPT_NO_CACHE=1; shift ;;
        --pull)     OPT_PULL=1; shift ;;
        --build-arg)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            [[ "$2" == *=* ]] || die "--build-arg ожидает КЛЮЧ=ЗНАЧЕНИЕ"
            BUILD_ARGS+=("--build-arg=$2"); shift 2 ;;
        -*)
            die "неизвестная опция: $1 (аргументы для pi передавайте после '--'; см. pibox --help)" ;;
        *)
            if [ -z "$CMD" ]; then
                case "$1" in
                    run|shell|sh|exec|build|env|ps|doctor|help|version) CMD="$1" ;;
                    *) die "неизвестная команда: $1 (см. pibox --help)" ;;
                esac
            else
                POSITIONAL+=("$1"); ARGS_ONLY=1
            fi
            shift ;;
    esac
done

# ----------------------------------------------------------------------------
# Команды
# ----------------------------------------------------------------------------

# Общая сборка docker run для run/shell/exec
run_container() {
    local -a cmd=("$@")

    require_pibox_dir
    require_docker

    local env_name="${OPT_ENV:-$DEFAULT_ENV}"
    ensure_env "$env_name"
    local env_dir
    env_dir="$(rp "$PIBOX_DIR/env/$env_name")" \
        || die "не удалось определить путь окружения: $PIBOX_DIR/env/$env_name"

    local ws="${OPT_CDIR:-$PWD}"
    [ -d "$ws" ] || die "рабочая директория не существует или не каталог: $ws"
    ws="$(rp "$ws")" || die "не удалось определить путь: $ws"
    check_workspace "$ws"

    # docker не понимает ':' в путях bind-mount'ов
    case "$ws$env_dir" in
        *:*) die "пути workspace/PIBOX_DIR не должны содержать символ ':'" ;;
    esac

    if [ "$OPT_OFFLINE" = "1" ] && [ "${#PORTS[@]}" -gt 0 ]; then
        die "проброс портов (-p) несовместим с --offline"
    fi

    ensure_image

    local -a d=(run --rm --hostname pibox --security-opt no-new-privileges)
    d+=(--label pibox=true --label "pibox.env=$env_name")

    if [ -t 0 ] && [ -t 1 ]; then d+=(-it); else d+=(-i); fi
    if [ -n "$OPT_NAME" ]; then d+=(--name "$OPT_NAME"); fi

    d+=(-v "$env_dir:/home/pi" -v "$ws:/home/pi/workspace" -w /home/pi/workspace)

    d+=(
        -e "PIBOX_UID=$(id -u)"
        -e "PIBOX_GID=$(id -g)"
        -e "PIBOX_GIT_SAFE=$OPT_GIT_SAFE"
        -e "PIBOX_ENV_NAME=$env_name"
    )
    if [ -n "${TZ:-}" ]; then d+=(-e "TZ=$TZ"); fi

    # Проброска ключей API и прокси
    local k v
    for k in "${PASS_KEYS[@]}" ${PIBOX_PASS_ENV:-}; do
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [ -n "${!k:-}" ]; then d+=(-e "$k=${!k}"); fi
    done
    for v in ${PASS_ENV_VARS[@]+"${PASS_ENV_VARS[@]}"}; do
        case "$v" in
            *=*) d+=(-e "$v") ;;
            *)
                if [ -n "${!v:-}" ]; then
                    d+=(-e "$v=${!v}")
                else
                    die "переменная '$v' не задана в окружении хоста"
                fi ;;
        esac
    done

    # Сеть
    if [ "$OPT_OFFLINE" = "1" ]; then
        d+=(--network none)
        warn "сеть отключена (--offline): интернет и Model API будут недоступны"
    else
        if docker_supports_host_gateway; then
            d+=(--add-host host.docker.internal:host-gateway)
        else
            warn "Docker < 20.10: host.docker.internal работать не будет (обновите Docker)"
        fi
        d+=(--cap-add SYS_PTRACE --cap-add NET_RAW)
    fi

    # Ограничения ресурсов
    if [ -n "$OPT_CPUS" ] && [ "$OPT_CPUS" != "0" ]; then d+=(--cpus "$OPT_CPUS"); fi
    if [ -n "$OPT_MEM" ] && [ "$OPT_MEM" != "0" ]; then d+=(--memory "$OPT_MEM"); fi
    case "$OPT_PIDS" in
        ''|0|unlimited|none) ;;
        *) d+=(--pids-limit "$OPT_PIDS") ;;
    esac

    # Порты
    local p
    for p in ${PORTS[@]+"${PORTS[@]}"}; do
        case "$p" in
            *:*) d+=(-p "$p") ;;
            *)   d+=(-p "$p:$p") ;;
        esac
    done

    d+=("$OPT_IMAGE" ${cmd[@]+"${cmd[@]}"})

    if [ "$OPT_DRY_RUN" = "1" ]; then
        printf 'docker'
        printf ' %q' ${d[@]+"${d[@]}"}
        printf '\n'
        return 0
    fi

    exec docker ${d[@]+"${d[@]}"}
}

cmd_run()   { run_container pi ${POSITIONAL[@]+"${POSITIONAL[@]}"}; }
cmd_shell() { run_container bash -l; }
cmd_exec() {
    [ "${#POSITIONAL[@]}" -gt 0 ] \
        || die "pibox exec требует команду (например: pibox exec git status)"
    run_container ${POSITIONAL[@]+"${POSITIONAL[@]}"}
}

cmd_build() {
    require_docker
    local ctx dockerfile
    if [ -f "$PIBOX_DIR/docker/Dockerfile" ] && [ -f "$PIBOX_DIR/docker/entrypoint.sh" ]; then
        ctx="$PIBOX_DIR/docker"
    elif [ -f "$PIBOX_DIR/Dockerfile" ] && [ -f "$PIBOX_DIR/entrypoint.sh" ]; then
        ctx="$PIBOX_DIR"
    else
        die "Dockerfile/entrypoint.sh не найдены в $PIBOX_DIR — переустановите pibox"
    fi
    dockerfile="$ctx/Dockerfile"

    local -a args=(build)
    if [ "$OPT_NO_CACHE" = "1" ]; then args+=(--no-cache); fi
    if [ "$OPT_PULL" = "1" ]; then args+=(--pull); fi
    args+=(-t "$OPT_IMAGE")
    args+=(${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"})
    args+=(-f "$dockerfile" "$ctx")

    info "Собираю образ $OPT_IMAGE (контекст: $ctx)"
    docker ${args[@]+"${args[@]}"} || die "сборка образа не удалась"
    info "Образ собран: $OPT_IMAGE"
}

# ----------------------------------------------------------------------------
# Управление окружениями
# ----------------------------------------------------------------------------
cmd_env() {
    require_pibox_dir
    local sub="${1:-list}"
    if [ $# -gt 0 ]; then shift; fi
    case "$sub" in
        list|ls)           env_list ;;
        create|new)        env_create "$@" ;;
        remove|rm|delete)  env_remove "$@" ;;
        reset)             env_reset "$@" ;;
        path)              env_path "$@" ;;
        pkg|packages)      env_pkg "$@" ;;
        *) die "неизвестная подкоманда env: '$sub' (list|create|remove|reset|path|pkg)" ;;
    esac
}

env_list() {
    local env_root="$PIBOX_DIR/env" d name sz marker found=0
    printf 'Окружения (%s):\n' "$env_root"
    for d in "$env_root"/*/; do
        if [ -d "$d" ]; then
            found=1
            name="$(basename "$d")"
            sz="$(du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
            marker=''
            if [ "$name" = "${OPT_ENV:-$DEFAULT_ENV}" ]; then
                marker="  ${C_DIM}<= по умолчанию${C_OFF}"
            fi
            printf '  %-24s %s%s\n' "$name" "$sz" "$marker"
        fi
    done
    if [ "$found" = "0" ]; then
        printf '  (пока нет — окружение создастся при первом запуске pibox)\n'
    fi
}

env_create() {
    local name='' from='template'
    while [ $# -gt 0 ]; do
        case "$1" in
            --from)
                [ $# -ge 2 ] || die "--from требует значение (имя окружения или 'template')"
                from="$2"; shift 2 ;;
            *)  if [ -z "$name" ]; then name="$1"; shift
                else die "лишний аргумент: $1"; fi ;;
        esac
    done
    [ -n "$name" ] || die "использование: pibox env create ИМЯ [--from ИМЯ|template]"
    valid_env_name "$name" || die "недопустимое имя окружения: '$name'"

    local dest="$PIBOX_DIR/env/$name"
    if [ -e "$dest" ]; then die "окружение '$name' уже существует: $dest"; fi

    local src
    if [ "$from" = "template" ]; then
        src="$PIBOX_DIR/env-template"
    else
        valid_env_name "$from" || die "недопустимое имя окружения: '$from'"
        src="$PIBOX_DIR/env/$from"
        [ -d "$src" ] || die "исходное окружение '$from' не найдено"
    fi
    cp -a "$src" "$dest" || die "не удалось скопировать $src -> $dest"
    copy_models_into_env "$dest"
    info "Создано окружение '$name': $dest"
    info "Запуск: pibox -e $name"
}

confirm() {
    local question="$1" answer
    if [ -t 0 ]; then
        read -r -p "$question " answer || true
        case "${answer:-}" in
            y|Y|yes|YES|да|Да) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

# Проверенный безопасный путь окружения (защита от symlink-трюков)
env_dir_checked() {
    local name="$1"
    valid_env_name "$name" || die "недопустимое имя окружения: '$name'"
    local dir="$PIBOX_DIR/env/$name"
    [ -d "$dir" ] || die "окружение '$name' не найдено ($dir)"
    local real root_real
    real="$(rp "$dir")" || die "не удалось разрешить путь $dir"
    root_real="$(rp "$PIBOX_DIR/env")" || die "не удалось разрешить путь $PIBOX_DIR/env"
    if [ "$(dirname "$real")" != "$root_real" ]; then
        die "безопасность: '$real' не является окружением непосредственно внутри $root_real"
    fi
    printf '%s\n' "$dir"
}

env_remove() {
    local name='' force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes|--force) force=1; shift ;;
            *)  if [ -z "$name" ]; then name="$1"; shift
                else die "лишний аргумент: $1"; fi ;;
        esac
    done
    [ -n "$name" ] || die "использование: pibox env remove ИМЯ [--yes]"
    local dir
    dir="$(env_dir_checked "$name")"
    if [ "$force" = "0" ]; then
        confirm "Удалить окружение '$name' ($dir)? [y/N]" || die "отменено"
    fi
    rm -rf -- "$dir"
    info "Окружение '$name' удалено"
}

env_reset() {
    local name='' force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes|--force) force=1; shift ;;
            *)  if [ -z "$name" ]; then name="$1"; shift
                else die "лишний аргумент: $1"; fi ;;
        esac
    done
    [ -n "$name" ] || die "использование: pibox env reset ИМЯ [--yes]"
    local dir
    dir="$(env_dir_checked "$name")"
    if [ "$force" = "0" ]; then
        confirm "Пересоздать '$name' из шаблона? Удалятся ВСЕ данные (сессии, тулчейны, ключи)! [y/N]" \
            || die "отменено"
    fi
    rm -rf -- "$dir"
    cp -a "$PIBOX_DIR/env-template" "$dir" || die "не удалось скопировать шаблон"
    copy_models_into_env "$dir"
    info "Окружение '$name' пересоздано из шаблона"
}

env_path() {
    if [ $# -eq 0 ]; then
        printf '%s\n' "$PIBOX_DIR/env"
        return 0
    fi
    local name="$1"
    if [ "$name" = "template" ]; then
        printf '%s\n' "$PIBOX_DIR/env-template"
        return 0
    fi
    valid_env_name "$name" || die "недопустимое имя окружения: '$name'"
    printf '%s\n' "$PIBOX_DIR/env/$name"
}

# apt-пакеты окружения: ставятся entrypoint'ом при старте контейнера
env_pkg() {
    local action="${1:-}"
    [ -n "$action" ] || die "использование: pibox env pkg list|add|rm|clear ИМЯ [ПАКЕТЫ...]"
    shift
    local env_name="${1:-}"
    [ -n "$env_name" ] || die "укажите имя окружения (pibox env pkg $action ИМЯ ...)"
    shift

    local dir="$PIBOX_DIR/env/$env_name"
    [ -d "$dir" ] || die "окружение '$env_name' не найдено (создайте: pibox env create $env_name)"
    local f="$dir/.pibox/apt-packages.txt"
    local p

    case "$action" in
        list|ls)
            if [ ! -f "$f" ] || ! grep -qE '^[[:space:]]*[^#[:space:]]' "$f"; then
                info "пакеты не заданы"
            else
                grep -vE '^\s*(#|$)' "$f"
            fi
            ;;
        add)
            [ $# -ge 1 ] || die "укажите пакеты: pibox env pkg add $env_name ПАКЕТ..."
            for p in "$@"; do
                [[ "$p" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+-]*$ ]] || die "недопустимое имя пакета: '$p'"
            done
            mkdir -p "$dir/.pibox"
            touch "$f"
            for p in "$@"; do
                if ! grep -qxF -- "$p" "$f"; then
                    printf '%s\n' "$p" >> "$f"
                fi
            done
            info "Пакеты добавлены; установятся при следующем запуске: pibox -e $env_name"
            ;;
        rm|remove)
            [ -f "$f" ] || die "пакеты не заданы"
            [ $# -ge 1 ] || die "укажите пакеты"
            local -a pats=()
            for p in "$@"; do
                [[ "$p" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+-]*$ ]] || die "недопустимое имя пакета: '$p'"
                pats+=(-e "$p")
            done
            grep -vxF ${pats[@]+"${pats[@]}"} "$f" > "$f.tmp" || true
            mv "$f.tmp" "$f"
            info "готово"
            ;;
        clear)
            mkdir -p "$dir/.pibox"
            : > "$f"
            rm -rf "$dir/.pibox/apt-cache"
            info "список пакетов и apt-кэш очищены"
            ;;
        *)
            die "неизвестное действие pkg: '$action' (list|add|rm|clear)" ;;
    esac
}

cmd_ps() {
    require_docker
    docker ps -a --filter label=pibox=true \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "pibox.env"}}'
}

cmd_doctor() {
    local problems=0
    _ok()   { printf '  [ %sOK%s ]   %s\n' "$C_OK" "$C_OFF" "$*"; }
    _bad()  { printf '  [ %sFAIL%s ]  %s\n' "$C_ERR" "$C_OFF" "$*"; problems=$((problems + 1)); }
    _warn() { printf '  [ %sWARN%s ]  %s\n' "$C_WARN" "$C_OFF" "$*"; }

    printf 'pibox %s — диагностика\n' "$VERSION"
    printf '  PIBOX_DIR: %s\n' "$PIBOX_DIR"

    if command -v docker >/dev/null 2>&1; then
        _ok "docker: $(docker --version 2>/dev/null || echo 'версия неизвестна')"
        if docker info >/dev/null 2>&1; then
            _ok "docker-демон запущен"
            if docker_supports_host_gateway; then
                _ok "Docker >= 20.10 (host-gateway поддерживается)"
            else
                _warn "Docker < 20.10: host.docker.internal работать не будет"
            fi
            if docker image inspect "$OPT_IMAGE" >/dev/null 2>&1; then
                _ok "образ $OPT_IMAGE собран"
                if docker run --rm --entrypoint /bin/sh "$OPT_IMAGE" -c 'command -v pi >/dev/null' >/dev/null 2>&1; then
                    _ok "pi доступен в образе"
                else
                    _bad "в образе нет pi — пересоберите: pibox build"
                fi
            else
                _warn "образ $OPT_IMAGE не собран (pibox build)"
            fi
        else
            _bad "docker-демон не отвечает (Docker запущен? права на docker.sock?)"
        fi
    else
        _bad "docker не установлен: https://docs.docker.com/engine/install/"
    fi

    if [ -d "$PIBOX_DIR" ]; then _ok "PIBOX_DIR существует"; else _bad "PIBOX_DIR не существует: $PIBOX_DIR"; fi
    if [ -d "$PIBOX_DIR/env-template" ]; then _ok "env-template на месте"; else _bad "нет $PIBOX_DIR/env-template — переустановите pibox"; fi
    if [ -d "$PIBOX_DIR/env" ]; then _ok "env/ на месте"; else _bad "нет $PIBOX_DIR/env — переустановите pibox"; fi
    if [ -d "$PIBOX_DIR/env/default" ]; then _ok "окружение default существует"; else _warn "окружение default создастся при первом запуске"; fi
    if [ -f "$PIBOX_DIR/env/models.json" ]; then _ok "env/models.json на месте"; else _warn "нет env/models.json — модели настраиваются вручную"; fi
    if [ "$(id -u)" -eq 0 ]; then _warn "запуск от root: файлы в workspace будут принадлежать root"; fi
    printf '  [ ---- ]  свободно на PIBOX_DIR: %s\n' \
        "$(df -h "$PIBOX_DIR" 2>/dev/null | awk 'NR==2{print $4}')"

    if [ "$problems" -eq 0 ]; then
        info "проблем не обнаружено"
    else
        die "обнаружено проблем: $problems"
    fi
}

# ----------------------------------------------------------------------------
# Диспетчер
# ----------------------------------------------------------------------------
case "${CMD:-run}" in
    run)       cmd_run ;;
    shell|sh)  cmd_shell ;;
    exec)      cmd_exec ;;
    build)     cmd_build ;;
    env)       cmd_env ${POSITIONAL[@]+"${POSITIONAL[@]}"} ;;
    ps)        cmd_ps ;;
    doctor)    cmd_doctor ;;
    help)      usage ;;
    version)   echo "pibox $VERSION" ;;
    *)         die "неизвестная команда: $CMD" ;;
esac
```

---

## `entrypoint.sh` — инициализация контейнера

```bash
#!/usr/bin/env bash
# ============================================================================
#  entrypoint.sh — инициализация pibox-контейнера (запускается от root).
#
#  Последовательность:
#    1) подстройка UID/GID пользователя pi под пользователя хоста;
#    2) мердж dotfiles из /opt/skel в /home/pi (без перезаписи существующих);
#    3) исправление владельцев файлов в /home/pi (кроме workspace);
#    4) установка apt-пакетов окружения (~/.pibox/apt-packages.txt);
#    5) git safe.directory (опция PIBOX_GIT_SAFE=1);
#    6) передача управления: gosu pi:pi tini -- <CMD>.
# ============================================================================
set -euo pipefail

PIBOX_HOME="${PIBOX_HOME:-/home/pi}"
PIBOX_UID="${PIBOX_UID:-1000}"
PIBOX_GID="${PIBOX_GID:-1000}"
PIBOX_GIT_SAFE="${PIBOX_GIT_SAFE:-0}"

log()  { echo "[pibox] $*"; }
warn() { echo "[pibox] предупреждение: $*" >&2; }
fail() { echo "[pibox] ошибка: $*" >&2; exit 1; }

getent_name() { # $1: passwd|group; $2: численный id -> имя или пусто
    local out
    out="$(getent "$1" "$2" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | head -n 1 | cut -d: -f1
    fi
    return 0
}

# --- 1. Подстройка UID/GID ---------------------------------------------------
run_as_root=0

if [ "$(id -u)" -eq 0 ]; then
    if [ "$PIBOX_UID" = "0" ]; then
        log "хост-пользователь — root: запускаю агента от root"
        run_as_root=1
    else
        id pi >/dev/null 2>&1 || fail "пользователь pi не найден в образе"
        cur_uid="$(id -u pi)"
        cur_gid="$(id -g pi)"

        if [ "$PIBOX_UID" != "$cur_uid" ]; then
            owner="$(getent_name passwd "$PIBOX_UID")"
            if [ -n "$owner" ] && [ "$owner" != "pi" ]; then
                fail "UID $PIBOX_UID уже занят пользователем '$owner' — не могу настроить pi"
            fi
        fi
        if [ "$PIBOX_GID" != "$cur_gid" ]; then
            gowner="$(getent_name group "$PIBOX_GID")"
            if [ -n "$gowner" ] && [ "$gowner" != "pi" ]; then
                fail "GID $PIBOX_GID уже занят группой '$gowner' — не могу настроить pi"
            fi
        fi

        if [ "$PIBOX_GID" != "$cur_gid" ]; then
            groupmod -g "$PIBOX_GID" pi || fail "groupmod -g $PIBOX_GID pi не удался"
        fi
        if [ "$PIBOX_UID" != "$cur_uid" ] || [ "$PIBOX_GID" != "$cur_gid" ]; then
            # -g pi: заново прописать primary group (groupmod правит только /etc/group)
            usermod -u "$PIBOX_UID" -g pi pi || fail "usermod для pi не удался"
        fi
        log "пользователь pi: uid=$PIBOX_UID gid=$PIBOX_GID"
    fi
else
    PIBOX_UID="$(id -u)"
    PIBOX_GID="$(id -g)"
    log "контейнер запущен без root (uid=$PIBOX_UID): подстройка UID/GID пропущена"
fi

# --- 2. Мердж /opt/skel -> /home/pi -----------------------------------------
force_chown=0
if [ -d /opt/skel ]; then
    if [ "$(id -u)" -eq 0 ] && command -v rsync >/dev/null 2>&1; then
        # --ignore-existing: не затираем пользовательские конфиги окружения
        rsync -a --ignore-existing --chown="$PIBOX_UID:$PIBOX_GID" \
            /opt/skel/ "$PIBOX_HOME"/ \
            || warn "не удалось скопировать файлы из /opt/skel"
    else
        # запасной вариант (спецификация: cp -rn)
        cp -rn /opt/skel/. "$PIBOX_HOME"/ 2>/dev/null || true
        force_chown=1
    fi
fi

# --- 3. Владельцы файлов home (кроме workspace) -----------------------------
# Быстрый путь: маркер ~/.pibox/owner — если uid/gid не менялись, обход пропускаем.
if [ "$(id -u)" -eq 0 ] && [ "$run_as_root" -eq 0 ]; then
    marker="$PIBOX_HOME/.pibox/owner"
    marker_ok=0
    if [ "$force_chown" -eq 0 ] && [ -f "$marker" ]; then
        if [ "$(cat "$marker" 2>/dev/null || true)" = "$PIBOX_UID:$PIBOX_GID" ]; then
            marker_ok=1
        fi
    fi
    if [ "$marker_ok" -eq 0 ]; then
        find "$PIBOX_HOME" -path "$PIBOX_HOME/workspace" -prune -o \
            \( ! -user "$PIBOX_UID" -o ! -group "$PIBOX_GID" \) -print0 \
            | xargs -0 -r chown -h "$PIBOX_UID:$PIBOX_GID" \
            || warn "не удалось исправить владельцев в $PIBOX_HOME"
        mkdir -p "$PIBOX_HOME/.pibox" || true
        printf '%s:%s\n' "$PIBOX_UID" "$PIBOX_GID" > "$marker" 2>/dev/null \
            || warn "не удалось записать $marker"
        chown "$PIBOX_UID:$PIBOX_GID" "$marker" 2>/dev/null || true
    fi
elif [ "$(id -u)" -eq 0 ]; then
    # запуск от root: сбросим маркер, чтобы следующий запуск всё перепроверил
    rm -f "$PIBOX_HOME/.pibox/owner" 2>/dev/null || true
fi

# --- 4. apt-пакеты окружения (~/.pibox/apt-packages.txt) --------------------
# Пакеты устанавливаются в контейнер при каждом старте (контейнер эфемерный),
# но скачанные .deb кэшируются в env, поэтому повторные запуски быстрые.
install_env_apt() {
    local pkg_file="$PIBOX_HOME/.pibox/apt-packages.txt"
    [ -f "$pkg_file" ] || return 0
    [ "$(id -u)" -eq 0 ] || { warn "apt-пакеты окружения требуют root — пропускаю"; return 0; }

    local -a want=() missing=()
    local line p
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [ -n "$line" ]; then want+=("$line"); fi
    done < "$pkg_file"
    [ "${#want[@]}" -gt 0 ] || return 0

    for p in "${want[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
            missing+=("$p")
        fi
    done
    [ "${#missing[@]}" -gt 0 ] || return 0

    log "устанавливаю пакеты окружения: ${missing[*]}"
    local cache="$PIBOX_HOME/.pibox/apt-cache"
    mkdir -p "$cache/archives/partial" || true
    if ! apt-get update -qq; then
        warn "apt-get update не удался (нет сети?) — пакеты не установлены"
        return 0
    fi
    if ! apt-get install -y --no-install-recommends \
            -o Dir::Cache::archives="$cache/archives" "${missing[@]}"; then
        warn "не удалось установить: ${missing[*]}"
        return 0
    fi
    chown -R "$PIBOX_UID:$PIBOX_GID" "$PIBOX_HOME/.pibox" 2>/dev/null || true
    log "пакеты окружения установлены (кэш: ~/.pibox/apt-cache)"
}
install_env_apt

# --- 5. git safe.directory --------------------------------------------------
if [ "$PIBOX_GIT_SAFE" = "1" ] && command -v git >/dev/null 2>&1; then
    # '*' — доверяем всем репозиториям внутри контейнера (в т.ч. вложенным в workspace)
    git config --system --add safe.directory '*' \
        || warn "не удалось настроить git safe.directory"
    log "git safe.directory включён"
fi

# --- 6. Окружение и запуск --------------------------------------------------
export HOME="$PIBOX_HOME"
if [ "$run_as_root" -eq 1 ]; then
    export USER=root LOGNAME=root
else
    export USER=pi LOGNAME=pi
fi
export SHELL=/bin/bash
export LANG="${LANG:-en_US.UTF-8}"
export PATH="$PIBOX_HOME/.local/bin:$PIBOX_HOME/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

cd "$PIBOX_HOME/workspace" 2>/dev/null || cd "$PIBOX_HOME"

if [ $# -eq 0 ]; then
    set -- pi
fi

if [ "$run_as_root" -eq 1 ] || [ "$(id -u)" -ne 0 ]; then
    exec /usr/bin/tini -- "$@"
fi
exec /usr/bin/gosu pi:pi /usr/bin/tini -- "$@"
```

---

## `Dockerfile` — multi-stage сборка образа

```dockerfile
# syntax=docker/dockerfile:1
# ============================================================================
#  pibox — образ для безопасного запуска Pi Coding Agent (https://pi.dev/)
#
#  Сборка:  pibox build   (или: docker build -t pibox:latest docker/)
#
#  Основные build-аргументы:
#    UBUNTU_VERSION  базовый образ Ubuntu       (по умолчанию 24.04)
#    NODE_VERSION    Node.js в /usr/local       (по умолчанию 22.14.0)
#    MISE_VERSION    версия mise                (пусто = последний релиз)
#    PI_PACKAGE      npm-пакет Pi Coding Agent  (по умолчанию @mariozechner/pi)
# ============================================================================

ARG UBUNTU_VERSION=24.04

# ----------------------------------------------------------------------------
# Стадия 1 (tools): скачиваем Node.js, mise и сам Pi.
# Мусор (tarball'ы, кэш npm) остаётся здесь и не попадает в финальный образ.
# ----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS tools

ARG TARGETARCH
ARG NODE_VERSION=22.14.0
ARG MISE_VERSION=
ARG PI_PACKAGE=@mariozechner/pi

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Node.js (официальный tarball в /usr/local) + mise (версионер тулчейнов)
RUN set -eux; \
    if [ -z "${TARGETARCH:-}" ]; then TARGETARCH="$(dpkg --print-architecture)"; fi; \
    case "$TARGETARCH" in \
        amd64) NODE_ARCH=x64;  MISE_ARCH=x64  ;; \
        arm64) NODE_ARCH=arm64; MISE_ARCH=arm64 ;; \
        *) echo "неподдерживаемая архитектура: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    node --version; \
    if [ -z "${MISE_VERSION:-}" ]; then \
        MISE_VERSION="$(curl -fsSL https://api.github.com/repos/jdx/mise/releases/latest \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"; \
    fi; \
    [ -n "${MISE_VERSION:-}" ] || { echo "не удалось определить версию mise" >&2; exit 1; }; \
    curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${MISE_ARCH}.tar.gz" \
        -o /tmp/mise.tar.gz; \
    tar -xzf /tmp/mise.tar.gz -C /tmp; \
    MISE_BIN="$(find /tmp/mise -type f -name mise | head -n 1)"; \
    [ -n "$MISE_BIN" ] || { echo "бинарник mise не найден в tarball" >&2; exit 1; }; \
    install -m 0755 "$MISE_BIN" /usr/local/bin/mise; \
    mise --version

# Pi Coding Agent (глобальный npm-пакет; версия задаётся как @mariozechner/pi@1.2.3)
RUN set -eux; \
    npm install -g --omit=dev "${PI_PACKAGE}"; \
    command -v pi; \
    pi --version || true; \
    rm -rf /root/.npm /tmp/node.tar.xz /tmp/mise.tar.gz

# ----------------------------------------------------------------------------
# Стадия 2 (final): финальный образ
# ----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="pibox" \
      org.opencontainers.image.description="Изолированное окружение для Pi Coding Agent (pi.dev)" \
      org.opencontainers.image.version="0.1.0"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    EDITOR=vim \
    PAGER=less

# --- Пакеты базового набора (спецификация, раздел 5.2) -----------------------
# Примечания:
#   * cat / find / xargs входят в coreutils/findutils базового образа
#     (отдельных apt-пакетов не существует);
#   * nodejs/npm из apt остаются в /usr/bin как запасные, рабочая версия
#     Node из /usr/local (см. стадию tools);
#   * тяжёлые тулчейны (cmake, golang, rust, gdb, ...) НЕ включаются:
#     языки ставятся локально через mise, системные пакеты — через
#     ~/.pibox/apt-packages.txt (см. README).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates locales tzdata lsb-release gosu tini \
        less grep sed gawk diffutils file xxd procps psmisc tmux \
        curl wget openssl iproute2 iputils-ping openssh-client dnsutils lsof \
        git tar gzip unzip rsync zip bzip2 xz-utils zstd lz4 \
        python3 python3-pip python3-venv \
        nodejs npm \
        jq ripgrep yq vim htop ncdu hexedit; \
    rm -rf /var/lib/apt/lists/*; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8

# pip в Ubuntu 24.04 требует PEP 668 — разрешаем установку в ~/.local пользователем pi
RUN printf '[install]\nbreak-system-packages = true\n' > /etc/pip.conf

# --- Node.js + mise + pi из стадии tools (/usr/local приоритетнее /usr) -----
COPY --from=tools /usr/local/ /usr/local/
RUN set -eux; \
    node --version; npm --version; mise --version; \
    command -v pi; command -v gosu; command -v tini

# --- Пользователь pi (UID/GID подстраивается в entrypoint.sh) ---------------
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd --gid 1000 pi; \
    useradd --uid 1000 --gid pi --create-home --shell /bin/bash pi

# --- Дополнительные dotfiles в /etc/skel ------------------------------------
RUN printf 'prefix=${HOME}/.local\nfund=false\naudit=false\nupdate-notifier=false\n' \
        > /etc/skel/.npmrc; \
    printf '"\\e[A": history-search-backward\n"\\e[B": history-search-forward\nset completion-ignore-case on\n' \
        > /etc/skel/.inputrc

# --- Эталонный home -> /opt/skel (мерджится в /home/pi при старте) -----------
RUN set -eux; \
    cp -a /home/pi /opt/skel; \
    ls -la /opt/skel

# --- entrypoint ---------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

WORKDIR /home/pi
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pi"]
```

---

## `install.sh` — установщик на хост

```bash
#!/usr/bin/env bash
# ============================================================================
#  install.sh — установка pibox на хост.
#
#  Использование: ./install.sh [--dir ~/pibox] [--no-path] [--yes] [--build]
#
#  Шаги:
#    1) создаёт PIBOX_DIR (по умолчанию ~/pibox);
#    2) копирует run.sh -> PIBOX_DIR/bin/pibox (единственная точка входа);
#    3) копирует Dockerfile и entrypoint.sh -> PIBOX_DIR/docker/;
#    4) копирует env-template -> PIBOX_DIR/env-template;
#    5) создаёт PIBOX_DIR/env/default из шаблона (если ещё нет);
#    6) кладёт PIBOX_DIR/env/models.json (если ещё нет);
#    7) опционально: PATH в ~/.bashrc и сборка образа.
#
#  Повторная установка безопасна: окружения env/*, models.json и данные
#  пользователя не перезаписываются (обновляется только env-template).
# ============================================================================
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

DEST="${PIBOX_DIR:-$HOME/pibox}"
DO_PATH=1
ASSUME_YES=0
DO_BUILD=0

if [ -t 2 ]; then
    C=$'\e[1;32m' CY=$'\e[1;33m' CE=$'\e[1;31m' CO=$'\e[0m'
else
    C='' CY='' CE='' CO=''
fi
info() { printf '%s[pibox-install]%s %s\n' "$C" "$CO" "$*"; }
warn() { printf '%s[pibox-install]%s %s\n' "$CY" "$CO" "$*" >&2; }
die()  { printf '%s[pibox-install]%s %s\n' "$CE" "$CO" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
install.sh — установка pibox

Опции:
  -d, --dir ПУТЬ   каталог установки (по умолчанию: ~/pibox или $PIBOX_DIR)
      --no-path    не изменять PATH
  -y, --yes        не задавать вопросов (все ответы — по умолчанию)
      --build      собрать Docker-образ сразу после установки
  -h, --help       эта справка
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)
            [ $# -ge 2 ] || die "опция '$1' требует значение"
            DEST="$2"; shift 2 ;;
        --no-path) DO_PATH=0; shift ;;
        -y|--yes)  ASSUME_YES=1; shift ;;
        --build)   DO_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

# --- Проверки исходников ------------------------------------------------------
for f in run.sh entrypoint.sh Dockerfile models.json; do
    [ -f "$SRC/$f" ] || die "$SRC/$f не найден — запускайте install.sh из корня репозитория pibox"
done
[ -d "$SRC/env-template" ] || die "$SRC/env-template не найден"

# --- Подготовка каталога ------------------------------------------------------
mkdir -p "$DEST" 2>/dev/null \
    || die "не удалось создать $DEST (права доступа? попробуйте другой --dir)"
DEST="$(cd "$DEST" && pwd -P)"
if [ "$DEST" = "$SRC" ]; then
    die "каталог установки совпадает с каталогом исходников — укажите другой --dir"
fi

info "Устанавливаю pibox в: $DEST"

mkdir -p "$DEST/bin" "$DEST/docker" "$DEST/env"

install -m 0755 "$SRC/run.sh"        "$DEST/bin/pibox"
install -m 0644 "$SRC/Dockerfile"    "$DEST/docker/Dockerfile"
install -m 0755 "$SRC/entrypoint.sh" "$DEST/docker/entrypoint.sh"

# env-template обновляем до версии репозитория (пользовательские env/* не трогаем)
if [ -d "$DEST/env-template" ]; then
    warn "обновляю $DEST/env-template (существующий шаблон заменяется; окружения env/* не затрагиваются)"
    rm -rf "$DEST/env-template"
fi
cp -a "$SRC/env-template" "$DEST/env-template"

# models.json — только если его ещё нет (не затираем пользовательский)
if [ ! -f "$DEST/env/models.json" ]; then
    cp "$SRC/models.json" "$DEST/env/models.json"
    info "env/models.json установлен — при необходимости отредактируйте под вашу модель"
else
    info "env/models.json уже существует — не трогаю"
fi

# окружение default — только если нет
if [ ! -d "$DEST/env/default" ]; then
    cp -a "$SRC/env-template" "$DEST/env/default"
    info "создано окружение по умолчанию: $DEST/env/default"
else
    info "окружение default уже существует — не трогаю"
fi

if [ -f "$SRC/README.md" ]; then
    cp "$SRC/README.md" "$DEST/README.md"
fi

# --- PATH ---------------------------------------------------------------------
if [ "$DO_PATH" = "1" ]; then
    case ":$PATH:" in
        *":$DEST/bin:"*)
            info "PATH уже содержит $DEST/bin"
            ;;
        *)
            add=0
            if [ "$ASSUME_YES" = "1" ]; then
                add=1
            elif [ -t 0 ]; then
                printf 'Добавить %s в PATH (~/.bashrc)? [Y/n]: ' "$DEST/bin"
                read -r answer || true
                case "${answer:-Y}" in
                    n|N|no|NO|н|Н|нет|Нет) add=0 ;;
                    *) add=1 ;;
                esac
            fi
            if [ "$add" = "1" ]; then
                if grep -qsF "$DEST/bin" "$HOME/.bashrc" 2>/dev/null; then
                    info "$DEST/bin уже прописан в ~/.bashrc — перезапустите оболочку"
                else
                    {
                        printf '\n# pibox (добавлено install.sh)\n'
                        printf 'export PATH="%s:$PATH"\n' "$DEST/bin"
                    } >> "$HOME/.bashrc"
                    info "PATH обновлён: перезапустите оболочку или выполните source ~/.bashrc"
                fi
            else
                info "PATH не изменён; запускайте так: $DEST/bin/pibox"
            fi
            ;;
    esac
fi

# --- Сборка образа ------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
    "$DEST/bin/pibox" build || die "сборка не удалась (повторите позже: pibox build)"
else
    if command -v docker >/dev/null 2>&1 \
        && docker image inspect "${PIBOX_IMAGE:-pibox:latest}" >/dev/null 2>&1; then
        :
    elif command -v docker >/dev/null 2>&1 && [ -t 0 ] && [ "$ASSUME_YES" = "0" ]; then
        printf 'Собрать Docker-образ сейчас (несколько минут)? [Y/n]: '
        read -r answer || true
        case "${answer:-Y}" in
            n|N|no|NO|н|Н|нет|Нет)
                info "Соберите образ позже: pibox build" ;;
            *)
                "$DEST/bin/pibox" build || warn "сборка не удалась — попробуйте позже: pibox build" ;;
        esac
    else
        info "Образ будет собран автоматически при первом запуске (или: pibox build)"
    fi
fi

cat <<EOF

Установка завершена.

  PIBOX_DIR:   $DEST
  Запуск:      pibox          (в любом каталоге с проектом)
  Справка:     pibox --help
  Диагностика: pibox doctor

Быстрый старт:
  cd ~/my-project && pibox

EOF
```

---

## `models.json` — шаблон конфигурации моделей

```json
{
  "_pibox_readme": [
    "Шаблон models.json для Pi Coding Agent (pibox).",
    "Копируется в env/<имя>/.pi/agent/models.json при первом запуске окружения,",
    "после чего не перезаписывается. Точную схему сверяйте с документацией pi.dev",
    "(раздел про кастомные модели/провайдеров).",
    "Локальный Model API на хосте из контейнера доступен как http://host.docker.internal:8080.",
    "Ключи API надёжнее передавать через переменные окружения: pibox пробрасывает",
    "ANTHROPIC_API_KEY, OPENAI_API_KEY, GROQ_API_KEY, OPENROUTER_API_KEY и др. (см. README)."
  ],
  "models": [
    {
      "id": "local-model",
      "name": "Local Model API (host)",
      "provider": "openai",
      "baseUrl": "http://host.docker.internal:8080/v1",
      "model": "change-me",
      "apiKey": "change-me"
    }
  ]
}
```

---

## `env-template/` — шаблон домашнего каталога

**`env-template/.bashrc`**

```bash
# ~/.bashrc — pibox: интерактивные оболочки bash внутри контейнера.

# Неинтерактивная оболочка — сразу выходим
case $- in *i*) ;; *) return 2>/dev/null || exit 0 ;; esac

# --- PATH: локальные утилиты + shims mise ---
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# --- mise: версионер тулчейнов (https://mise.jdx.dev) ---
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

# --- История ---
HISTSIZE=20000
HISTFILESIZE=40000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T '
shopt -s histappend checkwinsize

# --- Prompt (имя окружения pibox видно в скобках) ---
PS1='\[\e[1;32m\]\u@pibox\[\e[0m\]${PIBOX_ENV_NAME:+(\[\e[35m\]${PIBOX_ENV_NAME}\[\e[0m\])}:\[\e[1;34m\]\w\[\e[0m\]\$ '

# --- Алиасы ---
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias grep='grep --color=auto'
alias gs='git status -sb'
alias gl='git log --oneline --graph --decorate -n 20'
alias serve='python3 -m http.server 8000'
alias ..='cd ..'
alias ...='cd ../..'

# --- Окружение ---
export EDITOR="${EDITOR:-vim}"
export PAGER="${PAGER:-less}"
```

**`env-template/.profile`**

```bash
# ~/.profile — pibox: login-оболочки.

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export EDITOR="${EDITOR:-vim}"

if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

**`env-template/.inputrc`**

```
$include /etc/inputrc

# Навигация по истории по введённому префиксу (стрелки вверх/вниз)
"\e[A": history-search-backward
"\e[B": history-search-forward

set completion-ignore-case on
set show-all-if-ambiguous on
```

**`env-template/.gitconfig`**

```ini
# Глобальная конфигурация git для pibox.
# Задайте свои данные (нужно для коммитов):
#   git config --global user.name  "Имя Фамилия"
#   git config --global user.email "you@example.com"

[init]
    defaultBranch = main

[push]
    autoSetupRemote = true

[alias]
    st = status -sb
    lg = log --oneline --graph --decorate -n 20
    last = log -1 HEAD --stat
```

**`env-template/.npmrc`**

```ini
# Глобальные установки npm кладём в ~/.local — они сохраняются в окружении pibox
prefix=${HOME}/.local
fund=false
audit=false
update-notifier=false
```

**`env-template/.tmux.conf`**

```bash
# ~/.tmux.conf — pibox
set -g default-terminal "screen-256color"
set -g history-limit 10000
set -g mouse on
setw -g mode-keys vi
```

**`env-template/.pi/agent/AGENTS.md`** — глобальные инструкции агенту

```markdown
# pibox: глобальные инструкции агента

Ты (Pi Coding Agent) работаешь внутри Docker-контейнера pibox. Важно:

## Окружение
- `/home/pi` — персистентный домашний каталог (сохраняется между запусками pibox).
- `/home/pi/workspace` — текущий проект; изменения сразу видны на хосте.
- Всё вне `/home/pi` эфемерно и исчезает при остановке контейнера.

## Установка инструментов
- Языки и тулчейны ставь через mise (установлен): `mise use -g node@22`,
  `mise install python@3.12` и т.п. Установленное сохраняется в окружении.
- `sudo` нет и не нужен; напрямую системные apt-пакеты ставить нельзя.
- Если нужен системный пакет (gdb, strace, tcpdump, valgrind, sysstat, iotop...):
  добавь его имя в `~/.pibox/apt-packages.txt` (по одному в строке) и сообщи
  пользователю, что пакет установится при следующем запуске pibox
  (на хосте: `pibox env pkg add <имя_окружения> <пакет>`).

## Работа
- Dev-серверы запускай в tmux (установлен), чтобы они не умирали между командами.
- Порты наружу пробрасываются флагом `-p` при запуске pibox на хосте.
- Локальная модель / Model API хоста: `http://host.docker.internal:8080`.
- Не пытайся изменить конфигурацию Docker или выйти за пределы контейнера.
```

**`env-template/.pi/agent/skills/pibox-toolchains/SKILL.md`**

```markdown
---
name: pibox-toolchains
description: Установка языков, тулчейнов и системных пакетов в контейнере pibox (mise, apt-packages.txt), проброс портов и tmux
---

# Установка инструментов в pibox

## Языки и тулчейны — через mise (персистентно, в ~/.local)
```bash
mise use -g node@22          # установить и сделать версией по умолчанию
mise use -g python@3.12
mise install rust@1.79       # только скачать
mise ls                      # что установлено
```
После `mise use` бинарь доступны через shims (~/.local/share/mise/shims уже в PATH).
Поддерживаются node, python, go, rust, java, cmake, ruby, php и др.

## Системные apt-пакеты (gdb, strace, tcpdump, valgrind...)
Их нельзя поставить через mise и нельзя ставить из-под пользователя. Добавь их
в `~/.pibox/apt-packages.txt` (по одному в строке, `#` — комментарии):
```bash
echo gdb >> ~/.pibox/apt-packages.txt
echo strace >> ~/.pibox/apt-packages.txt
```
и попроси пользователя перезапустить pibox — entrypoint установит их при старте
(скачанные пакеты кэшируются в `~/.pibox/apt-cache`, повторные запуски быстрые).

## Dev-серверы
Запускай в tmux: `tmux new -d -s dev 'npm run dev'`, смотри `tmux attach -t dev`.
Порты наружу пробрасываются при запуске pibox на хосте: `pibox -p 3000`.

## Локальная модель на хосте
Базовый URL: `http://host.docker.internal:8080`.
```

**`env-template/.pi/agent/skills/README.md`**

```markdown
# Скиллы Pi

Каталог пользовательских скиллов: каждый скилл — поддиректория с файлом `SKILL.md`
(YAML frontmatter `name`/`description` + инструкции на Markdown). Pi подхватывает
их автоматически и использует по описанию.

Формат и возможности — см. документацию pi.dev (Skills).
Содержимое сохраняется вместе с окружением pibox.
```

**`env-template/.pi/agent/extensions/README.md`**

```markdown
# Расширения Pi

Пользовательские расширения Pi Coding Agent кладутся в эту директорию и
подхватываются при запуске `pi`. Расширения могут добавлять инструменты,
команды и обработчики событий.

API и формат — см. документацию pi.dev (Extensions).
Содержимое сохраняется вместе с окружением pibox.
```

**`env-template/.pi/agent/prompts/README.md`**

```markdown
# Пользовательские промпты

Markdown-файлы в этой директории становятся доступными как пользовательские
промпты/слэш-команды Pi. Имя файла = имя промпта.

Формат — см. документацию pi.dev (Custom prompts).
```

**`env-template/.pi/agent/sessions/.gitkeep`** — пустой файл (каталог для деревьев сессий `.jsonl`).

**`env-template/.pibox/apt-packages.txt`**

```bash
# apt-пакеты, устанавливаемые В КОНТЕЙНЕР при каждом старте (от root).
# По одному пакету в строке; строки, начинающиеся с '#', игнорируются.
#
# Примеры (тяжёлые отладочные утилиты, не входящие в образ):
#   gdb
#   valgrind
#   strace
#   tcpdump
#   sysstat
#   iotop
#
# Скачанные .deb кэшируются в ~/.pibox/apt-cache — повторные запуски быстрые.
# Управление с хоста: pibox env pkg add|rm|list|clear <имя_окружения> [пакеты]
```

---

## `.gitignore`

```gitignore
# локальные артефакты
*.log
.DS_Store
# на случай запуска из исходников (см. run.sh)
env/
```

---

## `README.md`

```markdown
# PIBOX — безопасный запуск Pi Coding Agent в Docker

**pibox** запускает [Pi Coding Agent](https://pi.dev/) в изолированном
Docker-контейнере:

- текущий каталог монтируется как `/home/pi/workspace` (чтение/запись);
- состояние агента — сессии, конфиги, ключи, расширения, локально установленные
  тулчейны — живёт в окружениях `~/pibox/env/<имя>` и переживает перезапуски;
- агент работает от внутреннего пользователя `pi`, чей UID/GID динамически
  подстраивается под пользователя хоста — файлы в проекте остаются вашими;
- произвольное число окружений (`default`, `php8`, `rust`, …), каждое создаётся
  автоматически из `env-template` при первом использовании;
- разумные лимиты CPU/памяти/процессов, no-new-privileges, без доступа к
  docker.sock и без привилегий внутри контейнера.

## Как это работает

```
 ХОСТ                                       КОНТЕЙНЕР (pibox)
 ───────────────────────────────────        ────────────────────────────────────────
 ~/pibox/                                   PID 1: tini
 ├─ bin/pibox ──── docker run ────────►     └─ entrypoint.sh (root)
 ├─ docker/                                    ├─ usermod: pi → UID/GID хоста
 │   ├─ Dockerfile                            ├─ rsync /opt/skel → /home/pi
 │   └─ entrypoint.sh                         ├─ apt-пакеты окружения (опция)
 ├─ env-template/ ──(новое окружение)──►      ├─ git safe.directory (опция)
 ├─ env/                                       └─ gosu pi:pi → pi <args>
 │   ├─ models.json
 │   └─ default/ ────── bind mount ─────►     /home/pi
 └─ ...                                        /home/pi/workspace
 ~/my-project ───────── bind mount ─────►
```

| Аспект | Решение |
|---|---|
| Состояние агента | bind-mount `env/<имя>` → `/home/pi`, шаблон `env-template` |
| Модели окружений | `default`, произвольные; создаются автоматически из шаблона |
| Размер образа | multi-stage; языки — через `mise` в `~/.local`, отладчики — apt-пакеты окружения |
| Dotfiles | эталон `/opt/skel`, мердж без перезаписи в `entrypoint.sh` |
| UID/GID | динамическая подстройка в `entrypoint.sh` (`usermod`/`groupmod` + `chown`) |
| Безопасность workspace | `realpath`-проверка: workspace не внутри PIBOX_DIR и наоборот |
| Сеть | `host.docker.internal:host-gateway`, caps `SYS_PTRACE`+`NET_RAW` |
| API-ключи | через переменные окружения (проброска), models.json — только шаблон |
| Docker Compose | не используется — интерактивный запуск и динамические монтирования |

## Требования

- Linux (лучше всего) или Docker Desktop; **Docker ≥ 20.10** (нужен `host-gateway`);
- bash ≥ 4.4;
- ~2 ГБ диска под образ.

## Быстрый старт

```bash
git clone <репозиторий> pibox && cd pibox
chmod +x run.sh entrypoint.sh install.sh
./install.sh                 # установит в ~/pibox, предложит собрать образ
# или: ./install.sh --dir ~/pibox --yes --build

cd ~/my-project
pibox                        # pi стартует с этой директорией
```

Образ при первом запуске собирается автоматически (или вручную: `pibox build`).

## Команды и опции

```
pibox [ОПЦИИ] [-- АРГУМЕНТЫ_PI]     запуск pi в текущей директории
pibox shell                          bash в том же контейнере/окружении
pibox exec КОМАНДА [АРГ...]         команда в том же окружении
pibox build [--no-cache] [--pull] [--build-arg К=З]
pibox env list|create|remove|reset|path|pkg ...
pibox ps | doctor | help | version
```

Основные опции запуска: `-e/--env`, `-p/--port` (например `-p 3000` или
`-p 127.0.0.1:3000:8080`), `-n/--name`, `-C/--cd`, `-E/--env-var КЛЮЧ[=ЗН]`,
`--cpus`, `--mem`, `--pids`, `--git-safe`, `--offline`, `--image`,
`--no-build`, `--dry-run`. Полный список — `pibox --help`.

Примеры:

```bash
pibox -e php8 -p 8080               # окружение php8, порт 8080:8080
pibox -- --resume                   # флаги самого pi — после '--'
pibox -E GROQ_API_KEY exec pi --version
pibox --cpus 4 --mem 8g --dry-run   # посмотреть итоговую docker-команду
pibox env create rust --from default
pibox env pkg add default gdb strace
pibox env reset default --yes
```

## Окружения (`env`)

Окружение — это каталог `~/pibox/env/<имя>`, монтируемый как `/home/pi`.
Внутри сохраняются: `~/.pi/` (сессии, расширения, скиллы, models.json),
`~/.local/` (mise-тулчейны, pip/npm-пакеты), dotfiles, кэши.
Если окружение отсутствует — создаётся из `env-template`, затем туда
копируется `env/models.json` (только если его там ещё нет).

### Установка инструментов агентом

- **Языки/тулчейны** (node, python, go, rust, cmake, …): агент ставит через
  `mise` в `~/.local` — персистентно в окружении.
- **Системные пакеты** (gdb, valgrind, strace, tcpdump, sysstat, iotop, …):
  через mise недоступны, поэтому используется файл `~/.pibox/apt-packages.txt`
  (`pibox env pkg add <env> <пакет>`): пакеты устанавливаются entrypoint'ом
  при старте контейнера, скачанные `.deb` кэшируются в `~/.pibox/apt-cache`.
  Контейнер эфемерный, поэтому установка повторяется при каждом запуске —
  из кэша это занимает секунды. Для «вечной» установки пакета — добавьте его
  в Dockerfile и пересоберите образ.

### Переменные окружения pibox

| Переменная | По умолчанию | Описание |
|---|---|---|
| `PIBOX_DIR` | авто (по скрипту) | каталог установки |
| `PIBOX_IMAGE` | `pibox:latest` | имя образа |
| `PIBOX_ENV` | `default` | окружение по умолчанию |
| `PIBOX_CPUS` / `PIBOX_MEMORY` / `PIBOX_PIDS` | `2` / `4g` / `1024` | лимиты ресурсов |
| `PIBOX_GIT_SAFE` | `0` | git safe.directory по умолчанию |
| `PIBOX_PASS_ENV` | — | доп. имена переменных для проброски (через пробел) |

## Модели и API-ключи

- `~/pibox/env/models.json` — шаблон; копируется в окружение при первом запуске.
  Отредактируйте под своего провайдера (схему см. в документации pi.dev).
  Локальный Model API хоста: `http://host.docker.internal:8080`.
- Ключи API передаются переменными окружения — pibox автоматически пробрасывает
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY`,
  `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`,
  `MISTRAL_API_KEY`, `XAI_API_KEY`, `DEEPSEEK_API_KEY`, `TOGETHER_API_KEY`,
  а также `HTTP(S)_PROXY`/`NO_PROXY`. Дополнительно:
  `-E ИМЯ_ПЕРЕМЕННОЙ` (взять с хоста) или `-E ИМЯ=ЗНАЧЕНИЕ`.

## Образ

Multi-stage: в стадии `tools` скачиваются Node.js (в `/usr/local`, актуальная
LTS-версия поверх apt-версии 18), `mise` и npm-пакет Pi; в финальный образ
копируется только результат. Базовый apt-набор — по спецификации (Ubuntu 24.04;
имена пакетов проверены под noble). Особенности:

- `cat`/`find`/`xargs` уже в coreutils/findutils базового образа;
- `pip` разрешён к установке в `~/.local` (PEP 668 override в `/etc/pip.conf`);
- `npm i -g` у агента идёт в `~/.local` (`.npmrc` с `prefix`);
- apt-`yq` — это python-обёртка над jq (синтаксис фильтров jq, не mikefarah);
- gosu/tini из Ubuntu; эталон home хранится в `/opt/skel`.

Build-аргументы: `UBUNTU_VERSION`, `NODE_VERSION`, `MISE_VERSION`
(пусто = последний релиз), `PI_PACKAGE`.

```bash
pibox build --build-arg UBUNTU_VERSION=24.04 --build-arg PI_PACKAGE=@mariozechner/pi
```

## Безопасность: что изолировано, а что нет

**Изолировано/ограничено:** файловая система вне `/home/pi` (эфемерная),
процессы, сеть (опция `--offline`), лимиты CPU/памяти/pids, `no-new-privileges`,
нет sudo внутри контейнера, нет доступа к docker.sock, workspace не может
находиться внутри `PIBOX_DIR` (и наоборот) — защита конфигов pibox.

**Честные ограничения:** `workspace` и `env` смонтированы **на запись** —
агент физически может изменить или удалить ваши файлы в проекте; окружение
хранит ключи API в открытом виде (как и `~/.pi` без pibox); контейнер имеет
доступ в интернет и локальную сеть, а `SYS_PTRACE`/`NET_RAW` — расширенные
права (нужны для отладки). Это «песочница для порядка, воспроизводимости и
разделения окружений», а не жёсткая security-граница; при необходимости
усилить: `--offline`, read-only mounts, rootless docker, сетевые политики.

## Troubleshooting

| Симптом | Решение |
|---|---|
| git: «dubious ownership» | `pibox --git-safe` (или `PIBOX_GIT_SAFE=1`) |
| `host.docker.internal` не резолвится | Docker < 20.10 — обновите; проверьте `pibox doctor` |
| Сборка падает на пакете | имена пакетов зависят от версии Ubuntu; попробуйте `--build-arg UBUNTU_VERSION=22.04` и уберите `xxd` |
| «UID/GID уже занят» | UID хоста совпал с системным пользователем образа — редкий случай, смените ARG в Dockerfile |
| env распух | `pibox env list`, почистите `~/.local/share/mise` или `pibox env reset <имя>` |
| apt-пакеты окружения не ставятся | нужен интернет при старте контейнера; смотрите предупреждения entrypoint |
| Два контейнера на одном env | не рекомендуется: гонки по сессиям/кэшам — используйте разные окружения |

## FAQ

**Почему не docker compose?** Интерактивный терминальный агент + монтирование
текущего каталога + динамические порты/окружения — это скрипт из 30 строк,
а не статичный YAML. Плюс это требование проекта.

**Почему не пробрасывается docker.sock?** Это дало бы агенту контроль над хостом.

**Как добавить системный пакет навсегда?** В `Dockerfile` (строка apt install) и
`pibox build --no-cache`, либо локально для окружения: `pibox env pkg add`.

**Как обновить pibox?** `git pull && ./install.sh` — окружения и данные не
затрагиваются; затем `pibox build --pull`.

**Удаление:** `rm -rf ~/pibox` (плюс строка `# pibox` в `~/.bashrc`),
`docker rmi pibox:latest`.
```

---

## Проверка после установки

```bash
./install.sh --build          # установка + сборка образа
pibox doctor                  # все проверки зелёные
cd ~/какой-то-проект && pibox # pi стартует, файлы создаются от вашего UID
pibox exec id                 # uid=...(...) gid=...(...) — как на хосте
pibox --dry-run -p 3000       # посмотреть итоговую docker-команду
```

**Замечания по сопровождению:** имена пакетов проверены под Ubuntu 24.04 (noble); при смене `UBUNTU_VERSION` проверьте `xxd`/`lz4`/`gosu` (исторически переименовывались). Версии Node и mise — build-аргументы; npm-пакет Pi (`@mariozechner/pi`) и схема `models.json` соответствуют документации pi.dev — при изменении релизов правится одна строка Dockerfile/один JSON-файл. Все ключевые инварианты (bind-монтирования, подстройка UID, `/opt/skel`, защита workspace, `env-template` → авто-создание окружений) реализованы точно по спецификации.