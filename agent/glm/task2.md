# Задача 2 — Каркас репозитория

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent: `/home/pi` контейнера — это смонтированный с хоста каталог окружения, текущая директория пользователя становится `workspace` агента. Репозиторий — исходники, из которых `install.sh` разворачивает инсталляцию в `PIBOX_DIR`. |
| **Цель задачи** | Создать структуру каталогов, git-инфраструктуру (LF, exec-биты, игноры), соглашения по коду и CI. Все скрипты — валидные заглушки, проходящие `shellcheck`. |
| **Зависимости** | Задача 1 (`docs/NOTES.md` коммитится как есть) |
| **Статус** | ✅ Готово к выполнению |

**Что НЕ входит в задачу:** реализация логики скриптов (задачи 5–7), содержимое `env-template/` (задача 4), реальный Dockerfile (задача 3), тесты (задача 8). Заглушки намеренно минимальны, но валидны.

---

## 1. Итоговая структура репозитория

```
pibox/
├── .github/
│   └── workflows/
│       └── ci.yml            # CI: shellcheck + exec-биты + docker build
├── .dockerignore             # минимальный build-контекст
├── .gitattributes            # принудительный LF для скриптов и Docker
├── .gitignore                # игноры; env-template КОММИТИМ
├── Dockerfile                # ЗАГЛУШКА (собирается; полная — задача 3)
├── README.md                 # заглушка (полная — задача 9)
├── entrypoint.sh             # ЗАГЛУШКА (полная — задача 5)
├── install.sh                # ЗАГЛУШКА (полная — задача 7)
├── models.json               # шаблон конфига моделей (плейсхолдеры)
├── run.sh                    # ЗАГЛУШКА CLI: --help/--version работают (задача 6)
├── docs/
│   ├── CONVENTIONS.md        # соглашения по коду — артефакт этой задачи
│   └── NOTES.md              # артефакт задачи 1, коммитится без изменений
├── env-template/
│   └── README.md             # плейсхолдер (наполнение — задача 4)
└── tests/
    └── smoke.sh              # ЗАГЛУШКА (полная — задача 8)
```

---

## 2. Содержимое файлов

### 2.1 `.gitattributes`

```gitattributes
# Окончания строк: всё, что исполняется внутри Linux-контейнера,
# обязано быть LF. CRLF в entrypoint.sh ломает запуск
# ("bad interpreter: /usr/bin/env^M") и не ловится ничем, кроме запуска.

*.sh          text eol=lf
Dockerfile    text eol=lf
.dockerignore text eol=lf
*.yml         text eol=lf
*.yaml        text eol=lf

# Данные и документация — нормализация в LF на коммите
*.md          text
*.json        text
```

### 2.2 `.gitignore`

```gitignore
# Локальные заметки исполнителя (не для общего доступа)
docs/NOTES.local.md

# Временные файлы и логи
*.log
*.tmp
*.bak
tmp/
.cache/

# Результаты локальных прогонов тестов
tests/.results/

# ОС
.DS_Store
Thumbs.db

# Редакторы
.idea/
.vscode/
*.swp
*.swo

# СТРАХОВКА: реальные окружения pibox никогда не коммитятся.
# После install.sh они живут в PIBOX_DIR (обычно вне репозитория).
# Паттерн привязан к корню (/env/), чтобы НЕ задеть env-template/ —
# шаблон коммитится намеренно. Не менять на "env*" или "env/"!
/env/

# ВАЖНО: env-template/ и models.json (шаблон с плейсхолдерами) КОММИТИМ.
# Реальные API-ключи и живые окружения в репозитории запрещены.
```

### 2.3 `.dockerignore`

```dockerignore
# Build-контекст минимален: для сборки образа нужны только Dockerfile
# и entrypoint.sh. CLI, установщик, шаблоны, тесты и документация
# в образ не попадают (после install.sh контекст живёт в PIBOX_DIR/docker/).
*
!Dockerfile
!entrypoint.sh
!.dockerignore
```

### 2.4 `Dockerfile` (заглушка)

```dockerfile
# ЗАГЛУШКА (задача 2): минимальный собирающийся каркас,
# чтобы CI мог проверять собираемость с самого начала.
# Полная multi-stage сборка (Node, pi, mise, /opt/skel) — задача 3.
FROM ubuntu:24.04
```

### 2.5 `run.sh` (заглушка CLI)

```bash
#!/usr/bin/env bash
# pibox — CLI для безопасного запуска Pi Coding Agent в Docker.
#
# ЗАГЛУШКА (задача 2): работают только --help и --version.
# Полная реализация (подкоманды, проверки, docker run) — задача 6.
#
# КОНТРАКТ с задачей 7: после установки этот скрипт живёт как
# PIBOX_DIR/bin/pibox, причём install.sh подменяет плейсхолдер
# __PIBOX_DIR__ ниже на фактический путь установки.

set -euo pipefail

VERSION="0.1.0-dev"
PIBOX_DIR="${PIBOX_DIR:-__PIBOX_DIR__}"

err() {
    echo "pibox: error: $*" >&2
}

usage() {
    cat <<'EOF'
pibox — запуск Pi Coding Agent в изолированном Docker-контейнере

Использование:
    pibox [run] [OPTIONS] [--] [PI_ARGS...]

Подкоманды:
    run                        запуск агента (по умолчанию)
    build [--no-cache]         сборка Docker-образа
    env list|create|remove     управление окружениями
    shell [-e NAME]            отладочная оболочка в контейнере
    update                     обновление установки
    doctor                     диагностика окружения

Опции запуска:
    -e, --env NAME             окружение (по умолчанию default)
    -p, --publish SPEC         проброс порта (повторяемая)
    -E, --pass-env VAR         проброс переменной окружения (повторяемая)
        --env-file FILE        файл с переменными окружения
        --memory LIMIT         лимит памяти (напр. 4g)
        --cpus N               лимит CPU
        --pids-limit N         лимит процессов
        --resync-skel          повторный merge /opt/skel в home
        --git-safe             git safe.directory для workspace
        --dry-run              напечатать команду docker run и выйти
    -h, --help                 эта справка
    -V, --version              версия

Полный CLI реализуется в задаче 6. Сейчас это заглушка.
EOF
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        -V|--version)
            echo "pibox ${VERSION}"
            exit 0
            ;;
        *)
            err "CLI ещё не реализован (задача 6). Доступны только --help и --version."
            exit 1
            ;;
    esac
}

main "$@"
```

### 2.6 `entrypoint.sh` (заглушка)

```bash
#!/usr/bin/env bash
# Entrypoint контейнера pibox: подстройка UID/GID, skel-merge,
# exec через gosu pi:pi tini -- "$@".
#
# ЗАГЛУШКА (задача 2). Полная реализация — задача 5.

set -euo pipefail

echo "pibox: entrypoint.sh — заглушка, полная реализация в задаче 5." >&2
exit 1
```

### 2.7 `install.sh` (заглушка)

```bash
#!/usr/bin/env bash
# Установщик pibox: разворачивает инсталляцию в PIBOX_DIR
# (bin/pibox, docker/, env-template/, env/default, models.json).
#
# ЗАГЛУШКА (задача 2). Полная реализация — задача 7.

set -euo pipefail

echo "pibox: install.sh — заглушка, полная реализация в задаче 7." >&2
exit 1
```

### 2.8 `models.json` (шаблон)

```json
{
  "providers": {
    "local": {
      "name": "Local Model API",
      "baseUrl": "http://host.docker.internal:8080/v1",
      "type": "openai",
      "apiKey": "REPLACE_ME",
      "models": [
        {
          "id": "local-model",
          "name": "Local Model",
          "maxTokens": 4096
        }
      ]
    }
  },
  "defaultProvider": "local",
  "defaultModel": "local-model"
}
```

> ⚠️ **Схема — черновик.** Точный формат `models.json` помечен как TODO в `docs/NOTES.md` (задача 1, открытый вопрос №4). Перед задачой 6 сверить с официальной документацией Pi (`docs/models.md` в репозитории `earendil-works/pi`). Реальные ключи сюда не писать — только плейсхолдеры.

### 2.9 `env-template/README.md` (плейсхолдер)

```markdown
# env-template — шаблон окружения

Содержимое этого каталога копируется в `PIBOX_DIR/env/<name>` при создании
нового окружения и становится `/home/pi` внутри контейнера pibox.

**ЗАГЛУШКА (задача 2):** каталог-плейсхолдер. Наполнение (конфиги Pi,
`.bashrc`, `.gitconfig`, `.tmux.conf`) выполняется в задаче 4.

Важно: `models.json` сюда НЕ входит — он кладётся в окружение отдельно
при первом запуске (из `PIBOX_DIR/env/models.json`).
```

### 2.10 `tests/smoke.sh` (заглушка)

```bash
#!/usr/bin/env bash
# Smoke-тесты pibox: изоляция каталогов, UID/GID, персистентность,
# сеть, capabilities, лимиты, проброс портов.
#
# ЗАГЛУШКА (задача 2). Полная реализация — задача 8.

set -euo pipefail

echo "pibox: smoke-тесты — заглушка, полная реализация в задаче 8." >&2
exit 1
```

### 2.11 `README.md` (заглушка)

```markdown
# PIBOX

Безопасный запуск Pi Coding Agent (https://pi.dev/) в изолированном
Docker-контейнере с сохранением состояния между сессиями.

**Статус:** каркас репозитория (задача 2). Функциональность добавляется
по задачам плана — прогресс и факты см. в docs/NOTES.md.

Структура репозитория:

Dockerfile      сборка образа (задача 3)
entrypoint.sh   entrypoint контейнера (задача 5)
run.sh          исходник CLI pibox (задача 6)
install.sh      установщик на хост (задача 7)
models.json     шаблон конфигурации моделей (плейсхолдеры)
env-template/   шаблон окружения /home/pi (задача 4)
tests/          smoke-тесты (задача 8)
docs/           CONVENTIONS.md — соглашения; NOTES.md — технические факты

Разработка: соглашения — docs/CONVENTIONS.md; проверка скриптов —
shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh

Полная документация появится в задаче 9.
```

### 2.12 `docs/CONVENTIONS.md`

````markdown
# CONVENTIONS — соглашения по коду pibox

Обязательны для всех shell-скриптов проекта: `run.sh`, `install.sh`,
`entrypoint.sh`, `tests/smoke.sh`.

## 1. Общий каркас скрипта

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `set -e` — падение на первом сбое, без «продолжения полуживым»;
- `set -u` — необъявленная переменная = ошибка (ловит опечатки);
- `set -o pipefail` — сбой любого звена пайпа = сбой пайпа.

## 2. Сообщения

Хелперы (пока дублируются в каждом скрипте):

```bash
err()  { echo "pibox: error: $*" >&2; }
warn() { echo "pibox: warn:  $*" >&2; }
log()  { echo "==> $*"; }
die()  { err "$*"; exit 1; }
```

Правила:

- Ошибки — только в **stderr**, всегда с префиксом `pibox:`.
- Фатальная ошибка сопровождается советом, что делать.
  Плохо: `die "docker not found"`.
  Хорошо: `die "docker не найден. Установите Docker >= 20.10: https://docs.docker.com/engine/install/"`
- Видимые пользователю шаги (особенно первый запуск) логируются через `log`:
  `log "создаю окружение 'php8' из шаблона"`.

## 3. Bash-гигиена

- Раскрытие переменных — всегда в кавычках: `"$path"`, `"${arr[@]}"`.
- Сборка аргументов команд — **только массивами**:

  ```bash
  args=()
  args+=(--cap-add SYS_PTRACE)
  args+=(-v "$env_dir":/home/pi)
  docker run "${args[@]}" "$image"
  ```

  Конкатенация строк в команду запрещена (word splitting, пробелы в путях).
- Локальные переменные: `local foo="$1"`.
- Проверка команды: `command -v docker >/dev/null 2>&1 || die "..."`.
- Числа: `(( x > 0 ))`; регэкспы: `[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]`.
- Heredoc с текстом справки — в кавычках: `<<'EOF'` (чтобы `$` не интерпретировался).

## 4. Поведение

- Внешние зависимости проверяются до начала работы.
- Пользовательский ввод валидируется до первого использования.
- Любая ошибка = ненулевой exit + понятное сообщение; никаких «тихих» сбоев.
- `|| true` — только с комментарием, почему сбой ожидаем и не важен.
- Идемпотентность: повторный запуск шага не ломает данные
  (критично для `install.sh` и автосоздания env).

## 5. shellcheck

Все коммиты со скриптами обязаны проходить:

    shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh

CI (`.github/workflows/ci.yml`) гоняет shellcheck на каждый PR.

## 6. Git

- `.gitattributes` закрепляет LF для `*.sh`, `Dockerfile`, `.dockerignore`,
  `*.yml` — менять нельзя: CRLF в `entrypoint.sh` ломает контейнер.
- Скрипты коммитятся с executable-битом. Проверка:
  `git ls-files -s '*.sh'` → режим `100755`.
  Восстановление: `git update-index --chmod=+x <file>`
  (права в файловой системе НЕ достаточно — git хранит режим в индексе).
- Имена файлов/каталогов — kebab-case, ASCII, без пробелов.

## 7. Секреты

- В репозитории нет реальных API-ключей: `models.json` — только плейсхолдеры.
- Реальные окружения и ключи живут в `PIBOX_DIR` (вне репозитория).
- Перед коммитом с изменением конфигов — глазами проверить diff на ключи.

## 8. Тексты

- Пользовательские сообщения — по-русски; код, идентификаторы, коммиты — по-английски.
- Решения и подводные камни фиксируются в `docs/NOTES.md`, а не в устной памяти.
````

### 2.13 `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    name: shellcheck + exec-биты
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Установить shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck

      - name: shellcheck
        run: shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh

      - name: Исполняемые биты скриптов в git
        run: |
          status=0
          while IFS= read -r f; do
            mode="$(git ls-files -s "$f" | awk '{print $1}')"
            if [ "$mode" != "100755" ]; then
              echo "::error::${f} не исполняемый в git (режим ${mode}). Запустите: git update-index --chmod=+x ${f}"
              status=1
            fi
          done < <(git ls-files '*.sh')
          exit "$status"

  build:
    name: docker build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Собрать образ
        run: docker build -t pibox:ci .
```

---

## 3. Контракты, зафиксированные каркасом

Каркас не только создаёт файлы — он дословно фиксирует интерфейсы между будущими задачами:

| Контракт | Где зафиксирован | Используют |
|---|---|---|
| Синтаксис CLI (подкоманды и опции) | `usage()` в `run.sh` | Задача 6 (реализация), 8 (тесты), 9 (README) |
| Механизм `__PIBOX_DIR__` → подстановка путей | комментарий в `run.sh` | Задача 7 (`install.sh`) |
| Расположение файлов в `PIBOX_DIR` | `README.md`, `env-template/README.md` | Задачи 6, 7 |
| Формат `models.json` (черновик) | `models.json` + TODO в `NOTES.md` | Задачи 4, 6 |
| Стандарт кода | `docs/CONVENTIONS.md` | Все последующие задачи |

---

## 4. Команды инициализации и проверки

```bash
# 1. Инициализация
git init pibox && cd pibox
mkdir -p env-template tests docs .github/workflows

# 2. Создать файлы из раздела 2, затем выставить права
chmod +x run.sh install.sh entrypoint.sh tests/smoke.sh

# 3. Индексация
git add -A

# 4. Проверка 1: shellcheck без замечаний
shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh

# 5. Проверка 2: LF закреплён атрибутами
git check-attr eol -- run.sh entrypoint.sh Dockerfile .github/workflows/ci.yml
# ожидаем: eol: lf для каждого файла

# 6. Проверка 3: исполняемые биты в индексе git
git ls-files -s run.sh install.sh entrypoint.sh tests/smoke.sh
# ожидаем режим 100755 у каждого (если 100644 — git update-index --chmod=+x <file>)

# 7. Проверка 4: заглушка Dockerfile собирается
docker build -t pibox:skeleton .

# 8. Проверка 5: CLI-заглушка ведёт себя корректно
./run.sh --version    # → pibox 0.1.0-dev
./run.sh --help       # → справка
./run.sh foo          # → ошибка в stderr, exit 1

# 9. Первый коммит
git commit -m "chore: repository skeleton (task 2)"
```

---

## 5. ✅ Критерии готовности

- [ ] Структура каталогов соответствует дереву из раздела 1
- [ ] `shellcheck` чист на всех четырёх скриптах
- [ ] `git check-attr eol -- run.sh` → `lf`
- [ ] `git ls-files -s *.sh` → `100755` для каждого скрипта
- [ ] `docker build` на заглушке `Dockerfile` проходит
- [ ] `./run.sh --version`, `--help` работают; прочие вызовы — ошибка + exit 1
- [ ] `./install.sh`, `./entrypoint.sh`, `tests/smoke.sh` завершаются с понятным сообщением о заглушке
- [ ] `git status` чист; в индексе нет секретов (визуальная проверка `git diff --cached`)
- [ ] CI зелёный после пуша (если репозиторий размещён на GitHub)

---

## 6. ⚠️ Подводные камни

1. **Exec-бит.** `chmod +x` в файловой системе — необходимо, но недостаточно: git хранит режим в индексе. На Linux режим подхватывается при `git add`, на **Windows/macOS этого не происходит** — обязательно проверяйте `git ls-files -s` и при необходимости `git update-index --chmod=+x`. CI-джоба lint ловит это автоматически.

2. **`.gitignore` против `env-template`.** Самая вероятная ошибка этой задачи — паттерн `env*` или незаякоренный `env/` в игнорах, который случайно исключит `env-template/` (а он коммитится намеренно). Использован корневой `/env/` — не «упрощать» его.

3. **CRLF при разработке на Windows.** `.gitattributes` нормализует окончания при коммите, но если файлы были созданы с CRLF до добавления атрибутов — выполнить `git add --renormalize .` и проверить `git ls-files --eol`.

4. **Heredoc в `usage()`.** Только `<<'EOF'` (закавыченный) — иначе `$` в тексте справки будет интерпретироваться bash'ем.

5. **`models.json` — не финальный.** Схема помечена TODO в NOTES.md; задачам 4/6 перед финализацией сверить её с `docs/models.md` репозитория Pi. Пока файл нужен только как «слот» в структуре и контракте install.sh.

6. **CI build на заглушке.** Джоба `docker build` сейчас проверяет только то, что `Dockerfile`-заглушка собирается. Это осознанно — CI не должен краснеть между задачами 2 и 3. Реальная multi-stage сборка подключится в задаче 3 без изменений в workflow.

---

## 7. Что передаётся следующим задачам

| Следующая задача | Получает |
|---|---|
| **3 (Dockerfile)** | слот `Dockerfile` + `.dockerignore`, гарантирующий минимальный контекст; CI уже проверяет собираемость |
| **4 (env-template)** | каталог с README-плейсхолдером; правило «models.json не входит в шаблон» |
| **5 (entrypoint)** | файл-заглушка с зафиксированным контрактом (gosu/tini, UID/GID) |
| **6 (run.sh)** | каркас с `set -euo pipefail`, хелперами `err`/`usage`, полным текстом CLI-справки и механизмом `__PIBOX_DIR__` |
| **7 (install.sh)** | список копируемых артефактов из структуры репо |
| **8 (tests)** | `tests/smoke.sh` + CI-джобы, к которым подключатся тесты |