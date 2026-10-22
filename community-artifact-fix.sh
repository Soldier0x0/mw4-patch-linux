#!/usr/bin/env bash
# Reversible D3D12 file check/install/rollback for the matching local build.
# Does not bundle DLLs, edit rex_sp.dll, or launch/patch the game process.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GAME_BASE=${MW4_GAME_ROOT:-$ROOT}
GAME_ROOT=''
SP26=''
RUNTIME=''
BRANCHES=''
STATE=''
EXPECTED_BUILD=25909941
DLLS=(d3d12.dll d3d12core.dll)
EXPECTED_d3d12_dll=633de512245b2b93728a283751f27bb44d199659830ec6fd9c78053f1feda2fe
EXPECTED_d3d12core_dll=3822f59b19f18458762a7f680ce4395bb4bd98b6e873bd645d0c83ee20d3cb24
ACTIVE_BACKUP=''

usage() {
    cat <<'EOF'
Usage:
  ./community-artifact-fix.sh --check --game-root PATH
  ./community-artifact-fix.sh --install --game-root PATH
  ./community-artifact-fix.sh --rollback [backup-directory] --game-root PATH

--check     Verify the game build and the two locally supplied source DLLs.
--install   Back up existing game-folder DLLs, then copy the verified pair
            from this installation's game/game/runtime/ into game/game/sp26/.
--rollback  Restore the latest backup, or the explicitly named backup directory.

This script does not download or bundle DLLs, modify rex_sp.dll, patch a running
game process, or launch the game. See COMMUNITY-ARTIFACT-FIX-README.md.
EOF
}

die() { printf 'Artifact fix: %s\n' "$*" >&2; exit 1; }
hash_file() { sha256sum -- "$1" | awk '{print $1}'; }

set_game_base() {
    [[ -d $1 ]] || die "game installation folder not found: $1"
    GAME_BASE=$(cd -- "$1" && pwd)
    GAME_ROOT="$GAME_BASE/game/game"
    SP26="$GAME_ROOT/sp26"
    RUNTIME="$GAME_ROOT/runtime"
    BRANCHES="$SP26/steam_settings/branches.json"
    STATE="$GAME_BASE/game/state/community-artifact-fix"
}

expected_hash() {
    case $1 in
        d3d12.dll) printf '%s\n' "$EXPECTED_d3d12_dll" ;;
        d3d12core.dll) printf '%s\n' "$EXPECTED_d3d12core_dll" ;;
        *) return 1 ;;
    esac
}

preflight() {
    local name hash
    [[ -f "$SP26/sp26-cod.exe" ]] || die "game files not found under $GAME_ROOT"
    [[ -f "$BRANCHES" ]] || die "missing build manifest: $BRANCHES"
    grep -Eq '"build_id"[[:space:]]*:[[:space:]]*'"$EXPECTED_BUILD"'([,[:space:]]|$)' "$BRANCHES" \
        || die "this script targets build $EXPECTED_BUILD; the local build manifest does not match"
    for name in "${DLLS[@]}"; do
        [[ -f "$RUNTIME/$name" ]] || die "source DLL is missing: $RUNTIME/$name"
        hash=$(hash_file "$RUNTIME/$name")
        [[ $hash == "$(expected_hash "$name")" ]] \
            || die "source hash mismatch for $name (found $hash)"
    done
}

game_running() {
    pgrep -f '[s]p26-cod\.exe' >/dev/null 2>&1
}

write_manifest() {
    local backup=$1 name dest
    {
        printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'game_build=%s\n' "$EXPECTED_BUILD"
        for name in "${DLLS[@]}"; do
            dest="$SP26/$name"
            printf '%s.source_sha256=%s\n' "$name" "$(hash_file "$RUNTIME/$name")"
            if [[ -f $dest ]]; then
                printf '%s.previous=present\n' "$name"
                printf '%s.previous_sha256=%s\n' "$name" "$(hash_file "$dest")"
            else
                printf '%s.previous=absent\n' "$name"
            fi
        done
    } > "$backup/manifest.txt"
}

rollback_dir() {
    local backup=$1 name marker dest temp prior
    [[ -d $backup && -f "$backup/manifest.txt" ]] || die "invalid backup directory: $backup"
    for name in "${DLLS[@]}"; do
        marker="$backup/$name.changed"
        [[ -f $marker ]] || continue
        dest="$SP26/$name"
        if [[ -e $dest ]]; then
            [[ $(hash_file "$dest") == "$(expected_hash "$name")" ]] \
                || die "$dest changed since installation; refusing to overwrite it"
        fi
        prior=$(awk -F= -v key="$name.previous" '$1 == key {print $2}' "$backup/manifest.txt")
        case $prior in
            present)
                [[ -f "$backup/$name.original" ]] || die "backup file missing: $backup/$name.original"
                temp="$dest.rollback.$$"
                cp -a -- "$backup/$name.original" "$temp"
                mv -f -- "$temp" "$dest"
                ;;
            absent)
                rm -f -- "$dest"
                ;;
            *) die "backup manifest has no valid previous state for $name" ;;
        esac
        rm -f -- "$marker"
        printf 'Restored %s (%s).\n' "$name" "$prior"
    done
    printf 'Rollback complete. Backup retained at %s\n' "$backup"
}

on_error() {
    local status=$?
    trap - ERR
    if [[ -n ${ACTIVE_BACKUP:-} ]]; then
        printf 'Install did not complete; restoring any files already changed.\n' >&2
        rollback_dir "$ACTIVE_BACKUP" || true
    fi
    exit "$status"
}

check_files() {
    local name target_hash
    preflight
    printf 'Game build %s: verified.\n' "$EXPECTED_BUILD"
    for name in "${DLLS[@]}"; do
        printf '%s source: %s\n' "$name" "$(hash_file "$RUNTIME/$name")"
        if [[ -f "$SP26/$name" ]]; then
            target_hash=$(hash_file "$SP26/$name")
            if [[ $target_hash == "$(expected_hash "$name")" ]]; then
                printf '%s game-folder copy: matches expected hash.\n' "$name"
            else
                printf '%s game-folder copy: differs (%s).\n' "$name" "$target_hash"
            fi
        else
            printf '%s game-folder copy: absent.\n' "$name"
        fi
    done
}

install_files() {
    local name dest backup
    preflight
    game_running && die 'close the game before installing or rolling back files'
    if [[ $(hash_file "$SP26/${DLLS[0]}") == "$(expected_hash "${DLLS[0]}")" ]] \
       && [[ $(hash_file "$SP26/${DLLS[1]}") == "$(expected_hash "${DLLS[1]}")" ]]; then
        printf 'Both game-folder DLLs already match; no changes made.\n'
        exit 0
    fi

    mkdir -p -- "$STATE"
    backup=$(mktemp -d "$STATE/backup-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    ACTIVE_BACKUP=$backup
    for name in "${DLLS[@]}"; do
        dest="$SP26/$name"
        if [[ -f $dest ]]; then
            cp -a -- "$dest" "$backup/$name.original"
        fi
    done
    write_manifest "$backup"
    printf 'Backups and manifest: %s\n' "$backup"

    for name in "${DLLS[@]}"; do
        dest="$SP26/$name"
        [[ -f $dest ]] && [[ $(hash_file "$dest") == "$(expected_hash "$name")" ]] && continue
        cp -a -- "$RUNTIME/$name" "$dest.new.$$"
        mv -f -- "$dest.new.$$" "$dest"
        : > "$backup/$name.changed"
        printf 'Installed verified %s.\n' "$name"
    done
    ACTIVE_BACKUP=''
    trap - ERR
    printf 'Graphics DLL step complete. No launcher or game-process files were changed.\n'
    printf 'To undo: %s --rollback %q\n' "$0" "$backup"
}

main() {
    local command=${1:-} backup='' arg
    shift || true
    while (($#)); do
        case $1 in
            --game-root)
                (($# >= 2)) || die '--game-root requires a path'
                set_game_base "$2"
                shift 2
                ;;
            --help|-h)
                usage
                return
                ;;
            --*) die "unknown option: $1" ;;
            *)
                [[ $command == --rollback && -z $backup ]] || die "unexpected argument: $1"
                backup=$1
                shift
                ;;
        esac
    done
    case $command in
        --help|-h) usage ;;
        --check)
            check_files
            ;;
        --install)
            install_files
            ;;
        --rollback)
            game_running && die 'close the game before installing or rolling back files'
            if [[ -z $backup ]]; then
                [[ -d $STATE ]] || die "no backups found at $STATE"
                backup=$(find "$STATE" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -printf '%T@ %p\n' \
                    | sort -nr | head -n 1 | cut -d' ' -f2-)
                [[ -n $backup ]] || die "no backups found at $STATE"
            fi
            rollback_dir "$backup"
            ;;
        *) usage >&2; exit 2 ;;
    esac
}

trap on_error ERR
set_game_base "$GAME_BASE"
main "$@"
