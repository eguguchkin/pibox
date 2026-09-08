Ниже представлена полная реализация **Задачи 1**. 

Для корректной работы установщика нам нужно подготовить минимальную структуру репозитория (файлы-заглушки для следующих задач), чтобы `install.sh` мог их найти и скопировать.

### 📂 1. Структура исходного репозитория
Перед запуском установщика убедитесь, что в корне вашего репозитория PIBOX создана следующая структура:

```text
pibox-repo/
├── install.sh                 # Скрипт установки (реализация ниже)
├── bin/
│   └── pibox                  # CLI-заглушка (для Задачи 4)
├── env/
│   └── models.json            # Базовый конфиг моделей (для Задачи 5)
├── env-template/              # Шаблон окружения
│   └── .pi/
│       └── agent/             # Пустые директории для структуры
├── Dockerfile                 # Заглушка (для Задачи 2)
├── entrypoint.sh              # Заглушка (для Задачи 3)
└── README.md                  # Заглушка (для Задачи 6)
```

---

### 💻 2. Листинги файлов

#### `install.sh`
Основной скрипт установки. Он идемпотентен (повторный запуск не сломает существующие пользовательские окружения) и корректно обрабатывает скрытые файлы (dotfiles).

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Конфигурация ---
# Директория, где находится сам скрипт install.sh (исходники репозитория)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Целевая директория установки PIBOX (по умолчанию ~/pibox)
PIBOX_DIR="${PIBOX_DIR:-$HOME/pibox}"

echo "================================================"
echo " 📦 PIBOX Installer"
echo "================================================"
echo "Source directory: $SOURCE_DIR"
echo "Target directory: $PIBOX_DIR"
echo "================================================"

# --- 1. Создание базовой структуры ---
echo "[1/5] Creating directory structure..."
mkdir -p "$PIBOX_DIR"
mkdir -p "$PIBOX_DIR/bin"
mkdir -p "$PIBOX_DIR/env"

# --- 2. Копирование env-template ---
# Шаблон нужен для создания новых окружений в будущем
echo "[2/5] Syncing env-template..."
mkdir -p "$PIBOX_DIR/env-template"

# Используем rsync для безопасного мерджа (не затирает существующие файлы, 
# если пользователь кастомизировал шаблон локально).
if command -v rsync &> /dev/null; then
    rsync -a --ignore-existing "$SOURCE_DIR/env-template/" "$PIBOX_DIR/env-template/"
else
    # Fallback для систем без rsync (используем tar для сохранения скрытых файлов)
    (cd "$SOURCE_DIR/env-template" && tar -cf - .) | (cd "$PIBOX_DIR/env-template" && tar -xf - --skip-old-files 2>/dev/null || true)
fi

# --- 3. Копирование models.json ---
echo "[3/5] Installing models.json..."
if [ -f "$SOURCE_DIR/env/models.json" ]; then
    # Копируем только если файла еще нет (защита от перезаписи пользовательских ключей)
    cp -n "$SOURCE_DIR/env/models.json" "$PIBOX_DIR/env/models.json" 2>/dev/null || true
else
    echo "⚠️  Warning: env/models.json not found in source directory."
fi

# --- 4. Инициализация окружения 'default' ---
echo "[4/5] Initializing 'default' environment..."
mkdir -p "$PIBOX_DIR/env/default"

# Проверяем, не инициализировано ли уже окружение (например, по наличию директории .pi)
if [ ! -d "$PIBOX_DIR/env/default/.pi" ]; then
    if command -v rsync &> /dev/null; then
        rsync -a "$PIBOX_DIR/env-template/" "$PIBOX_DIR/env/default/"
    else
        (cd "$PIBOX_DIR/env-template" && tar -cf - .) | (cd "$PIBOX_DIR/env/default" && tar -xf -)
    fi
    echo "✅ Environment 'default' created."
else
    echo "✅ Environment 'default' already initialized."
fi

# --- 5. Установка CLI (bin/pibox) ---
echo "[5/5] Installing PIBOX CLI..."
if [ -f "$SOURCE_DIR/bin/pibox" ]; then
    # CLI всегда обновляется до актуальной версии из репозитория
    cp -f "$SOURCE_DIR/bin/pibox" "$PIBOX_DIR/bin/pibox"
    chmod +x "$PIBOX_DIR/bin/pibox"
else
    echo "❌ Error: bin/pibox not found in source directory."
    exit 1
fi

# --- 6. Настройка PATH ---
echo "================================================"
echo "🔧 Configuring PATH..."
USER_SHELL=$(basename "$SHELL")
RC_FILE=""

if [ "$USER_SHELL" = "bash" ]; then RC_FILE="$HOME/.bashrc"
elif [ "$USER_SHELL" = "zsh" ]; then RC_FILE="$HOME/.zshrc"
elif [ "$USER_SHELL" = "fish" ]; then RC_FILE="$HOME/.config/fish/config.fish"
fi

EXPORT_CMD_BASH="export PATH=\"$PIBOX_DIR/bin:\$PATH\""
EXPORT_CMD_FISH="set -gx PATH \"$PIBOX_DIR/bin\" \$PATH"

if [ -n "$RC_FILE" ] && [ -f "$RC_FILE" ]; then
    if ! grep -qF "$PIBOX_DIR/bin" "$RC_FILE"; then
        echo "" >> "$RC_FILE"
        echo "# Added by PIBOX installer" >> "$RC_FILE"
        if [ "$USER_SHELL" = "fish" ]; then
            echo "$EXPORT_CMD_FISH" >> "$RC_FILE"
        else
            echo "$EXPORT_CMD_BASH" >> "$RC_FILE"
        fi
        echo "✅ Added PIBOX to PATH in $RC_FILE"
        echo "👉 Please restart your terminal or run: source $RC_FILE"
    else
        echo "✅ PIBOX is already in PATH."
    fi
else
    echo "⚠️  Could not detect shell RC file. Please add the following to your shell config manually:"
    echo "   $EXPORT_CMD_BASH"
fi

echo "================================================"
echo "🎉 Installation complete!"
echo "Run 'pibox' in your project directory to start."
echo "================================================"
```

#### `bin/pibox` (Заглушка для Задачи 4)
Создайте этот файл в исходниках, чтобы установщик мог его скопировать.
```bash
#!/usr/bin/env bash
# Заглушка CLI. Реализация подкоманд и docker run будет в Задаче 4.
echo "🚀 PIBOX CLI invoked!"
echo "Current directory: $(pwd)"
echo "Arguments: $@"
echo "(This is a stub. Docker orchestration goes here.)"
```

#### `env/models.json` (Заглушка для Задачи 5)
Базовый шаблон для копирования.
```json
{
  "models": [
    {
      "name": "local-model",
      "endpoint": "http://host.docker.internal:8080/v1",
      "api_key": "YOUR_API_KEY_HERE"
    }
  ]
}
```

---

### 🧪 3. Инструкция по тестированию

1. **Сделайте `install.sh` исполняемым:**
   ```bash
   chmod +x install.sh
   ```
2. **Запустите установку:**
   ```bash
   ./install.sh
   ```
   *Вы должны увидеть логи о создании директорий, синхронизации шаблонов и добавлении пути в `.bashrc`/`.zshrc`.*
3. **Примените изменения PATH:**
   ```bash
   source ~/.bashrc  # или source ~/.zshrc
   ```
4. **Проверьте структуру установки:**
   ```bash
   tree -a ~/pibox
   ```
   *Ожидаемый результат:* Вы должны увидеть `bin/pibox`, `env/models.json`, `env-template/` и скопированный `env/default/`.
5. **Проверьте работу CLI:**
   Перейдите в любую директорию (например, `cd /tmp`) и выполните:
   ```bash
   pibox --help
   ```
   *Должен сработать скрипт-заглушка, подтверждая, что бинарник успешно найден в `PATH`.*
   