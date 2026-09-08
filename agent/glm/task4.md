# Задача 4 — Шаблон окружения `env-template/`

## 📋 Общая информация

| Параметр | Значение |
|---|---|
| **Контекст проекта** | PIBOX — Docker-песочница для Pi Coding Agent: `/home/pi` контейнера подменяется bind-mount'ом каталога `env/<name>` с хоста. `env-template` — «заводское» содержимое home, из которого копируются новые окружения. |
| **Цель задачи** | Наполнить `env-template/` минимальным, но функциональным содержимым: структура конфигов Pi, дотфайлы для shell/git/tmux, поддержка mise для персистентных тулчейнов. |
| **Зависимости** | Задача 3 (контракт: `/opt/skel` — фолбэк, канонические дотфайлы — здесь; `~/.npmrc` с prefix для npm). |
| **Артефакты** | Каталог `env-template/` со всеми файлами из раздела 2. |
| **Не входит в задачу** | Логика entrypoint (задача 5), CLI/установщик (задачи 6–7), тесты (задача 8). `models.json` **не создаётся** — он копируется из `PIBOX_DIR/env/models.json` при первом запуске окружения (задача 6). |

---

## 🏗️ Ключевые архитектурные решения

| # | Решение | Обоснование |
|---|---|---|
| 1 | **Канонические дотфайлы — в env-template, `/opt/skel` — фолбэк** | Задача 3 зафиксировала контракт: skel содержит только минимальный PATH+mise. Пользовательские настройки (PS1, aliases) — здесь, в каноническом виде. |
| 2 | **`mise` активируется в `.bashrc` для интерактивных сессий** | В неинтерактивных скриптах PATH задаётся ENV образа (задача 3) и переэкспортируется entrypoint (задача 5). |
| 3 | **`~/.npmrc` с `prefix=~/.local`** | Позволяет `npm install -g` от пользователя pi без root, установки персистентны (попадают в env). |
| 4 | **Структура `.pi/agent/` с подкаталогами** | Pi создаёт эти каталоги при первом запуске, но их наличие в шаблоне предотвращает проблемы с правами. |
| 5 | **`AGENTS.md` и `SYSTEM.md` — плейсхолдеры** | Pi читает их для инструкций 【turn0search3】. Шаблоны объясняют пользователю, что туда писать. |

---

## 1. Итоговая структура `env-template/`

```
env-template/
├── .pi/
│   └── agent/
│       ├── sessions/          # Пусто; каталог создаётся заранее
│       ├── extensions/        # README-заглушка
│       ├── skills/            # README-заглушка
│       ├── prompts/           # README-заглушка
│       ├── themes/            # README-заглушка
│       ├── AGENTS.md          # Инструкции для агента
│       ├── SYSTEM.md          # Опционально: заменяет системный промпт
│       └── settings.json      # Настройки Pi
├── .bashrc                    # Активация mise, PATH, aliases
├── .profile                   # Для login-шеллов
├── .gitconfig                 # Безопасные дефолты
├── .tmux.conf                 # Базовая конфигурация tmux
├── .npmrc                     # prefix для npm
└── README.md                  # Общее описание шаблона
```

---

## 2. Содержимое файлов

### 2.1 `env-template/.pi/agent/AGENTS.md`

```markdown
# AGENTS.md — инструкции для Pi Coding Agent

Pi автоматически загружает этот файл и конкатенирует с родительскими
`AGENTS.md` (если есть) 【turn0search3】. Используйте его для:

- Описания проекта и его структуры
- Специфичных для проекта правил кодирования
- Указания, какие инструменты использовать
- Настройки workflow (например, "всегда запускать тесты перед коммитом")

## Пример содержимого:

- **Проект**: pibox — Docker-песочница для Pi
- **Структура**: см. `README.md` в корне
- **Тесты**: `./tests/smoke.sh` перед PR
- **Стиль кода**: следовать `docs/CONVENTIONS.md`

Не пишите сюда секреты — файл попадает в git.
```

### 2.2 `env-template/.pi/agent/SYSTEM.md` (опционально)

```markdown
# SYSTEM.md — опциональная замена системного промпта

Если этот файл существует, Pi заменит стандартный системный промпт
его содержимым 【turn0search3】. Используйте с осторожностью —
это меняет поведение агента глобально для этого окружения.

## Пример (не рекомендуется копировать без необходимости):

Ты — ассистент для разработки в изолированном Docker-контейнере.
Всегда выполняй команды в /home/pi/workspace. Не изменяй файлы вне
рабочей директории без явного разрешения.
```

### 2.3 `env-template/.pi/agent/settings.json`

```json
{
  "settings": {
    "defaultTools": ["read", "write", "edit", "bash"],
    "autoSaveSession": true,
    "compactThreshold": 0.8
  }
}
```

<details>
<summary>📖 Подробнее о настройках Pi</summary>

Pi использует `settings.json` для конфигурации 【turn0search3】. Возможные ключи:
- `defaultTools` — инструменты, доступные модели по умолчанию
- `autoSaveSession` — автосохранение сессий
- `compactThreshold` — порог контекста для компакции

Полный список — в официальной документации Pi (`docs/settings.md` в репозитории `earendil-works/pi`).
</details>

### 2.4 `env-template/.bashrc`

```bash
# ~/.bashrc — каноническая версия для pibox (задача 4).
# Фолбэк из /opt/skel (задача 3) используется только если этот файл отсутствует.

# Неинтерактивный bash не читает rc-файлы; выходим сразу
case $- in *i*) ;; *) return ;; esac

# Тулчейны mise и локальные установки агента
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# Активация mise для интерактивных сессий
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

# История команд
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:erasedups
export HISTTIMEFORMAT="%F %T "

# Цветной вывод и удобный PS1
if command -v tput >/dev/null 2>&1 && [ -n "$(tput colors)" ] && [ "$(tput colors)" -ge 8 ]; then
    PS1='(pibox) \[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
else
    PS1='(pibox) \u@\h:\w\$ '
fi

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'

# Безопасные дефолты для git
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'

# Убедиться, что mise-тулчейны доступны даже если не активированы
if [ -d "$HOME/.local/share/mise/shims" ]; then
    export PATH="$HOME/.local/share/mise/shims:$PATH"
fi
```

### 2.5 `env-template/.profile`

```bash
# ~/.profile — каноническая версия для pibox (задача 4).
# Читается login-шеллами (bash -l, ssh, tmux).

# Тулчейны mise и локальные установки
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# Загрузка .bashrc для интерактивных сессий
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi

# Убедиться, что ~/.local/bin в PATH
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
```

### 2.6 `env-template/.gitconfig`

```ini
# ~/.gitconfig — каноническая версия для pibox (задача 4).

[user]
    # ЗАПОЛНИТЕ перед первым коммитом
    # name = Your Name
    # email = you@example.com

[init]
    defaultBranch = main

[push]
    default = simple

[core]
    # Использовать глобальный .gitignore
    excludesfile = ~/.gitignore_global

[pull]
    rebase = false

[color]
    ui = auto

[alias]
    st = status
    co = checkout
    br = branch
    ci = commit
    # Полезные aliases
    last = log -1 HEAD
    unstage = reset HEAD --
    lg = log --oneline --graph --decorate
```

### 2.7 `env-template/.gitignore_global` (опционально)

```gitignore
# Глобальный .gitignore — применяется ко всем репозиториям пользователя

# ОС
.DS_Store
Thumbs.db

# Редакторы
.idea/
.vscode/
*.swp
*.swo

# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/

# Node.js
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Логи
*.log
```

### 2.8 `env-template/.tmux.conf`

```bash
# ~/.tmux.conf — базовая конфигурация для pibox (задача 4).

# История команд
set -g history-limit 10000

# Начинать нумерацию окон с 1
set -g base-index 1
setw -g pane-base-index 1

# Мышь
set -g mouse on

# Цветовая схема
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

# Статус-бар
set -g status-left-length 50
set -g status-right-length 150
set -g status-left '#[fg=green](pibox) #[fg=white]❐ #S #[default]'
set -g status-right '#[fg=cyan]#{?client_prefix,⌨️  ,} %H:%M %d-%b-%y #[fg=white]#{?window_bigger,[#{window_offset}#{window_size}],}#{s/  / /:window_panes}'

# Сессии
set -g status-justify centre

# Панели
set -g pane-border-style fg=colour238
set -g pane-active-border-style fg=colour46

# Сплиты
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Навигация по панелям с Alt+стрелки
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Перезагрузка конфига
bind r source-file ~/.tmux.conf \; display-message "Config reloaded!"
```

### 2.9 `env-template/.npmrc`

```ini
# ~/.npmrc — конфигурация npm для pibox (задача 4).
# Устанавливает prefix для глобальных установок в ~/.local,
# чтобы npm install -g работал без root и установки были персистентны.

prefix=${HOME}/.local
```

<details>
<summary>📖 Почему prefix важен</summary>

По умолчанию `npm install -g` пытается писать в `/usr/local`, что требует root. С `prefix=${HOME}/.local`:
- Установки идут в `~/.local/lib/node_modules`
- Бинарники в `~/.local/bin` (уже в PATH из .bashrc)
- Установки персистентны — попадают в env-каталог и переживают перезапуск контейнера

Аналогично работает `~/.local/share/mise` для тулчейнов mise 【turn0search11】.
</details>

### 2.10 `env-template/.pi/agent/extensions/README.md`

```markdown
# extensions/ — расширения Pi Coding Agent

Сюда кладутся TypeScript-файлы расширений для Pi 【turn0search0】.

## Установка из npm:
```bash
pi install npm:@pi-unipi/utility
```

## Установка из git:
```bash
pi install git+https://github.com/user/repo
```

## Свои расширения:
Создайте файл `extension.ts` в этом каталоге. Pi автоматически загрузит его.

## Пример расширения:
```typescript
// extension.ts
export default function({ defineCommand, defineTool }) {
    defineCommand('my-command', {
        description: 'Моя команда',
        handler: async ({ args }) => {
            console.log('Hello from my extension!', args);
        }
    });
}
```

⚠️ Безопасность: расширения выполняют код с правами агента. Проверяйте исходники перед установкой 【turn0search0】.
```

### 2.11 `env-template/.pi/agent/skills/README.md`

```markdown
# skills/ — навыки (skills) для Pi Coding Agent

Навыки — пакеты инструкций и инструментов для Pi 【turn0search0】.

## Установка:
```bash
# Через skill.sh (универсальный установщик)
skill.sh install pi https://raw.githubusercontent.com/user/repo/main/skill.md

# Или вручную: положите .md файл в этот каталог
```

## Структура файла навыка:
```markdown
# skill-name

## Description
Что делает этот навык.

## Instructions
Подробные инструкции для агента.

## Tools
Необходимые инструменты (если есть).
```

## Пример:
```markdown
# code-review

## Description
Навык для ревью кода.

## Instructions
1. Прочитать изменённые файлы
2. Проверить стиль кода
3. Найти потенциальные баги
4. Предложить улучшения
```
```

### 2.12 `env-template/.pi/agent/prompts/README.md`

```markdown
# prompts/ — шаблоны промптов для Pi

Шаблоны промптов — Markdown-файлы, которые можно вызывать через
`/template-name` 【turn0search0】.

## Создание шаблона:
1. Создайте файл `template-name.md` в этом каталоге
2. Используйте в Pi: `/template-name`

## Пример:
```markdown
# template-review.md
Сделай код-ревью изменённых файлов.
Фокус на:
- Безопасность
- Производительность
- Читаемость
```

## Переменные:
В шаблонах можно использовать `{{ variable }}`:
```markdown
# template-explain.md
Объясни, как работает {{ function_name }}.
```

При вызове: `/template-explain function_name=main`
```

### 2.13 `env-template/.pi/agent/themes/README.md`

```markdown
# themes/ — темы интерфейса для Pi

Темы меняют внешний вид TUI Pi 【turn0search0】.

## Установка:
```bash
pi install npm:theme-name
```

## Свои темы:
Создайте `theme-name.json` в этом каталоге.

## Пример:
```json
{
  "name": "my-theme",
  "colors": {
    "primary": "#00ff00",
    "secondary": "#0000ff",
    "background": "#000000"
  }
}
```

## Применение:
В Pi: `/theme my-theme`
```

### 2.14 `env-template/README.md`

```markdown
# env-template — шаблон окружения pibox

Содержимое этого каталога копируется в `PIBOX_DIR/env/<name>` при создании
нового окружения и становится `/home/pi` внутри контейнера pibox.

## Что здесь хранится:
- **Конфиги Pi**: `.pi/agent/` — настройки, сессии, расширения, навыки
- **Дотфайлы**: `.bashrc`, `.profile`, `.gitconfig`, `.tmux.conf` и др.
- **Тулчейны mise**: `~/.local/share/mise/` (персистентны)
- **npm-установки**: `~/.local/lib/node_modules/` (через prefix в .npmrc)

## Чего здесь НЕТ:
- `models.json` — копируется из `PIBOX_DIR/env/models.json` при первом запуске
- Секретов — реальные ключи только в реальных окружениях, не в шаблоне

## Как использовать:
1. Установите pibox (`install.sh`)
2. Настройте `models.json` (скопируйте из шаблона и заполните ключи)
3. Запустите `pibox` — создаст `default` окружение из этого шаблона
4. Для нового окружения: `pibox -e newenv` — создаст из этого шаблона

## Кастомизация:
Измените файлы здесь — они попадут во все новые окружения.
Для существующих окружений редактируйте файлы в `PIBOX_DIR/env/<name>/`.

## Важно:
- Права: файлы 644, каталоги 755
- Никаких секретов в git
- `models.json` отдельно (не в шаблоне)
```

---

## 3. Инструкция по созданию

```bash
# 1. Перейдите в корень репозитория pibox
cd /path/to/pibox

# 2. Очистите возможные остатки (если были попытки)
rm -rf env-template

# 3. Создайте структуру
mkdir -p env-template/.pi/agent/{sessions,extensions,skills,prompts,themes}

# 4. Создайте файлы (см. раздел 2 выше)
#    Используйте редактор или скрипт:
cat > env-template/.bashrc <<'EOF'
# ... (содержимое из 2.4)
EOF

# 5. Установите права
find env-template -type d -exec chmod 755 {} \;
find env-template -type f -exec chmod 644 {} \;

# 6. Проверьте структуру
tree env-template || find env-template -type f | sort

# 7. Визуальная проверка: нет ли секретов
grep -r "API_KEY\|SECRET\|TOKEN" env-template/ --include="*" | grep -v "README\|example" || echo "OK: секретов нет"

# 8. Проверьте, что models.json отсутствует
[ ! -f env-template/.pi/agent/models.json ] && echo "OK: models.json нет"

# 9. Коммит
git add env-template
git commit -m "feat(env-template): canonical home template (task 4): pi configs, dotfiles, mise/npm support"
```

---

## 4. ✅ Критерии готовности

- [ ] Структура `env-template/` соответствует разделу 1
- [ ] Все файлы из раздела 2 созданы с корректным содержимым
- [ ] Права: каталоги 755, файлы 644
- [ ] В `env-template` нет секретов (визуальная проверка + grep)
- [ ] `env-template/.pi/agent/models.json` **не существует**
- [ ] `.bashrc` содержит активацию mise и PATH с шимами
- [ ] `.npmrc` содержит `prefix=${HOME}/.local`
- [ ] `AGENTS.md` и `SYSTEM.md` — валидные Markdown-плейсхолдеры
- [ ] `README.md` объясняет назначение и ограничения
- [ ] `git status` чист; изменения закоммичены

---

## 5. ⚠️ Подводные камни

1. **Не включать `models.json` в шаблон.** По архитектуре он копируется из `PIBOX_DIR/env/models.json` при первом запуске окружения (задача 6). Иначе обновление конфига моделей не дошло бы до уже созданных окружений.

2. **Права на файлы.** Git хранит режим в индексе. После создания файлов убедитесь, что они исполняемые (если нужно) через `git update-index --chmod=+x`.

3. **Секреты.** В шаблоне не должно быть реальных ключей API. Только плейсхолдеры или комментарии.

4. **Совместимость с `/opt/skel`.** Задача 3 создала минимальный фолбэк в `/opt/skel`. Канонические дотфайлы здесь — более полные. Убедитесь, что PATH и mise в обоих согласованы.

5. **`mise activate` vs `PATH`.** В `.bashrc` используется `eval "$(mise activate bash)"` для интерактивных сессий 【turn0search11】【turn0search13】. Для неинтерактивных скриптов PATH задаётся ENV образа (задача 3) и переэкспортируется entrypoint (задача 5).

6. **npm prefix.** Убедитесь, что `~/.npmrc` с `prefix=${HOME}/.local` работает: тестовая установка `npm install -g <package>` должна пройти без root.

---

## 6. 🔗 Контракты, зафиксированные задачей 4

| Контракт | Значение |
|---|---|
| Канонические дотфайлы | В `env-template/`, не в `/opt/skel` |
| `models.json` | **Не входит** в шаблон; копируется из `PIBOX_DIR/env/models.json` |
| mise-тулчейны | `~/.local/share/mise/` (внутри home → персистентны) |
| npm-установки | `~/.local/lib/node_modules/` (через prefix в `~/.npmrc`) |
| Структура Pi | `.pi/agent/{sessions,extensions,skills,prompts,themes}` |
| Инструкции | `AGENTS.md`, `SYSTEM.md` (опционально) |

**Что получают следующие задачи:**

| Задача | Получает |
|---|---|
| **5 (entrypoint)** | контракт дотфайлов: канонические здесь, фолбэк в skel |
| **6 (run.sh)** | логику копирования `env-template` → `env/<name>` |
| **7 (install.sh)** | список файлов для копирования в `PIBOX_DIR` |
| **8 (тесты)** | структуру для проверки персистентности тулчейнов и конфигов |