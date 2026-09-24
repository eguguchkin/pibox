# shellcheck shell=bash disable=SC2034  # переменные общие между модулями (после source)
# --- Подкоманда user: слои template/user ------------------------------------------

cmd_user() {
    local env_name="$DEFAULT_ENV"
    local subcmd="${1:-}"

    if [[ "$subcmd" == "-e" || "$subcmd" == "--env" ]]; then
        # pibox user -e NAME push|pull
        [[ $# -ge 3 ]] || die "Опция -e требует имя окружения и подкоманду: pibox user -e NAME push|pull"
        env_name="$2"
        subcmd="$3"
        shift 3
    else
        [[ -n "$subcmd" ]] || {
            usage
            exit 1
        }
        shift
    fi

    # pibox user push|pull -e NAME [PATH…] — -e может стоять и после;
    # ${1:-} — под set -u при отсутствии аргументов $1 «не существует»
    if [[ "${1:-}" == "-e" || "${1:-}" == "--env" ]]; then
        [[ $# -ge 2 ]] || die "Опция -e требует имя окружения: pibox user pull -e NAME"
        env_name="$2"
        shift 2
    fi

    validate_env_name "$env_name"

    case "$subcmd" in
    push)
        user_push "$env_name"
        ;;
    pull)
        user_pull "$env_name" "$@"
        ;;
    -h | --help | help)
        usage
        ;;
    *)
        err "Неизвестная подкоманда user: $subcmd (доступны: push, pull)"
        usage
        exit 1
        ;;
    esac
}
