#!/usr/bin/env bash
# ============================================================================
# PIBOX webui — лаунчер pi-web-ui внутри контейнера.
#
# Запускается как команда контейнера из `pibox webui` (CMD-override: webui):
# печатает зелёную строку со ссылкой на интерфейс и exec'ит сервер в
# foreground — дальше в консоль идут штатные логи pi-web-ui и агента,
# Ctrl+C останавливает контейнер.
#
# Контракт с lib/cmd-webui.sh (CLI pibox):
#   WEBUI_HOST_PORT — хост-порт для ссылки (pibox пробрасывает через -e).
# Переменные pi-web-ui (пробрасываются -E / --env-file):
#   PI_WEB_PORT  — контейнерный порт (по умолчанию 8787);
#   PI_WEB_TOKEN — общий секрет (обязателен при публикации порта в LAN).
# ============================================================================
set -euo pipefail

readonly PORT="${PI_WEB_PORT:-8787}"

# Контрольный сокет pi-web-ui лежит в персистентном ~/.pi-web (bind-mount
# хоста), поэтому сокет от убитого (kill -9 / docker kill) запуска переживает
# рестарт контейнера. pi-web-ui пробует удалить его сам (best-effort), но на
# macOS/virtiofs это может молча не пройти, а bind тогда даёт
# «[control] socket error: listen EACCES» — сервер стартует без control-API
# (status/quiesce). Подчищаем заранее; если удалить не удалось — это симптом
# другого владельца файла (env переносили между машинами с другим UID) или
# чужого живого контейнера с тем же env: предупреждаем с подсказкой.
readonly CONTROL_SOCK="${PI_WEB_DATA_DIR:-$HOME/.pi-web}/pi-web-ui.sock"
if [ -e "$CONTROL_SOCK" ]; then
    rm -f -- "$CONTROL_SOCK" 2>/dev/null || true
    if [ -e "$CONTROL_SOCK" ]; then
        # virtiofs (macOS): удаление события может отставать — даём время,
        # иначе pi-web-ui успеет сделать bind по ещё живой записи.
        sleep 0.2
    fi
    if [ -e "$CONTROL_SOCK" ]; then
        printf '\033[33m\r\n  ⚠  не удалось удалить контрольный сокет %s — control-API будет недоступен.\r\n     На хосте: rm -f %s  (или chown -R, если env переносился между машинами с другим UID)\r\n\033[0m' \
            "$CONTROL_SOCK" "$CONTROL_SOCK"
    fi
fi

# Зелёная строка со ссылкой. \r\n: docker run -t переводит хостовый TTY в
# raw-режим (ONLCR отключён) — «голый» \n даёт съехавшие отступы, как в
# entrypoint.sh. Токен из PI_WEB_TOKEN подставляем в query (только URL-safe —
# иначе страницу авторизовать вручную).
readonly URL="http://localhost:${WEBUI_HOST_PORT:-$PORT}"
if [ -n "${PI_WEB_TOKEN:-}" ] && printf '%s' "$PI_WEB_TOKEN" | grep -qE '^[A-Za-z0-9._~+-]+$'; then
    printf '\033[32m  ➜  web-ui: %s/?token=%s\033[0m\r\n' "$URL" "$PI_WEB_TOKEN"
else
    printf '\033[32m  ➜  web-ui: %s\033[0m\r\n' "$URL"
fi

exec pi-web-ui --no-browser --host 0.0.0.0 --port "$PORT"
