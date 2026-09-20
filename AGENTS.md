# AGENTS.md — инструкции для агента

## Описание проекта

Полное описание проекта PIBOX (что это, архитектура, контракты компонентов,
как тестировать, подводные камни) — см. **[docs/PROJECT.md](docs/PROJECT.md)**.
Читай его перед началом работы.

## Быстрые факты

- PIBOX — запуск Pi Coding Agent в изолированном Docker-контейнере с персистентными окружениями.
- Основные файлы: `Dockerfile` (pi + pi-web-ui в /usr/local), `entrypoint.sh`, `webui.sh` (лаунчер web-ui), `bin/pibox` + `lib/` (CLI), `install.sh`, `env/.template/`.
- Проверки: `./tests/smoke.sh` и `shellcheck install.sh entrypoint.sh webui.sh bin/pibox lib/*.sh tests/*.sh`.
- Скрипты — bash, только LF-окончания.
- Существующие окружения пользователей (`~/pibox/env/*`) не затрагивать.

## Соглашения по коду

- Shell-скрипты: строгий стиль, совместимый с shellcheck (без warnings).
- Версии зависимостей пинуются в ARG Dockerfile; смена версий фиксируется в docs.
