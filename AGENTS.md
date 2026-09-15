# AGENTS.md — инструкции для агента

## Описание проекта

Полное описание проекта PIBOX (что это, архитектура, контракты компонентов,
как тестировать, подводные камни) — см. **[docs/PROJECT.md](docs/PROJECT.md)**.
Читай его перед началом работы.

## Быстрые факты

- PIBOX — запуск Pi Coding Agent в изолированном Docker-контейнере с персистентными окружениями.
- Основные файлы: `Dockerfile`, `entrypoint.sh`, `run.sh` (CLI `pibox`), `install.sh`, `env/.template/`.
- Проверки: `./tests/smoke.sh` и `shellcheck run.sh install.sh entrypoint.sh tests/smoke.sh`.
- Скрипты — bash, только LF-окончания.
- Существующие окружения пользователей (`~/pibox/env/*`) не затрагивать.

## Соглашения по коду

- Shell-скрипты: строгий стиль, совместимый с shellcheck (без warnings).
- Версии зависимостей пинуются в ARG Dockerfile; смена версий фиксируется в docs.
