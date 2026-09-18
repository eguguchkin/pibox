# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Основной блок --------------------------------------------------------------

main() {
    # Если первый аргумент не опция, то это подкоманда
    local SUBCOMMAND
    if [[ $# -gt 0 && "$1" != -* ]]; then
        SUBCOMMAND="$1"
        shift
    else
        SUBCOMMAND="run"
    fi

    # Вызов соответствующей подкоманды
    case "$SUBCOMMAND" in
    run)
        cmd_run "$@"
        ;;
    build)
        cmd_build "$@"
        ;;
    env)
        cmd_env "$@"
        ;;
    shell)
        cmd_shell "$@"
        ;;
    update)
        cmd_update "$@"
        ;;
    doctor)
        cmd_doctor "$@"
        ;;
    extensions)
        cmd_extensions "$@"
        ;;
    *)
        err "Неизвестная подкоманда: $SUBCOMMAND"
        usage
        exit 1
        ;;
    esac
}
