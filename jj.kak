# Jujutsu - https://jj-vcs.github.io/jj/latest/

hook -group jj-diff-highlight global WinSetOption filetype=jj-diff %{
    require-module diff
    add-highlighter window/jj-diff-ref-diff ref diff
    hook -once -always window WinSetOption filetype=.* %{
        remove-highlighter window/jj-diff-ref-diff
    }
}

hook global WinSetOption filetype=jj-diff %{
    map buffer normal <ret> %{:jj-diff-goto-source<ret>} -docstring 'Jump to source from jj diff'
    hook -once -always window WinSetOption filetype=.* %{
        unmap buffer normal <ret> %{:jj-diff-goto-source<ret>}
    }
}

define-command -hidden -docstring %{
    call diff-jump with the jj workspace root
} jj-diff-goto-source %{
    require-module diff
    diff-jump %sh{ jj workspace root }
}

declare-option -hidden -docstring %{
    whether to suppress output of successful jj commands
} bool jj_silent false

define-command jj -params 0.. -docstring %{
    jj [<arguments>]: wrapper for the Jujutsu version control system CLI
    All optional arguments are forwarded to the jj utility.
    See ':doc jj' for help.
} %{ evaluate-commands %sh{
    kakquote() {
        printf "%s" "$1" | sed "s/'/''/g; 1s/^/'/; \$s/\$/'/"
    }

    shell() {
        echo ${KAKOUNE_POSIX_SHELL:-/bin/sh}
    }

    check_output() {
        local buffered_error=/dev/null
        if ! $INPARAM_combine_output; then
            buffered_error=$(mktemp "${TMPDIR:-/tmp}"/kak-jj-error.XXXXXXXX)
        fi
        OUTPARAM_jj_output=$(
            if $INPARAM_combine_output; then
                "$@" 2>&1
            else
                "$@" 2>"$buffered_error"
            fi
            local status=$?
            printf .
            exit $status
        )
        local status=$?
        OUTPARAM_jj_output=${OUTPARAM_jj_output%.}

        if [ $status -ne 0 ] || ! $INPARAM_silent; then
            echo 'echo -debug <<<'
            printf 'echo -debug $'
            for arg; do
                printf ' %s' "$(kakquote "$arg")"
            done
            printf '\n'
            echo "echo -debug -- $(kakquote "$OUTPARAM_jj_output$(cat "$buffered_error")")"
            echo 'echo -debug >>>'
        fi

        if [ $status -ne 0 ]; then
            echo "fail $(kakquote "failed to run $*, see the *debug* buffer")"
            return 1
        fi
    }

    jj_with_transient_output() {
        local silent=${kak_opt_jj_silent}
        INPARAM_combine_output=true INPARAM_silent=$silent check_output jj --color=auto "$@"
        status=$?
        if [ $status -eq 0 ] && ! $silent; then
            echo info -title "$(kakquote "\$ jj $*")" -- "$(kakquote "$OUTPARAM_jj_output")"
        fi
        return $status
    }

    jj_with_buffer_output() {
        local output=$(mktemp -d "${TMPDIR:-/tmp}"/kak-jj.XXXXXXXX)/fifo
        mkfifo ${output}
        # Hack-ish: if the kak-ansi plugin is installed, turn on colors by default.
        # If jj prints invalid UTF-8, this might truncate the output.
        # NOTE: going forward, we should probably require an 'ansi' module.
        local color=
        local render_colors=
        if [ -n "${kak_opt_ansi_filter}" ]; then
            color=--color=always
            render_colors='
                ansi-enable
                # Undo the cursor-movement after the initial ansi-render.
                hook -once buffer BufReadFifo .* %exp{
                    execute-keys -client %val{client} gk
                }
            '
        fi
        (
            trap - INT QUIT
            jj $color "$@" >${output} 2>&1 &
        ) >/dev/null 2>&1 </dev/null
        printf %s "
            evaluate-commands -try-client '${kak_opt_docsclient}' '
                edit! -fifo ${output} *jj*
                $render_colors
                set-option buffer filetype %{${INPARAM_filetype}}
                hook -always -once buffer BufCloseFifo .* ''
                    nop %sh{ rm -r $(dirname ${output}) }
                    ${INPARAM_onclose}
                ''
            '
        "
    }

    jj_with_editor() {
        # Make sure we generate a safe file name.
        if ! printf %s "$1" | grep -q '^[a-z-]*$'; then
            echo fail unexpected command "$(kakquote "$1")"
            exit
        fi
        local tmpfile=$(mktemp "${TMPDIR:-/tmp}"/kak-jj-$1.XXXXXXXX)
        if ! JJ_EDITOR=cat INPARAM_combine_output=false INPARAM_silent=true \
            check_output jj "$@"
        then
            return
        fi
        printf %s "$OUTPARAM_jj_output" >$tmpfile
        printf %s "
            edit $tmpfile
            declare-option str-list jj_with_editor_args %arg{@}
            hook buffer BufWritePost .* %{
                evaluate-commands %{
                    set-option local jj_silent true
                    jj __with_predetermined_edit $tmpfile %opt{jj_with_editor_args}
                }
            }
            hook buffer BufClose .* %{ nop %sh{ rm -f $tmpfile } }
        "
    }

    jj_with_predetermined_edit() {
        local tmpfile=$2
        shift 2
        JJ_EDITOR="cp $tmpfile" jj_with_transient_output "$@"
    }

    jj_with_editor_async() {
        if ! fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/kak-jj-editor-XXXXXX") ||
            ! mkfifo "${fifo_dir}/response_fifo"
        then
            echo "fail %{failed to set up fifo for editor, see *debug* buffer}"
            [ -n "${fifo_dir}" ] && rmdir "${fifo_dir}"
            exit 1
        fi
        {
            trap 'rm -r "${fifo_dir}"' EXIT
            escape2() { printf %s "$*" | sed "s/'/''''/g"; }
            export JJ_EDITOR="$(git rev-parse --sq-quote \
                "${KAKOUNE_POSIX_SHELL:-/bin/sh}" \
                "${kak_runtime}/rc/tools/blocking-editor-in-client" \
                "${fifo_dir}" "${kak_session}" "${kak_client}")"
            failed=false
            if err=$(jj "$@" 2>&1); then
                exit
            elif [ -f "${fifo_dir}/cancelled" ]; then
                cmd="eval -try-client ${kak_client} %{
                    echo -markup '{Information}Cancelled'
                }"
            else
                cmd="eval -try-client ${kak_client} '
                    try %{
                        edit! -fifo $(kakquote "${fifo_dir}/response_fifo") ''*git-commit*''
                    }
                    echo -markup ''{Error}{\\}failed to run $(escape2 jj "$@")''
                '"
                failed=true
            fi
            printf %s "${cmd}" | kak -p "${kak_session}"
            if [ ${failed} = true ]; then
                printf %s "$err" >"${fifo_dir}/response_fifo"
            fi
        } >/dev/null 2>&1 </dev/null &
    }

    jj_bookmark() {
        case "$2" in
            (list | l) jj_with_buffer_output "$@" ;;
            (*) jj_with_transient_output "$@" ;;
        esac
    }

    jj_commit() {
        if JJ_EDITOR=true jj_with_transient_output "$@"; then
            echo 'jj describe @-'
        fi
    }

    jj_describe() {
        if printf %s\\n "$@" | grep -qE '^(--message(=|$)|-m)'; then
            jj_with_transient_output "$@"
            return
        fi
        jj_with_editor "$@"
        echo 'set-option buffer filetype jj-describe'
    }

    jj_file() {
        case "$2" in
            (list | show) jj_with_buffer_output "$@" ;;
            (*) jj_with_transient_output "$@" ;;
        esac
    }

    jj_operation() {
        case "$2" in
            (diff | log | show) jj_with_buffer_output "$@" ;;
            (*) jj_with_transient_output "$@" ;;
        esac
    }

    jj_show_or_diff() {
        INPARAM_filetype=$(
            if printf %s\\n "$@" | grep -Fxq -- --git; then
                echo git-diff
            else
                echo jj-diff
            fi
        )
        jj_with_buffer_output "$@"
    }

    jj_show() {
        INPARAM_onclose='execute-keys -draft gkxs^Commit<space>ID:<ret>ccommit'
        jj_show_or_diff "$@"
    }

    jj_sparse() {
        case "$2" in
            (edit) jj_with_editor "$@" ;;
            (list) jj_with_buffer_output "$@" ;;
            (*) jj_with_transient_output "$@" ;;
        esac
    }

    jj_split() {
        local parallel=false
        local has_fileset_argument=false
        local seen_ddash=false
        shift
        for arg; do
            if $seen_ddash; then
                has_fileset_argument=true
                break
            fi
            case "$arg" in
                (--)
                    seen_ddash=true
                    ;;
                (-p | --parallel)
                    parallel=true
                    ;;
                (-*)
                    echo "fail -- jj split: unsupported argument $(kakquote "$arg")"
                    ;;
                (*)
                    has_fileset_argument=true
                    break
                    ;;
            esac
        done
        # undo shift
        set -- split "$@"
        if $has_fileset_argument; then
            jj_with_transient_output "$@"
            return
        fi
        if [ ${kak_selection_count} -ne 1 ]; then
            echo 'evaluate-commands -verbatim -itersel jj %arg{@}'
            return
        fi
        echo >${kak_command_fifo} "
            evaluate-commands -draft %{
                try %{
                    execute-keys %{<a-/>^(?:commit|Change ID:) \S+<ret>}
                    execute-keys %{1s^(?:commit|Change ID:) (\S+)<ret>}
                    echo -to-file ${kak_response_fifo} -- %val{selection}
                } catch %{
                    # assume we're splitting the working copy commit
                    echo -to-file ${kak_response_fifo} @
                }
            }
        "
        local revision=$(cat ${kak_response_fifo})
        local statefile=$(mktemp "${TMPDIR:-/tmp}"/kak-jj-split.XXXXXXXX)
        echo "require-module patch"
        local empty_description=false
        if [ -z "$(jj log --no-graph --ignore-working-copy -r ${revision} -T description)" ]; then
            empty_description=true
        fi
        echo "patch %exp{JJ_EDITOR='$(shell) %val{runtime}/rc/tools/jj-split-editor $empty_description ${statefile}'} \
                jj --color=auto %arg{@} -r $revision %exp{--tool=%val{runtime}/rc/tools/jj-split-tool}"
        # The first split will inherit the change ID from this diff, if
        # any. But typically -- when the diff is from "jj show --git" --
        # the remaining diff corresponds to the second split.  Update the
        # change ID accordingly. Among other things, this means that multiple
        # successive splits will create a simple, linear history.
        if [ "$revision" != @ ] && ! $parallel; then {
            echo "evaluate-commands -draft -save-regs | %{
                try %{
                    execute-keys %{<a-/>^Change ID: \S+<ret>}
                    execute-keys %{1s^Change ID: (\S+)<ret>}
                    set-register | %{
                        jj log --color=auto --no-graph --ignore-working-copy -r ${revision}+ -T change_id
                    }
                    execute-keys |<ret>
                }
            }"
        } fi
    }

    jj_workspace() {
        case "$2" in
            (root | list)
                jj_with_buffer_output "$@"
                ;;
            (*)
                jj_with_transient_output "$@"
                ;;
        esac
    }

    INPARAM_filetype=
    INPARAM_onclose=

    for arg; do
        case "$arg" in
            (-h | --help)
                jj_with_buffer_output "$@"
                exit
                ;;
            (-*)
                break
                ;;
        esac
    done
    if [ $# -eq 0 ]; then
        jj_with_buffer_output "$@"
        exit
    fi
    case "$1" in
        (abandon) jj_with_transient_output "$@" ;;
        (absorb) jj_with_transient_output "$@" ;;
        (b | bookmark) jj_bookmark "$@" ;;
        (commit) jj_commit "$@" ;;
        (config) jj_with_transient_output "$@" ;;
        (describe) jj_describe "$@" ;;
        (__with_predetermined_edit) jj_with_predetermined_edit "$@" ;;
        (diff) jj_show_or_diff "$@" ;;
        # 'diffedit' not yet supported
        (duplicate) jj_with_transient_output "$@" ;;
        (edit) jj_with_transient_output "$@" ;;
        (evolog) jj_with_buffer_output "$@" ;;
        (file) jj_file "$@" ;;
        (fix) jj_with_transient_output "$@" ;;
        (git) jj_with_transient_output "$@" ;;
        (help) jj_with_buffer_output "$@" ;;
        (init) jj_with_transient_output "$@" ;;
        (interdiff) jj_with_buffer_output "$@" ;;
        (log) jj_with_buffer_output "$@" ;;
        (new) jj_with_transient_output "$@" ;;
        (next) jj_with_transient_output "$@" ;;
        (op | operation) jj_operation "$@" ;;
        (parallelize) jj_with_transient_output "$@" ;;
        (prev) jj_with_transient_output "$@" ;;
        (rebase) jj_with_transient_output "$@" ;;
        # 'resolve' not yet supported
        (restore) jj_with_transient_output "$@" ;;
        (revert) jj_with_transient_output "$@" ;;
        (root) jj_with_transient_output "$@" ;;
        (show) jj_show "$@" ;;
        (simplify-parents) jj_with_transient_output "$@" ;;
        (sparse) jj_sparse "$@" ;;
        (split) jj_split "$@" ;;
        (squash) jj_with_editor_async "$@" ;;
        (st | status) jj_with_buffer_output "$@" ;;
        (tag) jj_with_buffer_output "$@" ;;
        (undo) jj_with_transient_output "$@" ;;
        # 'util' not yet supported
        (version) jj_with_transient_output "$@" ;;
        (workspace) jj_workspace "$@" ;;
        (*) echo "fail -- unknown jj command: $(kakquote "$1")" ;;
    esac
} }

complete-command jj shell-script-candidates %{
    if [ ${kak_token_to_complete} -eq 0 ]; then {
        printf %s\\n \
            abandon \
            absorb \
            b bookmark \
            commit \
            config \
            describe \
            diff \
            duplicate \
            edit \
            evolog \
            file \
            fix \
            git \
            help \
            init \
            interdiff \
            log \
            new \
            next \
            op operation \
            parallelize \
            prev \
            rebase \
            restore \
            revert \
            root \
            show \
            simplify-parents \
            sparse \
            split \
            squash \
            st status \
            tag \
            undo \
            version \
            workspace \
            -h --help \
        ; return
    } fi
    COMPLETE=fish jj -- jj "$@" | sed 's,\t.*,,g' # Remove descriptions.
}
