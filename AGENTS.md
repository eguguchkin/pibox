# AGENTS.md — инструкции для агента

## Описание проекта

Полное описание проекта PIBOX (что это, архитектура, контракты компонентов,
как тестировать, подводные камни) — см. **[docs/PROJECT.md](docs/PROJECT.md)**.
Читай его перед началом работы.

## Быстрые факты

- PIBOX — запуск Pi Coding Agent в изолированном Docker-контейнере с персистентными окружениями.
- Основные файлы: `docker/` (build-контекст: `Dockerfile` — pi + pi-web-ui в /usr/local, `entrypoint.sh`, `webui.sh` — лаунчер web-ui, `.dockerignore`), `bin/pibox` + `lib/` (CLI), `install.sh`, `template/` (двухслойный шаблон: `common` — продукт, `user` — личные инварианты).
- Проверки: `./tests/smoke.sh` (полный — на хосте с docker; внутри контейнера — `./tests/smoke.sh --no-docker`, см. [docs/TESTS.md](docs/TESTS.md)) и `shellcheck install.sh docker/entrypoint.sh docker/webui.sh bin/pibox lib/*.sh tests/*.sh`.
- Скрипты — bash, только LF-окончания.

## Соглашения по коду

- Shell-скрипты: строгий стиль, совместимый с shellcheck (без warnings).
- Версии зависимостей пинуются в ARG docker/Dockerfile; смена версий фиксируется в docs.
