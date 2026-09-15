---
name: install-languages
description: Установка языков и тулчейнов в контейнере pibox — через mise (глобально в окружение или в проект) и локально в $HOME (npm, pip/venv). Использовать всегда, когда нужно поставить компилятор, интерпретатор, CLI-тул или библиотеку.
---

# Установка языков и тулчейнов в pibox

Контейнер персистентен только в `$HOME` (=`/home/pi`) и `/home/pi/workspace`.
Системные каталоги (`/usr`, `/etc`) сбрасываются при перезапуске — ничего важного
туда не ставить. Root и sudo недоступны (агент работает от `pi` = хост-юзер).

## Порядок выбора способа

1. **Язык/версия/компилятор** (go, php, rust, python X.Y, java, node X, gcc…) → **mise**.
2. **CLI на Node** (типа `typescript`, `eslint`, `prettier`) → **npm global** с prefix `~/.local`.
3. **Python-библиотеки** → **venv в проекте** (системный pip заблокирован PEP 668).
4. **`apt install` — НЕ ДОСТУПЕН** (нет root). Если задача без apt не решается — сказать пользователю.

## 1. mise — основной способ

Шимы уже на PATH (`~/.local/share/mise/shims`), `mise activate` прописан в `~/.bashrc`.

```bash
# глобально в ОКРУЖЕНИЕ (переживает перезапуск, видно во всех проектах этого env):
mise use -g go@latest
mise use -g php@8.3 rust@stable python@3.12

# для ПРОЕКТА (создаёт mise.toml в cwd — версия фиксируется для всей команды):
cd /home/pi/workspace && mise use go@1.22

# диагностика:
mise ls          # что установлено
mise which go    # откуда берётся бинарник
```

После установки — всегда верифицировать: `go version && which go`.

Первый `mise use` качает тулчейн из сети (~50–200 МБ) — это норма, занимает минуты.

## 2. npm — глобальные пакеты без sudo

```bash
npm config get prefix     # должен быть /home/pi/.local
# если нет или при EACCES:
npm config set prefix ~/.local
npm install -g typescript
tsc -v                    # бинарник попадёт в ~/.local/bin (уже на PATH)
```

## 3. Python — только через venv (PEP 668)

`pip install` в системный python падает (`externally-managed-environment`) — это не баг:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install requests
```

Нужна другая версия Python целиком → mise: `mise use -g python@3.11`.

## Персистентность (главное)

- mise-тулчейны: `~/.local/share/mise/` — живут в окружении навсегда.
- npm -g: `~/.local/lib/node_modules` — то же.
- venv: внутри проекта (workspace) — живёт с проектом.
- Всё, что поставлено вне `$HOME`/workspace, исчезнет при следующем запуске.
- Окружения изолированы: go, поставленный в env `default`, не виден в env `php8`.
