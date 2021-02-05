#!/usr/bin/env bash

# Script to auto sync a git repo dag.
function git_auto_sync() {
    local help_info="USAGE: git_autosync [sync-path]
OR AS LIB: source git_autosync --as-lib
ARGS:
    [sync-path]     The path to the repo. (Defualts to current folder)
    -r --repo-url   The repo url (defaults to folder git repo if exists)
    -b --branch     The name of the branch (defaults to folder git branch if exists)
    -n --max-times  Max Number of sync times. -1 for infinity. (default -1)
    -i --interval   The time interval to use in seconds (defaults to 5)
    --sync-command  The git sync command to use. (defaults to 'git pull')
    
    --as-lib        Load the current file as a library function. Dose not allow any other
                    arguments.
FLAGS:
    -a --async      If flag exists, syncs in background after first successful sync
    -h --help       Show this help menu.
ENVS:
    GIT_AUTOSYNC_LOGPREFEX  The git sync log prefex, (apperas before the log),
                            Allowes for stack tracing.
"
    # helper methods
    : ${GIT_AUTOSYNC_LOGPREFEX:="GIT_AUTOSYNC:"}

    function log() {
        local type="$2"
        : ${type:="LOG"}
        echo "$GIT_AUTOSYNC_LOGPREFEX:$type: $1"
    }

    function assert() {
        local error="$1"
        local txt="$2"

        if ! [[ "$error" =~ ^[0-9]+$ ]]; then
            assert 99 "The error value (\$1) for the assert function must be a number." || return $?
        fi

        if [ "$error" -ne 0 ]; then
            log "when running ${BASH_SOURCE[1]} ${FUNCNAME[1]}, code: $error" "ERROR"
            log "Message: $txt" "ERROR"
            if [ ${#FUNCNAME[@]} -gt 2 ]; then
                echo "Stack trace:"
                for ((i = 1; i < ${#FUNCNAME[@]} - 1; i++)); do
                    log "$i: ${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)"
                done
            fi
        fi

        return "$error"
    }

    # variables
    local repo_local_path=""
    local repo_url=""
    local repo_branch=""
    local max_times=-1
    local interval=5
    local async=0
    local sync_command="git pull"

    # loading varaibles.
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help)
                echo "$help_info"
                exit 0
                ;;
            -r | --repo-url)
                shift
                repo_url="$1"
                ;;
            -b | --branch)
                shift
                repo_branch="$1"
                ;;
            -n | --max-times)
                shift
                max_times=$1
                ;;
            -i | --interval)
                shift
                interval="$1"
                ;;
            -a | --async)
                async=1
                ;;
            --sync-command)
                shift
                sync_command="$1"
                ;;
            --as-lib)
                assert 2 "git_auto_sync cannot be both called as a library and have command args." || return $?
                ;;
            -*)
                assert 2 "Unknown identifier $1" || return $?
                ;;
            *)
                if [ -z "$repo_local_path" ]; then
                    repo_local_path="$1"
                else
                    assert 2 "Unknown positional parameter (or command) $1" || return $?
                fi
                ;;
        esac
        shift
    done

    if [ -z "$repo_local_path" ]; then
        repo_local_path="."
    fi

    repo_local_path="$(realpath "$repo_local_path")"
    assert $? "Failed to resolve local path: $repo_local_path" || return $?

    # this may be changed at each iteration.
    local current_working_dir="$PWD"

    function to_repo_dir() {
        current_working_dir="$PWD"
        cd "$repo_local_path"
        assert $? "Failed to enter directory $repo_local_path" || return $?
    }

    function back_to_working_dir() {
        cd "$current_working_dir"
        assert $? "Failed to enter directory $current_working_dir" || return $?
    }

    to_repo_dir || return $?

    # adding default params.
    if [ -z "$repo_url" ]; then
        repo_url="$(git config --get remote.origin.url)"
        if [ -z "$repo_url" ]; then
            assert 2 "Failed to retrive git origin url" || return $?
        fi
    fi
    if [ -z "$repo_branch" ]; then
        repo_branch="$(git rev-parse --abbrev-ref HEAD)"
        if [ -z "$repo_branch" ]; then
            assert 2 "Failed to retrive git branch name" || return $?
        fi
    fi

    back_to_working_dir || return $?

    function sync() {
        to_repo_dir || return $?
        log "Invoking sync with '$sync_command'..."
        eval "$sync_command"
        local last_error=$?

        back_to_working_dir || return $?
        assert $last_error "Failed sync from remote using command '$sync_command'" || return $?
        return 0
    }

    function get_change_list() {
        to_repo_dir || return $?

        function __internal() {
            remote_update_log="$(git remote update)"
            newline=$'\n'
            assert "$?" "Failed to update from remote: $newline$remote_update_log $newline Proceed to next attempt" || return 0

            file_difs="$(git diff "$repo_branch" "origin/$repo_branch" --name-only)"
            assert $? "Field to execute git diff: $file_difs" || return $?

            if [ -n "$file_difs" ]; then
                echo "$file_difs"
            fi

            return 0
        }

        __internal
        local last_error="$?"
        back_to_working_dir || return $?
        assert $last_error "Failed to get change list." || return $?

        return 0
    }

    # first attempt to pull
    get_change_list
    assert $? "Failed to initialize remote repo autosync @ $repo_url/$repo_branch to $repo_local_path" || return $?

    local last_error=0

    function sync_loop() {
        log "Starting sync: $repo_url/$repo_branch -> $repo_local_path"
        local sync_count=0
        while true; do
            change_list="$(get_change_list)"
            last_error=$?

            if [ $last_error -ne 0 ]; then
                log "ERROR: could not get change list. Re-attempting in $interval [sec]."
                sleep "$interval"
                continue
            fi

            if [ -n "$change_list" ]; then
                log "Repo has changed:"
                echo "$change_list"
                sync
                assert $? "Failed to sync. Re-attempt in $interval seconds" || continue
                log "Sync complete @ $(date)"
            fi

            if [ $max_times -gt 0 ] && [ $max_times -gt $sync_count ]; then
                break
            fi
            sync_count=$((sync_count + 1))
            sleep "$interval"
        done

        log "Sync stopped"
    }

    # start loop.
    if [ $async -eq 1 ]; then
        sync_loop &
    else
        sync_loop
    fi
}

# if not as library then use invoke the function.
if [ "$1" != "--as-lib" ]; then
    git_auto_sync "$@"
fi
