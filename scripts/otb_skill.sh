#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: otb_skill.sh [options] <command> [arguments]

Options:
  --help           Show this help
  --version        Show the wrapper version
  --dry-run        Print the executable command for a mutation
  -h, --host HOST  Server host or Unix socket directory
  -p, --port PORT  Server port
  -U, --user USER  Database user
  -d, --dbname DB  Database name

Commands:
  status
  nodes
  groups
  databases
  roles
  logs
  create-db <name>
  create-table <name> <cols> [shard|replication]
  grant <priv> <table> <role>
  start
  stop

Connection options override PGHOST, PGPORT, PGUSER, and PGDATABASE.
Unset host and port are discovered from postmaster.pid when available.
Local commands use PGDATA or ~/.local/opentenbase/data. Start and stop
control the server in that directory with pg_ctl.
Create-table accepts a trusted SQL column list as one argument. Shard
uses its first column as the distribution key.
Table names can be schema-qualified. Grant accepts comma-separated
table privileges. Without -d or PGDATABASE, the database is postgres.
HELP
}

die() {
    printf 'otb_skill: %s\n' "$*" >&2
    exit 1
}

host=${PGHOST:-}
port=${PGPORT:-}
db_user=${PGUSER:-}
dbname=${PGDATABASE:-postgres}
dry_run=false
command_name=
args=()
while (( $# )); do
    case $1 in
        --help) usage; exit 0 ;;
        --version) printf 'otb_skill 1.0.0\n'; exit 0 ;;
        --dry-run) dry_run=true ;;
        -h|--host|-p|--port|-U|--user|-d|--dbname)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || die "$1 requires a value"
            case $1 in
                -h|--host) host=$2 ;;
                -p|--port) port=$2 ;;
                -U|--user) db_user=$2 ;;
                -d|--dbname) dbname=$2 ;;
            esac
            shift
            ;;
        --)
            shift
            if [[ -z $command_name ]] && (( $# )); then
                command_name=$1
                shift
            fi
            args+=("$@")
            break
            ;;
        -*) die "unknown option: $1" ;;
        *)
            if [[ -z $command_name ]]; then
                command_name=$1
            else
                args+=("$1")
            fi
            ;;
    esac
    shift
done

data_dir=${PGDATA:-${HOME:?HOME or PGDATA must be set}/.local/opentenbase/data}
if [[ ( -z $host || -z $port ) && -r $data_dir/postmaster.pid ]]; then
    mapfile -t pid_info < "$data_dir/postmaster.pid"
    if [[ ${pid_info[3]:-} =~ ^[0-9]+$ ]]; then
        port=${port:-${pid_info[3]}}
        if [[ -z $host ]]; then
            listen_address=${pid_info[5]:-}
            case $listen_address in
                '*'|0.0.0.0) listen_address=127.0.0.1 ;;
                '::') listen_address=::1 ;;
            esac
            host=${pid_info[4]:-${listen_address:-localhost}}
        fi
    fi
fi

psql_cmd=(psql -X -w -v ON_ERROR_STOP=1 -P pager=off)
[[ -z $host ]] || psql_cmd+=(-h "$host")
[[ -z $port ]] || psql_cmd+=(-p "$port")
[[ -z $db_user ]] || psql_cmd+=(-U "$db_user")
psql_cmd+=(-d "$dbname")

mutate() {
    if "$dry_run"; then
        local arg previous=
        printf '%q' "$1"
        shift
        for arg in "$@"; do
            if [[ $previous == -c ]]; then
                printf " '%s'" "${arg//\'/\'\\\'\'}"
            else
                printf ' %q' "$arg"
            fi
            previous=$arg
        done
        printf '\n'
    else
        "$@"
    fi
}

quote_identifier() {
    [[ -n $1 ]] || die "empty SQL identifier"
    printf '"%s"' "${1//\"/\"\"}"
}

quote_table() {
    if [[ $1 == *.* ]]; then
        [[ ${1#*.} != *.* ]] || die "expected table or schema.table"
        quote_identifier "${1%%.*}" || return
        printf '.'
        quote_identifier "${1#*.}"
    else
        quote_identifier "$1"
    fi
}

tail_log() {
    local format path candidate newest=
    if [[ -r $data_dir/current_logfiles ]]; then
        while read -r format path; do
            [[ -n $path ]] || continue
            [[ $path == /* ]] || path=$data_dir/$path
            if [[ -f $path && ( -z $newest || $path -nt $newest ) ]]; then
                newest=$path
            fi
        done < "$data_dir/current_logfiles"
    fi
    if [[ -z $newest ]]; then
        for candidate in "$data_dir"/{log,pg_log}/* "$data_dir"/*.log; do
            if [[ -f $candidate && ( -z $newest || $candidate -nt $newest ) ]]; then
                newest=$candidate
            fi
        done
    fi
    [[ -n $newest ]] || die "no server log found in $data_dir"
    tail -n 50 -- "$newest"
}

case $command_name in
    status|nodes|groups|databases|roles|logs|start|stop)
        (( ${#args[@]} == 0 )) || die "$command_name takes no arguments"
        ;;
    '') usage >&2; exit 1 ;;
esac

case $command_name in
    status)
        if command -v otb_aiops >/dev/null 2>&1; then
            [[ -z $host ]] || export PGHOST=$host
            [[ -z $port ]] || export PGPORT=$port
            [[ -z $db_user ]] || export PGUSER=$db_user
            export PGDATABASE=$dbname
            otb_aiops health --json
        else
            "${psql_cmd[@]}" -c 'SELECT version(), now() - pg_postmaster_start_time() AS uptime;'
        fi
        ;;
    nodes) "${psql_cmd[@]}" -c 'SELECT * FROM pg_catalog.pgxc_node;' ;;
    groups) "${psql_cmd[@]}" -c 'SELECT * FROM pg_catalog.pgxc_group;' ;;
    databases) "${psql_cmd[@]}" -c '\l' ;;
    roles) "${psql_cmd[@]}" -c 'SELECT * FROM pg_catalog.pg_roles;' ;;
    logs) tail_log ;;
    create-db)
        (( ${#args[@]} == 1 )) || die 'usage: create-db <name>'
        name=$(quote_identifier "${args[0]}")
        mutate "${psql_cmd[@]}" -c "CREATE DATABASE $name;"
        ;;
    create-table)
        (( ${#args[@]} >= 2 && ${#args[@]} <= 3 )) ||
            die 'usage: create-table <name> <cols> [shard|replication]'
        name=$(quote_table "${args[0]}")
        cols=${args[1]}
        [[ $cols =~ [^[:space:]] ]] || die 'column list is empty'
        distribution=
        case ${args[2]-} in
            '') ;;
            replication) distribution=' DISTRIBUTE BY REPLICATION' ;;
            shard)
                first_column='^[[:space:]]*("([^"]|"")+"|[a-zA-Z_][a-zA-Z_0-9$]*)[[:space:]]+[^[:space:]]'
                [[ $cols =~ $first_column ]] || die 'shard requires a first column with a name and type'
                distribution=" DISTRIBUTE BY SHARD (${BASH_REMATCH[1]})"
                ;;
            *) die 'distribution must be shard or replication' ;;
        esac
        mutate "${psql_cmd[@]}" -c "CREATE TABLE $name ($cols)$distribution;"
        ;;
    grant)
        (( ${#args[@]} == 3 )) || die 'usage: grant <priv> <table> <role>'
        privileges=${args[0]^^}
        privilege='(SELECT|INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER)'
        privilege_list="^[[:space:]]*(ALL([[:space:]]+PRIVILEGES)?|$privilege([[:space:]]*,[[:space:]]*$privilege)*)[[:space:]]*$"
        [[ $privileges =~ $privilege_list ]] || die 'invalid table privilege list'
        name=$(quote_table "${args[1]}")
        role=$(quote_identifier "${args[2]}")
        mutate "${psql_cmd[@]}" -c "GRANT $privileges ON TABLE $name TO $role;"
        ;;
    start) mutate pg_ctl -D "$data_dir" -l "$data_dir/server.log" -w start ;;
    stop) mutate pg_ctl -D "$data_dir" -m fast -w stop ;;
    *) die "unknown command: $command_name" ;;
esac
