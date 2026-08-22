# bash completion for macon. Source this from your profile:
#     . /path/to/macon/completions/macon.bash
#
# Not installed by install.sh -- it writes only to the prefix, and a completion
# belongs to a shell's configuration rather than to the tool.

_macon() {
    local cur prev cmd
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cmd=${COMP_WORDS[1]}

    local subcommands='on run off done status report saved log failsafe version help'
    local on_opts='--max --on-expire --extend-by --busy-check
                   --hook-end --hook-warn --pre-warn --interval
                   --allow-battery --no-failsafe --no-announce --quiet'

    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "$subcommands" -- "$cur")
        return
    fi

    # Options that take a value the shell cannot guess: offer nothing rather
    # than offering filenames for a duration.
    case $prev in
        --on-expire)
            mapfile -t COMPREPLY < <(compgen -W 'restore extend' -- "$cur")
            return
            ;;
        --max | --extend-by | --pre-warn | --interval | --busy-check | \
        --hook-end | --hook-warn | --grace)
            return
            ;;
        --out | --session | --since)
            mapfile -t COMPREPLY < <(compgen -f -- "$cur")
            return
            ;;
    esac

    case $cmd in
        on | run)
            mapfile -t COMPREPLY < <(compgen -W "$on_opts" -- "$cur")
            ;;
        report)
            mapfile -t COMPREPLY < <(compgen -W '--out --since --session' -- "$cur")
            ;;
        log)
            mapfile -t COMPREPLY < <(compgen -W '--session' -- "$cur")
            ;;
        done)
            mapfile -t COMPREPLY < <(compgen -W '--grace' -- "$cur")
            ;;
        failsafe)
            mapfile -t COMPREPLY < <(compgen -W 'install remove status' -- "$cur")
            ;;
        off | status | saved | version | help)
            ;;
    esac
}

complete -F _macon macon
