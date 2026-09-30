// socks-preload.cjs — Node preload: завернуть HTTPS к *.telegram.org через SOCKS5.
// Подключается NODE_OPTIONS="--require <этот файл>" (см. pi-telegram-bridge.sh).
// Прокси задаётся переменной окружения PIBOX_SOCKS_URL, например:
//   PIBOX_SOCKS_URL=socks5h://proxyuser:pass@88.218.64.103:1080
// (socks5h = DNS тоже через прокси). Область действия: ТОЛЬКО хосты
// *.telegram.org — остальные запросы pi (LLM API, web) идут напрямую.
"use strict";

const PROXY_URL = process.env.PIBOX_SOCKS_URL;
if (PROXY_URL) {
    const { SocksProxyAgent } = require("socks-proxy-agent");
    const agent = new SocksProxyAgent(PROXY_URL);
    const https = require("node:https");

    const isTelegram = (host) =>
        typeof host === "string" && /(^|\.)telegram\.org$/i.test(host);
    const isPlainOptions = (v) =>
        !!v && typeof v === "object" && !(v instanceof URL) && typeof v !== "function";

    const withAgent = (opts) => ({ ...opts, agent });

    const origRequest = https.request;
    https.request = function patchedRequest(...args) {
        const first = args[0];
        if (typeof first === "string" || first instanceof URL) {
            let host = "";
            try {
                host = new URL(first).hostname;
            } catch {
                host = "";
            }
            if (isTelegram(host)) {
                // https.request(url[, options][, cb]) → вставляем/дополняем options
                const rest = args.slice(1);
                if (isPlainOptions(rest[0])) {
                    return origRequest.apply(this, [first, withAgent(rest[0]), ...rest.slice(1)]);
                }
                return origRequest.apply(this, [first, withAgent({}), ...rest]);
            }
            return origRequest.apply(this, args);
        }
        if (isPlainOptions(first)) {
            const host = first.host || first.hostname || "";
            if (isTelegram(host) && !first.agent) {
                return origRequest.apply(this, [withAgent(first), ...args.slice(1)]);
            }
        }
        return origRequest.apply(this, args);
    };
    // https.get держит локальный биндинг на module-внутренний request —
    // патчить нужно и его, иначе get() идёт мимо прокси (проверено: hangs
    // на drop-фаерволе). Семантика: request(...) + req.end().
    https.get = function patchedGet(...args) {
        const req = https.request(...args);
        req.end();
        return req;
    };
    // https.get строится на https.request — патчить не нужно.
}
