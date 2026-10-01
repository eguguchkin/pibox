#!/usr/bin/env bash
# pi-telegram-bridge — RPC-демон pi с автоподключением Telegram-моста (@llblab/pi-telegram).
#
# Режимы:
#   run      — foreground (команда контейнера для `pibox tg`): держатель stdin,
#              pi RPC в фоне, /telegram-connect, ожидание; TERM/INT = остановка
#   start    — фоновый демон (вручную или из entrypoint, см. контракт ниже)
#   stop     — остановить
#   status   — статус + последние события
#   connect  — заново отправить /telegram-connect в работающий демон
#
# Токен бота должен быть уже сохранён в ~/.pi/agent/telegram.json
# (шаблон — template/user/.pi/agent/telegram.json в user-слое pibox;
# разовая настройка: pi → /telegram-setup).
#
# Переменные окружения:
#   PIBOX_BRIDGE_DIR   — рабочий каталог сессии pi (по умолчанию ~/workspace/pibox)
#   PIBOX_BRIDGE_DELAY — задержка перед /telegram-connect, сек (по умолчанию 8)
#
# Контракт с docker/entrypoint.sh: при CMD-команде «pi-telegram-bridge»
# (режим `pibox tg`) entrypoint НЕ запускает фоновый автостарт — мост здесь
# сам является командой контейнера.
#
# Нюанс: argv[0] у pi переписан (cmdline = "pi"), поэтому живость демона
# проверяется по fd/1 — его stdout перенаправлен в наш журнал RPC-событий.
set -euo pipefail

STATE_DIR="${HOME}/.local/state/pi-bridge"
WORKDIR="${PIBOX_BRIDGE_DIR:-${HOME}/workspace/pibox}"
DELAY="${PIBOX_BRIDGE_DELAY:-8}"
TAKEOVER_WAIT="${PIBOX_BRIDGE_TAKEOVER_WAIT:-12}"
FIFO="${STATE_DIR}/rpc-stdin"
OUT_LOG="${STATE_DIR}/rpc-out.jsonl"
ERR_LOG="${STATE_DIR}/rpc-err.log"
PID_FILE="${STATE_DIR}/pi.pid"
HOLDER_FILE="${STATE_DIR}/holder.pid"

# Проверки перед запуском: рабочий каталог и настроенный токен.
# Заглушка из user-слоя («REPLACE_ME») отсекается sanity-regex токена.
check_prereqs() {
    [[ -d "$WORKDIR" ]] || {
        echo "нет каталога: $WORKDIR (задай PIBOX_BRIDGE_DIR)"
        return 1
    }
    local cfg="${HOME}/.pi/agent/telegram.json"
    [[ -f "$cfg" ]] || {
        echo "нет ${cfg} — настрой мост одним из способов:"
        echo "  1) pi → /telegram-setup (вставить токен из @BotFather)"
        echo "  2) заполнить template/user/.pi/agent/telegram.json (user-слой pibox)"
        return 1
    }
    local token
    token="$(jq -r '.profiles.default.botToken // empty' "$cfg")"
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{6,}$ ]] || {
        echo "токен в ${cfg} не похож на валидный (заглушка REPLACE_ME?) —"
        echo "шаблон с инструкцией: template/user/.pi/agent/telegram.json.example"
        return 1
    }
    # allowedUserId: отсутствует — подсказка про строгое владение; заведомо
    # мёртвое значение (0/мусор) — отказ: llblab молча отвергает всех, и бот
    # выглядит «включённым», но не отвечает никому.
    local uid
    uid="$(jq -r '.profiles.default.allowedUserId // empty' "$cfg")"
    if [ -z "$uid" ]; then
        echo "подсказка: allowedUserId не задан — владельцем бота станет первый,"
        echo "  кто напишет /start. Для строгого владения впишите свой числовой Id"
        echo "  (узнать: @userinfobot) в ${cfg}"
    elif ! [[ "$uid" =~ ^[1-9][0-9]*$ ]]; then
        echo "allowedUserId='$uid' в ${cfg} не годится: llblab будет молча"
        echo "  отвергать всех. Впишите свой числовой Id (узнать: @userinfobot)"
        echo "  или удалите поле — шаблон: telegram.json.example"
        return 1
    fi
}

# fifo + держатель конца записи (не даёт rpc-ридеру увидеть EOF).
prepare_fifo() {
    mkdir -p "$STATE_DIR"
    # Хвост прошлого демона (после крэша контейнера): гасим осиротевший
    # держатель, иначе на каждый цикл крэш→старт накапливаются висяки.
    if holder_alive; then
        kill "$(cat "$HOLDER_FILE")" 2>/dev/null || true
    fi
    rm -f "$FIFO"
    mkfifo "$FIFO"
    (exec sleep infinity >"$FIFO") &
    echo "$!" >"$HOLDER_FILE"
}

# Жив ли pi-демон из pidfile: пид существует и его stdout — наш журнал событий
# (cmdline у pi переписан, по нему отличить демона от чужого процесса нельзя).
daemon_alive() {
    local pid
    [[ -f "$PID_FILE" ]] || return 1
    pid="$(cat "$PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local out
    out="$(readlink "/proc/$pid/fd/1" 2>/dev/null)"
    out="${out% (deleted)}" # после rm+recreate лога fd помечается «(deleted)»
    [ "$out" = "$OUT_LOG" ]
}

# Жив ли держатель fifo (cmdline у sleep не переписан — grep по нему честный).
holder_alive() {
    local pid
    [[ -f "$HOLDER_FILE" ]] || return 1
    pid="$(cat "$HOLDER_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q "sleep infinity"
}

# Ответить confirmed:true на единственный автостартовый диалог — тейковер
# singleton-lock («move singleton lock here?»): возникает, когда прошлый
# запуск контейнера убили без graceful-остановки. Следит за новыми строками
# журнала с позиции $1 (байтовый офсет) до TAKEOVER_WAIT секунд, ответ
# пишет в fifo.
answer_stale_takeover() {
    python3 - "$OUT_LOG" "$1" "$FIFO" "$TAKEOVER_WAIT" <<'PY'
import json, sys, time
path, since, fifo, wait = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
deadline = time.time() + wait
while time.time() < deadline:
    try:
        with open(path, "rb") as f:
            f.seek(since)
            for raw in f:
                try:
                    e = json.loads(raw)
                except ValueError:
                    continue
                if (e.get("type") == "extension_ui_request"
                        and e.get("method") == "confirm"
                        and "move singleton lock" in (e.get("message") or "")):
                    with open(fifo, "w") as out:
                        out.write(json.dumps({
                            "type": "extension_ui_response",
                            "id": e["id"],
                            "confirmed": True,
                        }) + "\n")
                    print("подтверждён тейковер singleton-lock (stale lock после крэша)")
                    sys.exit(0)
    except FileNotFoundError:
        pass
    time.sleep(0.5)
sys.exit(0)
PY
}

# Подключить мост: офсет журнала → /telegram-connect в fifo → автоответ
# на тейковер, если llblab его запросил.
connect_bridge() {
    local offset
    offset="$(wc -c <"$OUT_LOG")"
    printf '{"id":"boot-%s","type":"prompt","message":"/telegram-connect"}\n' "$(date +%s)" >"$FIFO"
    echo "→ /telegram-connect отправлен"
    answer_stale_takeover "$offset" || true
}

# Остановить демона и держатель (для stop и для trap в run).
shutdown() {
    if daemon_alive; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    if holder_alive; then
        kill "$(cat "$HOLDER_FILE")" 2>/dev/null || true
    fi
    rm -f "$FIFO" "$PID_FILE" "$HOLDER_FILE"
}

# SOCKS5-прокси для Telegram (PIBOX_TELEGRAM_PROXY, например
# socks5h://user:pass@host:port): llblab ходит в Telegram через сырой
# https.request мимо HTTP(S)_PROXY, поэтому подключаем preload-хук,
# заворачивающий запросы к *.telegram.org через socks-proxy-agent.
# Модуль ищем в запечённом в образ каталоге и в персистентном $HOME.
setup_socks_proxy() {
    [ -n "${PIBOX_TELEGRAM_PROXY:-}" ] || return 0
    local preload="" moddir="" c d
    for c in /usr/local/lib/pi-telegram/socks-preload.cjs \
        "$HOME/.local/pi-socks/socks-preload.cjs"; do
        [ -f "$c" ] && preload="$c" && break
    done
    for d in /usr/local/lib/pi-socks/node_modules \
        "$HOME/.local/pi-socks/node_modules"; do
        [ -d "$d/socks-proxy-agent" ] && moddir="$d" && break
    done
    if [ -z "$preload" ] || [ -z "$moddir" ]; then
        echo "PIBOX_TELEGRAM_PROXY задан, но preload/socks-proxy-agent не найдены —" \
            "запросы пойдут напрямую (Telegram может быть недоступен)" >&2
        return 0
    fi
    export PIBOX_SOCKS_URL="$PIBOX_TELEGRAM_PROXY"
    export NODE_PATH="${NODE_PATH:+$NODE_PATH:}$moddir"
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require $preload"
    echo "→ Telegram через SOCKS5-прокси"
}

# --- run: foreground (команда контейнера `pibox tg`) ----------------------------

run() {
    check_prereqs
    if daemon_alive; then
        echo "фоновый демон уже запущен (pid $(cat "$PID_FILE")) — сначала pi-telegram-bridge stop"
        return 1
    fi
    prepare_fifo
    setup_socks_proxy
    cd "$WORKDIR"
    pi --mode rpc --continue <"$FIFO" >>"$OUT_LOG" 2>>"$ERR_LOG" &
    echo "$!" >"$PID_FILE"
    local daemon_pid
    daemon_pid="$(cat "$PID_FILE")"
    echo "pi RPC запущен (pid ${daemon_pid}, cwd ${WORKDIR}), инициализация ${DELAY}s..."
    sleep "$DELAY"
    connect_bridge
    echo "мост работает; логи: ${OUT_LOG} (Ctrl+C — остановка)"
    trap 'shutdown; exit 143' INT TERM
    wait "$daemon_pid"
}

# --- start: фоновый демон (вручную или из entrypoint) ---------------------------

start() {
    if daemon_alive; then
        echo "уже запущен: pid $(cat "$PID_FILE")"
        return 0
    fi
    check_prereqs
    prepare_fifo
    setup_socks_proxy
    cd "$WORKDIR"
    nohup pi --mode rpc --continue <"$FIFO" >>"$OUT_LOG" 2>>"$ERR_LOG" &
    echo "$!" >"$PID_FILE"
    echo "pi RPC запущен (pid $(cat "$PID_FILE")), инициализация ${DELAY}s..."
    sleep "$DELAY"
    connect_bridge
    echo "логи: ${OUT_LOG}"
}

stop() {
    local rc=0
    if daemon_alive; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        echo "остановлен: pid $(cat "$PID_FILE")"
    else
        echo "не запущен"
        rc=1
    fi
    if holder_alive; then
        kill "$(cat "$HOLDER_FILE")" 2>/dev/null || true
    fi
    rm -f "$FIFO" "$PID_FILE" "$HOLDER_FILE"
    return "$rc"
}

status() {
    if daemon_alive; then
        echo "демон: работает (pid $(cat "$PID_FILE")), cwd=${WORKDIR}"
    else
        echo "демон: не запущен"
    fi
    if [[ -s "$OUT_LOG" ]]; then
        echo "--- последний статус Telegram:"
        python3 -c "
import json
last = ''
for line in open('$OUT_LOG'):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get('method') == 'setStatus' and e.get('statusKey') == 'telegram':
        last = e.get('statusText', '')
print(' ', last or '(нет)')" 2>/dev/null || true
        echo "--- последние notify:"
        rg '"method":"notify"' "$OUT_LOG" | tail -3 |
            python3 -c "import sys,json; [print('  -', json.loads(l)['message'].splitlines()[0][:120]) for l in sys.stdin]" 2>/dev/null || true
    fi
}

connect() {
    if ! daemon_alive; then
        echo "демон не запущен"
        return 1
    fi
    connect_bridge
}

case "${1:-}" in
run) run ;;
start) start ;;
stop) stop ;;
status) status ;;
connect) connect ;;
*)
    echo "usage: $0 {run|start|stop|status|connect}"
    echo "  run      — foreground (команда контейнера pibox tg)"
    echo "  start    — фоновый демон (вручную или автостарт entrypoint)"
    echo "  stop     — остановить демона и держатель fifo"
    echo "  status   — состояние + последние события моста"
    echo "  connect  — повторно отправить /telegram-connect"
    exit 2
    ;;
esac
