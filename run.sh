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
