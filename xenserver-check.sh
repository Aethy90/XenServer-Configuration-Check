#!/bin/bash
# Generated XenServer checker launcher. Editable sources are in the source ZIP.
# Host requirements remain Bash 4+, root, xe/OpenSSH and existing GNU utilities.
# No Python, installation, credential setup or host configuration change.
set -u
set -o pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
case "${1:-}" in
  --version) printf 'XenServer configuration checker 0.12.0\n'; exit 0;;
  --help|-h) cat <<'CHECKER_HELP'
Usage: bash xenserver-check.sh --output-root /existing/directory [options]
  --scope host|pool    Explicit local/pool selection (otherwise discover/prompt).
  --case-id TEXT       Collection label.
  --dry-run           Discovery only; no snapshot or member SSH.
  --ssh-key PATH      Existing key for pool members; no key is installed.
  --known-hosts PATH  Existing, verified member host keys.
  --debug             Bounded diagnostics.
  --snapshot          FIRST option: raw single-host snapshot for manual combining.

Full pool collection must launch on the coordinator. No Python is invoked.
The launcher temporarily unpacks its internal Bash stages in /var/tmp, verifies
them and removes those script copies on exit. Collection output is retained.
Standard collection: transfer the printed bundle and checksum to a workstation:
  python3 xenserver-review.pyz review bundle.tar.gz --out new-review
For all underlying collection options use the source package collection guide.
CHECKER_HELP
    exit 0;;
esac
[[ ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Bash 4+ required on XenServer\n' >&2; exit 2; }
work=$(mktemp -d /var/tmp/xen-checker-launch.XXXXXX) || exit 2
cleanup() {
  rm -f -- "$work/collect_pool.sh" "$work/xen_config_collect.sh" "$work/pool_member_capture.sh"
  rmdir -- "$work" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$work/collect_pool.sh" <<'CHECKER_04B9B55C1BEF54562CCF723B80643B225D26949437D68100CEC5C0BF4E982819'
#!/bin/bash
# Collection only: Bash 4+, xe, OpenSSH and existing GNU utilities. No Python.
SHELL_RUNNER_VERSION=0.12.0
pool_usage() {
    cat <<'HELP'
Usage: bash collect_pool.sh --output-root /existing/directory [options]
  --scope host|pool         Explicit scope (otherwise discover/prompt).
  --debug                   Bounded stage diagnostics on stderr.
  --case-id TEXT             Label (default POOL).
  --ssh-key PATH             Existing coordinator private key; otherwise agent/default keys.
  --known-hosts PATH         Preverified member host keys (default /root/.ssh/known_hosts).
  --ssh-port N               Member SSH port (default 22).
  --remote-output-root PATH  Existing member directory (default /var/tmp).
  --command-timeout N        Per query seconds (default 30).
  --host-timeout N           Per host seconds (default 1200).
  --max-total-mib N          Source data per host (default 64).
  --max-archive-mib N        Archive transfer cap per host (1–128, default 128).
  --max-pool-mib N           Total retrieved archive/frame budget (default 1024).
  --dry-run                 Local coordinator/member discovery only; no output or SSH.
  --help | --version
Run as root on XenServer; full multi-host collection starts on the coordinator.
Keep this script,
xen_config_collect.sh and pool_member_capture.sh together. No Python is invoked.
Transfer the bundle to a workstation, then run review_collected_pool.py there.
Exit 0: retrieval complete, pending offline validation; 1: saved partial bundle;
2: requirements/discovery/coordinator capture/packaging failed. Not a compliance score.
HELP
}
pool_error() { printf '%s\n' "$*" >&2; return 2; }
pool_uuid() { [[ $1 =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
pool_root() {
    [[ $1 =~ ^/[A-Za-z0-9/_.-]+$ && $1 != *'/../'* && $1 != */.. ]] || return 1
    case "$1/" in /|/etc/*|/usr/*|/boot/*|/proc/*|/sys/*|/run/*|/root/*|/home/*|/var/log/*|/var/spool/*) return 1;; esac
}
pool_address() {
    local a=$1 octet
    # Numeric literals only; invalid IPv6 literals are rejected by OpenSSH/offline review.
    if [[ $a == *:* ]]; then [[ $a =~ ^[a-fA-F0-9:.]+$ && ${#a} -le 45 ]]; return; fi
    [[ $a =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local -a octets
    IFS=. read -r -a octets <<< "$a"
    for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}
pool_query() {
    ( ulimit -c 0; ulimit -f 1024 || exit 2
      timeout --signal=TERM --kill-after=5 "$COMMAND_TIMEOUT" xe "$@" )
}
pool_require_host() { [[ ${BASH_VERSINFO[0]} -ge 4 && $EUID == 0 && -f /etc/xensource-inventory ]]; }
pool_local_uuid() { sed -n "s/^INSTALLATION_UUID=['\"]\([^'\"]*\)['\"]$/\1/p" /etc/xensource-inventory; }
pool_discover() {
    # DISCOVER: emit only validated identity/address rows; never infer a
    # standalone host when a required discovery query fails.
    local local_id pools master ids h address count=0
    local_id=$(pool_local_uuid) || return 2
    local_id=${local_id,,}; pool_uuid "$local_id" || return 2
    pools=$(pool_query pool-list --minimal) || return 2
    pools=${pools,,}; pool_uuid "$pools" || return 2
    master=$(pool_query pool-param-get "uuid=$pools" param-name=master) || return 2
    master=${master,,}
    pool_uuid "$master" || return 2
    ids=$(pool_query host-list --minimal) || return 2
    local -a host_ids; local -A seen=() addresses=()
    IFS=, read -r -a host_ids <<< "$ids"
    (( ${#host_ids[@]} >= 1 && ${#host_ids[@]} <= 256 )) || return 2
    printf 'pool\t%s\t%s\n' "$pools" "$master"
    for h in "${host_ids[@]}"; do
        h=${h,,}; pool_uuid "$h" && [[ ! ${seen[$h]+yes} ]] || return 2
        seen[$h]=1
        address=$(pool_query host-param-get "uuid=$h" param-name=address) || return 2
        pool_address "$address" || { pool_error 'Invalid or missing host management IP'; return 2; }
        [[ ! ${addresses[$address]+yes} ]] || { pool_error 'Duplicate management address'; return 2; }
        addresses[$address]=1
        printf 'host\t%s\t%s\n' "$h" "$address"
        count=$((count+1))
    done | sort || return 2
    # The loop above executes in a subshell; pipefail propagates its failures.
    [[ ,${ids,,}, == *",$master,"* && ,${ids,,}, == *",$local_id,"* ]] || return 2
}
# Select scope only after verified discovery. No peer connections occur here.
# Inputs: count, requested scope, local/coordinator UUIDs. Output: effective scope.
pool_select_scope() {
    local count=$1 requested=$2 launch=$3 coordinator=$4 answer
    SELECTION_METHOD=explicit
    if (( count == 1 )); then EFFECTIVE_SCOPE=host; SELECTION_METHOD=single-host
    elif [[ $requested == host || $requested == pool ]]; then EFFECTIVE_SCOPE=$requested
    elif [[ -t 0 ]]; then
        SELECTION_METHOD=interactive
        printf 'This host belongs to a pool containing %s hosts.\n' "$count" >&2
        while true; do
            printf 'Check the entire pool? [y/N] ' >&2
            IFS= read -r answer || { pool_error 'Scope selection cancelled'; return 2; }
            case $answer in y|Y|yes|YES) EFFECTIVE_SCOPE=pool; break;; n|N|no|NO|'') EFFECTIVE_SCOPE=host; break;; *) printf 'Enter y for pool or n for this host.\n' >&2;; esac
        done
    else pool_error 'Multi-host noninteractive run requires --scope host or --scope pool'; return 2; fi
    if [[ $EFFECTIVE_SCOPE == pool && $launch != "$coordinator" ]]; then
        local entry=collect_pool.sh; [[ ${XEN_CHECKER_PACKAGED:-0} != 1 ]] || entry=xenserver-check.sh
        pool_error "Launch full pool collection on coordinator $coordinator using: bash $entry --scope pool --output-root /var/tmp"
        return 2
    fi
}
# Stage events contain fixed labels/UUIDs only; never command arguments or secrets.
pool_trace() {
    (( ${DEBUG_MODE:-0} )) || return 0
    (( ${TRACE_COUNT:-0} < 1024 )) || return 0
    TRACE_COUNT=$(( ${TRACE_COUNT:-0}+1 ))
    printf 'CHECKER stage=%s state=%s host=%s source=collect_pool.sh:%s version=%s run=%s digest=%s\n' "$1" "$2" "${LAUNCH_HOST_UUID:-discovery}" "${BASH_LINENO[0]}" "$SHELL_RUNNER_VERSION" "${RUN:-discovery}" "${COLLECTOR_HASH:-pending}" >&2
}
pool_guard() {
    local current
    current=$(pool_discover) && [[ $current == "$INITIAL_DISCOVERY" ]]
}
pool_json() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}
pool_manifest() {
    local h first=1 complete=true
    [[ $DISCOVERY_STABLE == true ]] || complete=false
    for h in "${HOST_IDS[@]}"; do [[ ${STATUS[$h]} == Retrieved ]] || complete=false; done
    COLLECTION_COMPLETE=$complete
    {
        printf '{"schema":"xenserver-shell-pool-collection/1","runner_version":"%s",' "$SHELL_RUNNER_VERSION"
        printf '"pool_uuid":"%s","coordinator_uuid":"%s","started_at":"%s","finished_at":"%s",' "$POOL_UUID" "$COORDINATOR_UUID" "$STARTED_AT" "$FINISHED_AT"
        printf '"scope":{"requested":"%s","effective":"%s","selection":"%s","launch_host_uuid":"%s","selected_host_uuids":[' "$REQUESTED_SCOPE" "$EFFECTIVE_SCOPE" "$SELECTION_METHOD" "$LAUNCH_HOST_UUID"
        local first_target=1 target
        for target in "${HOST_IDS[@]}"; do (( first_target )) || printf ','; first_target=0; printf '"%s"' "$target"; done
        printf ']},'
        printf '"discovery_stable":%s,"collection_complete":%s,"retrieved_bytes":%s,' "$DISCOVERY_STABLE" "$complete" "$RETRIEVED_BYTES"
        printf '"collector_script_sha256":"%s","member_template_sha256":"%s",' "$COLLECTOR_HASH" "$TEMPLATE_HASH"
        printf '"limits":{"command_timeout_seconds":%s,"host_timeout_seconds":%s,"source_mib_per_host":%s,"archive_mib_per_host":%s,"retrieval_budget_mib":%s},' "$COMMAND_TIMEOUT" "$HOST_TIMEOUT" "$MAX_TOTAL" "$MAX_ARCHIVE" "$MAX_POOL"
        printf '"status_file":"collection-status.tsv","events":["Retrieval only; identity, internal checksums, completion and configuration are validated on the workstation."],"hosts":['
        for h in "${HOST_IDS[@]}"; do
            (( first )) || printf ','; first=0
            printf '{"host_uuid":"%s","address":' "$h"; pool_json "${ADDRESS[$h]}"
            printf ',"role":'; pool_json "${ROLE[$h]}"
            printf ',"status":'; pool_json "${STATUS[$h]}"
            printf ',"archive":'; pool_json "${ARCHIVE_PATH[$h]:-}"
            printf ',"archive_sha256":'; pool_json "${ARCHIVE_HASH[$h]:-}"
            printf ',"archive_bytes":%s,"remote_directory":' "${ARCHIVE_BYTES[$h]:-0}"; pool_json "${REMOTE_DIR[$h]:-}"
            printf ',"log":'; pool_json "${LOG[$h]:-}"
            printf ',"error":'; pool_json "${ERROR[$h]:-}"; printf '}'
        done
        printf ']}\n'
    } > "$RUN/collection-manifest.json.tmp" && mv -- "$RUN/collection-manifest.json.tmp" "$RUN/collection-manifest.json" || return 2
    {
        printf 'host_uuid\taddress\trole\tstatus\tarchive\tarchive_sha256\tarchive_bytes\tremote_directory\terror\tlog\n'
        for h in "${HOST_IDS[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "${ADDRESS[$h]}" "${ROLE[$h]}" "${STATUS[$h]}" "${ARCHIVE_PATH[$h]:-}" "${ARCHIVE_HASH[$h]:-}" "${ARCHIVE_BYTES[$h]:-0}" "${REMOTE_DIR[$h]:-}" "${ERROR[$h]:-}" "${LOG[$h]:-}"
        done
    } > "$RUN/collection-status.tsv"
}
pool_space() {
    local free
    free=$(df -Pk -- "$RUN" | awk 'NR==2 {print $4}')
    [[ $free =~ ^[0-9]+$ ]] && (( free*1024 >= $1+134217728 ))
}
pool_payload() {
    local line delimiter="XEN_COLLECTOR_$COLLECTOR_HASH" count=0
    while IFS= read -r line; do
        if [[ $line == __XEN_COLLECTOR_PAYLOAD__ ]]; then
            count=$((count+1))
            printf 'cat > "$work/xen_config_collect.sh" <<\x27%s\x27\n' "$delimiter"
            cat -- "$COLLECTOR" || return 2
            printf '%s\n' "$delimiter"
        else printf '%s\n' "$line"; fi
    done < "$TEMPLATE"
    (( count == 1 ))
}
pool_receive() {
    # VERIFY_TRANSFER: reject extra/truncated data before accepting a receipt.
    # Do not add prompts or pauses while the member frame is being retrieved.
    local frame=$1 destination=$2 cap=$3 header protocol size hash retained extra total actual
    IFS= read -r -n 4097 header < "$frame" || return 1
    (( ${#header} <= 4096 )) || return 1
    IFS=$'\t' read -r protocol size hash retained extra <<< "$header"
    [[ $header == "$protocol"$'\t'"$size"$'\t'"$hash"$'\t'"$retained" && $protocol == XENPOOL/1 && $size =~ ^[1-9][0-9]{0,12}$ && $hash =~ ^[a-f0-9]{64}$ && $retained =~ ^/[A-Za-z0-9/_.-]+$ ]] || return 1
    (( size <= cap )) || return 1
    total=$(stat -Lc '%s' -- "$frame") || return 1
    (( total == ${#header}+1+size )) || return 1
    tail -c "$size" -- "$frame" > "$destination" || return 1
    read -r actual _ < <(sha256sum -- "$destination")
    [[ $actual == "$hash" ]] || return 1
    RECEIVED_HASH=$hash RECEIVED_SIZE=$size RECEIVED_REMOTE=$retained
}
pool_capture_remote() {
    # Caller supplies only validated literals; timeout bounds the process group.
    ( ulimit -c 0; ulimit -f "$blocks" || exit 2
      timeout --signal=TERM --kill-after=5 "$((HOST_TIMEOUT+45))" "${ssh_args[@]}" -- "${ADDRESS[$h]}" "bash -s -- $h $POOL_UUID $COORDINATOR_UUID $CASE_ID $REMOTE_ROOT $COMMAND_TIMEOUT $MAX_TOTAL $HOST_TIMEOUT" < "$payload"
    ) > "$frame" 2> "$RUN/${LOG[$h]}"
}
pool_main() {
    # Coordinator/local workflow: discovery -> scope -> role -> local capture
    # -> sequential selected members -> discovery recheck -> manifest/package.
    set -u; set -o pipefail; set +o posix; umask 077
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC SSH_ASKPASS_REQUIRE=never
    unset XE_EXTRA_ARGS
    local OUTPUT_ROOT='' CASE_ID=POOL SSH_KEY='' KNOWN_HOSTS=/root/.ssh/known_hosts SSH_PORT=22 REMOTE_ROOT=/var/tmp
    local REQUESTED_SCOPE=auto EFFECTIVE_SCOPE=pool SELECTION_METHOD=explicit LAUNCH_HOST_UUID DEBUG_MODE=0 TRACE_COUNT=0
    local COMMAND_TIMEOUT=30 HOST_TIMEOUT=1200 MAX_TOTAL=64 MAX_ARCHIVE=128 MAX_POOL=1024 DRY_RUN=0
    while (( $# )); do
        case $1 in
            --help) pool_usage; return 0;;
            --version) printf 'XenServer shell pool collector %s\n' "$SHELL_RUNNER_VERSION"; return 0;;
            --dry-run) DRY_RUN=1; shift;;
            --debug) DEBUG_MODE=1; shift;;
            --scope) (( $# >= 2 )) && [[ $2 == host || $2 == pool ]] || { pool_error 'Use --scope host or --scope pool'; return 2; }; REQUESTED_SCOPE=$2; shift 2;;
            --output-root|--case-id|--ssh-key|--known-hosts|--ssh-port|--remote-output-root|--command-timeout|--host-timeout|--max-total-mib|--max-archive-mib|--max-pool-mib)
                (( $# >= 2 )) || { pool_error "Missing value: $1"; return 2; }
                case $1 in
                    --output-root) OUTPUT_ROOT=$2;; --case-id) CASE_ID=$2;; --ssh-key) SSH_KEY=$2;;
                    --known-hosts) KNOWN_HOSTS=$2;; --ssh-port) SSH_PORT=$2;; --remote-output-root) REMOTE_ROOT=$2;;
                    --command-timeout) COMMAND_TIMEOUT=$2;; --host-timeout) HOST_TIMEOUT=$2;;
                    --max-total-mib) MAX_TOTAL=$2;; --max-archive-mib) MAX_ARCHIVE=$2;; --max-pool-mib) MAX_POOL=$2;;
                esac; shift 2;;
            *) pool_error "Unknown option: $1"; return 2;;
        esac
    done
    pool_require_host || { pool_error 'Root, Bash 4+ and XenServer are required'; return 2; }
    local value tool
    for value in "$COMMAND_TIMEOUT" "$HOST_TIMEOUT" "$MAX_TOTAL" "$MAX_ARCHIVE" "$MAX_POOL" "$SSH_PORT"; do
        [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { pool_error 'Limits must be integers 1–999999'; return 2; }
    done
    (( SSH_PORT <= 65535 && MAX_ARCHIVE <= 128 )) && [[ $CASE_ID =~ ^[A-Za-z0-9._-]{1,64}$ ]] && pool_root "$REMOTE_ROOT" || { pool_error 'Invalid case ID, port, archive cap (maximum 128 MiB) or remote root'; return 2; }
    for tool in xe bash date dirname timeout sed sort sha256sum stat tar tail head df awk mktemp mkdir cp mv cat rm readlink du; do
        command -v "$tool" >/dev/null || { pool_error "Required existing utility missing: $tool"; return 2; }
    done
    local INITIAL_DISCOVERY
    pool_trace DISCOVER start
    INITIAL_DISCOVERY=$(pool_discover) || { pool_error 'Coordinator discovery failed'; return 2; }
    pool_trace DISCOVER complete
    if (( DRY_RUN )); then printf '%s\n' "$INITIAL_DISCOVERY"; return 0; fi
    [[ -d $OUTPUT_ROOT ]] || { pool_error 'An existing --output-root is required'; return 2; }
    OUTPUT_ROOT=$(cd -P -- "$OUTPUT_ROOT" && pwd) || return 2
    pool_root "$OUTPUT_ROOT" || { pool_error 'Output root overlaps system sources or uses unsupported characters'; return 2; }
    local POOL_UUID COORDINATOR_UUID kind h address
    IFS=$'\t' read -r kind POOL_UUID COORDINATOR_UUID <<< "$INITIAL_DISCOVERY"
    local -a HOST_IDS=(); local -A ADDRESS=() ROLE=() STATUS=() ERROR=() LOG=() ARCHIVE_PATH=() ARCHIVE_HASH=() ARCHIVE_BYTES=() REMOTE_DIR=()
    while IFS=$'\t' read -r kind h address; do
        [[ $kind == host ]] || continue
        HOST_IDS+=("$h"); ADDRESS[$h]=$address; STATUS[$h]='Not attempted'; ROLE[$h]=Member
    done <<< "$INITIAL_DISCOVERY"
    ROLE[$COORDINATOR_UUID]=Coordinator
    LAUNCH_HOST_UUID=$(pool_local_uuid); LAUNCH_HOST_UUID=${LAUNCH_HOST_UUID,,}
    pool_uuid "$LAUNCH_HOST_UUID" && [[ ${ADDRESS[$LAUNCH_HOST_UUID]+yes} ]] || { pool_error 'Local identity absent from discovery'; return 2; }
    pool_trace SELECT_SCOPE start
    pool_select_scope "${#HOST_IDS[@]}" "$REQUESTED_SCOPE" "$LAUNCH_HOST_UUID" "$COORDINATOR_UUID" || return 2
    if [[ $EFFECTIVE_SCOPE == host ]]; then HOST_IDS=("$LAUNCH_HOST_UUID"); fi
    pool_trace CHECK_ROLE complete
    if (( ${#HOST_IDS[@]} > 1 )); then
        command -v ssh >/dev/null && [[ -f $KNOWN_HOSTS && ( -z $SSH_KEY || -f $SSH_KEY ) ]] || { pool_error 'Existing SSH access, key (if supplied) and preverified known-hosts are required'; return 2; }
    fi
    local PACKAGE COLLECTOR TEMPLATE COLLECTOR_HASH TEMPLATE_HASH
    PACKAGE=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 2
    COLLECTOR=$PACKAGE/xen_config_collect.sh; TEMPLATE=$PACKAGE/pool_member_capture.sh
    [[ -f $COLLECTOR && -f $TEMPLATE ]] || { pool_error 'Keep all three Bash scripts together'; return 2; }
    (( $(stat -Lc '%s' -- "$COLLECTOR") <= 1048576 )) || return 2
    read -r COLLECTOR_HASH _ < <(sha256sum -- "$COLLECTOR")
    read -r TEMPLATE_HASH _ < <(sha256sum -- "$TEMPLATE")
    local RUN STARTED_AT FINISHED_AT='' DISCOVERY_STABLE=true COLLECTION_COMPLETE=false RETRIEVED_BYTES=0
    RUN=$(mktemp -d -- "$OUTPUT_ROOT/xen-pool-$CASE_ID-XXXXXX") || return 2
    mkdir -- "$RUN/archives" "$RUN/logs" "$RUN/coordinator-work" || return 2
    STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '%s\n' "$INITIAL_DISCOVERY" > "$RUN/discovery-initial.tsv"
    pool_manifest || return 2
    printf 'Collecting pool into %s\n' "$RUN"
    pool_space $((2*MAX_ARCHIVE*1048576)) || { pool_error "Insufficient space; partial run: $RUN"; return 2; }
    h=$LAUNCH_HOST_UUID; LOG[$h]=logs/$h.log
    pool_trace COLLECT_LOCAL start
    local -a debug_args=(); (( DEBUG_MODE == 0 )) || debug_args+=(--debug)
    if ! timeout --signal=TERM --kill-after=5 "$HOST_TIMEOUT" bash "$COLLECTOR" "${debug_args[@]}" --output-root "$RUN/coordinator-work" --case-id "$CASE_ID" --command-timeout "$COMMAND_TIMEOUT" --max-total-mib "$MAX_TOTAL" > "$RUN/${LOG[$h]}" 2>&1; then
        STATUS[$h]=Failed; ERROR[$h]='Coordinator capture failed; see log'; pool_manifest
        pool_error "Coordinator capture failed; partial run: $RUN"; return 2
    fi
    local -a sources; shopt -s nullglob; sources=("$RUN/coordinator-work"/xen-config-*.tar.gz)
    local source hash size expected
    (( ${#sources[@]} == 1 )) || { pool_error "Ambiguous coordinator archive; partial run: $RUN"; return 2; }
    source=${sources[0]}; read -r hash _ < <(sha256sum -- "$source"); size=$(stat -Lc '%s' -- "$source")
    expected=''; [[ ! -f $source.sha256 ]] || read -r expected _ < "$source.sha256"
    if [[ $hash != "$expected" ]] || (( size > MAX_ARCHIVE*1048576 || size > MAX_POOL*1048576 )); then
        STATUS[$h]=Failed; ERROR[$h]='Coordinator checksum or archive budget failure'; pool_manifest; return 2
    fi
    ARCHIVE_PATH[$h]=archives/host-$h.tar.gz
    cp -- "$source" "$RUN/${ARCHIVE_PATH[$h]}" || return 2
    ARCHIVE_HASH[$h]=$hash; ARCHIVE_BYTES[$h]=$size; STATUS[$h]=Retrieved; RETRIEVED_BYTES=$size
    printf '%s  host-%s.tar.gz\n' "$hash" "$h" > "$RUN/${ARCHIVE_PATH[$h]}.sha256"
    pool_manifest || return 2
    pool_trace COLLECT_LOCAL complete
    local payload=$RUN/member-payload.sh
    pool_payload > "$payload" || { pool_error "Payload generation failed; partial run: $RUN"; return 2; }
    local quoted_known=$KNOWN_HOSTS frame=$RUN/member-transfer.part cap blocks rc frame_bytes
    [[ $KNOWN_HOSTS != *$'\n'* && $KNOWN_HOSTS != *$'\r'* ]] || return 2
    quoted_known=${quoted_known//\\/\\\\}; quoted_known=${quoted_known//\"/\\\"}
    local -a ssh_args=(ssh -F /dev/null -T -x -p "$SSH_PORT" -l root -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=\"$quoted_known\"" -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ForwardAgent=no -o ClearAllForwardings=yes)
    [[ -z $SSH_KEY ]] || ssh_args+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
    for h in "${HOST_IDS[@]}"; do
        [[ $h != "$LAUNCH_HOST_UUID" ]] || continue
        if ! pool_guard; then DISCOVERY_STABLE=false; ERROR[$h]='Discovery changed or failed; remaining members not attempted'; break; fi
        cap=$((MAX_POOL*1048576-RETRIEVED_BYTES)); (( cap <= MAX_ARCHIVE*1048576 )) || cap=$((MAX_ARCHIVE*1048576))
        if (( cap <= 0 )) || ! pool_space $((3*cap)); then STATUS[$h]=Failed; ERROR[$h]='Retrieval budget or disk space exhausted'; pool_manifest; continue; fi
        LOG[$h]=logs/$h.ssh.log
        printf 'Collecting member %s %s\n' "$h" "${ADDRESS[$h]}"
        blocks=$(((cap+4096+1023)/1024))
        pool_trace COLLECT_MEMBER start
        pool_capture_remote
        rc=$?; frame_bytes=$(stat -Lc '%s' -- "$frame"); RETRIEVED_BYTES=$((RETRIEVED_BYTES+frame_bytes))
        # Keep at most 1 MiB of diagnostics after the bounded SSH process exits.
        head -c 1048576 -- "$RUN/${LOG[$h]}" > "$RUN/logs/trimmed.tmp" && mv -- "$RUN/logs/trimmed.tmp" "$RUN/${LOG[$h]}"
        ARCHIVE_PATH[$h]=archives/host-$h.tar.gz
        if (( rc == 0 )) && pool_receive "$frame" "$RUN/${ARCHIVE_PATH[$h]}" "$cap"; then
            STATUS[$h]=Retrieved; ARCHIVE_HASH[$h]=$RECEIVED_HASH; ARCHIVE_BYTES[$h]=$RECEIVED_SIZE; REMOTE_DIR[$h]=$RECEIVED_REMOTE
            printf '%s  host-%s.tar.gz\n' "$RECEIVED_HASH" "$h" > "$RUN/${ARCHIVE_PATH[$h]}.sha256"
        else
            STATUS[$h]=Failed; ERROR[$h]='SSH, timeout, transfer limit, frame or checksum failure; see log'
            rm -f -- "$RUN/${ARCHIVE_PATH[$h]}"; ARCHIVE_PATH[$h]=''
        fi
        pool_trace VERIFY_TRANSFER "${STATUS[$h]}"
        rm -f -- "$frame"; pool_manifest || return 2
    done
    local final
    if final=$(pool_discover); then
        printf '%s\n' "$final" > "$RUN/discovery-final.tsv"
        [[ $final == "$INITIAL_DISCOVERY" ]] || DISCOVERY_STABLE=false
    else DISCOVERY_STABLE=false; fi
    FINISHED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); pool_manifest || return 2
    local bundle=$RUN.tar.gz bytes
    bytes=$(du -sb -- "$RUN/archives" "$RUN/logs" | awk '{n+=$1} END {print n+1048576}')
    pool_space "$bytes" || { pool_error "Insufficient packaging space; run retained: $RUN"; return 2; }
    # Deliberately exclude coordinator raw files, payload and temporary transfers.
    local -a packed=(collection-manifest.json collection-status.tsv discovery-initial.tsv archives logs) tar_paths=()
    [[ ! -f $RUN/discovery-final.tsv ]] || packed+=(discovery-final.tsv)
    for value in "${packed[@]}"; do tar_paths+=("${RUN##*/}/$value"); done
    pool_trace PACKAGE start
    timeout --signal=TERM --kill-after=5 120 tar -czf "$bundle" -C "$OUTPUT_ROOT" -- "${tar_paths[@]}" || { pool_error "Packaging failed; run retained: $RUN"; return 2; }
    pool_trace PACKAGE complete
    sha256sum -- "$bundle" > "$bundle.sha256" || return 2
    printf 'Bundle: %s\nChecksum: %s.sha256\nRetrieval complete: %s (pending offline validation)\n' "$bundle" "$bundle" "$COLLECTION_COMPLETE"
    if [[ ${XEN_CHECKER_PACKAGED:-0} == 1 ]]; then
        printf 'On workstation: python3 xenserver-review.pyz review <bundle.tar.gz> --out <new-review-directory>\n'
    else
        printf 'On workstation: python3 review_collected_pool.py <bundle.tar.gz> --out <new-review-directory>\n'
    fi
    [[ $COLLECTION_COMPLETE == true ]]
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then pool_main "$@"; fi
CHECKER_04B9B55C1BEF54562CCF723B80643B225D26949437D68100CEC5C0BF4E982819
cat > "$work/xen_config_collect.sh" <<'CHECKER_4EF9736FDCEFF6331EEDC7EC34F54E075BF92781D77ECA9863E9436FDD899BD5'
#!/bin/bash
# XenServer Configuration Best Practices Checker v0.12.0
# Bash 4+, existing GNU utilities. No configuration changes or installations.
VERSION=0.12.0
usage() {
    cat <<'HELP'
Usage: bash xen_config_collect.sh --output-root /existing/directory [options]
  --debug                Bounded query-stage diagnostics on stderr.
  --case-id TEXT          Snapshot label (default case).
  --command-timeout SEC   Per-query timeout (default 30).
  --max-file-mib N        Per-file/output limit (default 4).
  --max-total-mib N       Approximate data budget (default 64).
  --max-files N           Source-file attempts (default 512).
  --no-pool-config        Local settings only; pool checks become Not assessed.
  --no-archive            Keep snapshot directory without tar.gz packaging.
  --help                 Show help.
Run as root on XenServer. Uses installed tools and read/list-only xe queries.
Writes restricted snapshot output and may create normal SSH/API audit activity.
Review and configuration drift comparison run separately on the workstation.
HELP
}
stamp() { date -u '+%Y-%m-%dT%H:%M:%S.%NZ'; }
uptick() { local up rest; read -r up rest < /proc/uptime; printf '%s' "$up"; }
esc() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
    printf '%s' "$s"
}
note() {
    printf '%s\t%s\t%s\n' "$(stamp)" "$(esc "$1")" "$(esc "$2")" >> "$CASE/meta/coverage.tsv"
}
bytes() { stat -Lc '%s' -- "$1" 2>/dev/null || printf '0'; }
check_space() {
    local free_kib
    free_kib=$(df -Pk -- "$CASE" | awk 'NR==2 {print $4}')
    if [[ ! $free_kib =~ ^[0-9]+$ ]] || (( free_kib < 131072 )); then
        note STOP 'Cannot establish at least 128 MiB free at destination'
        STOP=1
        return 1
    fi
    return 0
}
remaining() { printf '%s' "$(( TOTAL_LIMIT - USED ))"; }
budget() {
    (( STOP == 0 )) || return 1
    if (( USED >= TOTAL_LIMIT - 4096 )); then
        note STOP 'Approximate data budget exhausted; subsequent collection omitted'
        STOP=1; return 1
    fi
    return 0
}

# All evidence commands use argv, never eval. stdout/stderr are separate.
run_cmd() {
    local label=$1 seconds=$2; shift 2
    if (( ${DEBUG_MODE:-0} && SEQ < 512 )); then printf 'CHECKER stage=QUERY label=%s source=xen_config_collect.sh:%s\n' "$label" "${BASH_LINENO[0]}" >&2; fi
    LAST_RC=125
    budget || return 1
    SEQ=$((SEQ+1))
    (( SEQ % 40 != 0 )) || check_space || return 1
    local out="commands/$label.out" err="commands/$label.stderr"
    local start end before after rc argv='' arg blocks max_blocks
    for arg in "$@"; do printf -v arg '%q' "$arg"; argv+="$arg "; done
    start=$(stamp); before=$(uptick)
    max_blocks=$(( (TOTAL_LIMIT - USED) / 3072 ))
    blocks=$(( FILE_LIMIT / 1024 ))
    (( blocks <= max_blocks )) || blocks=$max_blocks
    if (( blocks < 1 )); then STOP=1; note STOP 'Insufficient data budget'; return 1; fi
    if ! command -v "$1" >/dev/null 2>&1; then
        : > "$CASE/$out"
        printf 'Command unavailable: %s\n' "$1" > "$CASE/$err"
        rc=127
        note MISSING_TOOL "$label: $1"
    else
        (
            # POSIX mode is disabled in main: Bash file-size units are 1024 bytes.
            ulimit -c 0
            ulimit -f "$blocks" || exit 125
            timeout --signal=TERM --kill-after=5 "$seconds" "$@"
        ) > "$CASE/$out" 2> "$CASE/$err"
        rc=$?
        if (( rc != 0 )); then note COMMAND_NONZERO "$label exited $rc; inspect stderr and partial stdout"; fi
    fi
    end=$(stamp); after=$(uptick)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SEQ" "$label" "$start" "$end" "$before" "$after" "$rc" "$out" "$err" "$(esc "$argv")" >> "$CASE/meta/commands.tsv"
    USED=$(( USED + $(bytes "$CASE/$out") + $(bytes "$CASE/$err") ))
    LAST_RC=$rc
    # 124: timeout; 137: killed; 153 commonly SIGXFSZ; all nonzero are retained.
    return 0
}

safe_source() {
    [[ $1 == /* && $1 != *'/../'* && $1 != */.. && $1 != *'/./'* ]]
}
copy_file() {
    local src=$1 logical=${2:-$1}
    budget || return 1
    ATTEMPTS=$((ATTEMPTS+1))
    if (( ATTEMPTS > MAX_FILES )); then note STOP 'Source-file attempt limit reached'; STOP=1; return 1; fi
    (( ATTEMPTS % 40 != 0 )) || check_space || return 1
    if ! safe_source "$src" || ! safe_source "$logical"; then note REJECTED_PATH "$src"; return 1; fi
    # Never create copied symlinks. Record their target instead; do not follow them.
    local dst="$CASE/files$logical" link="$CASE/links$logical.link.txt"
    local before after size rc state limit blocks
    if [[ -L $src ]]; then
        mkdir -p -- "${link%/*}"
        { stat --printf='type=%F mode=%a uid=%u gid=%g size=%s inode=%i device=%d mtime=%y ctime=%z atime=%x\n' -- "$src"; readlink -- "$src"; } > "$link" 2>&1
        note LINK_ONLY "$src: target recorded, target bytes not followed"
        return 0
    fi
    if [[ ! -e $src ]]; then note ABSENT "$src"; return 0; fi
    if [[ ! -f $src ]]; then note SPECIAL_NOT_READ "$src"; return 0; fi
    # A source may race/change after these observations. Records describe observations.
    size=$(bytes "$src")
    if (( size > FILE_LIMIT )); then note FILE_TOO_LARGE "$src ($size bytes)"; return 0; fi
    limit=$FILE_LIMIT; (( limit <= TOTAL_LIMIT - USED )) || limit=$((TOTAL_LIMIT-USED))
    blocks=$((limit/1024)); (( blocks > 0 )) || { STOP=1; return 1; }
    before=$(stat --printf='type=%F mode=%a uid=%u gid=%g size=%s inode=%i device=%d mtime=%y ctime=%z atime=%x' -- "$src" 2>&1)
    mkdir -p -- "${dst%/*}"
    ( ulimit -c 0; ulimit -f "$blocks" || exit 125; timeout --signal=TERM --kill-after=5 "$CMD_TIMEOUT" cp -P --preserve=timestamps -- "$src" "$dst" ) 2>> "$CASE/meta/copy-errors.log"
    rc=$?
    # cp -P avoids dereferencing a final symlink swapped in during acquisition.
    if [[ -L $dst ]]; then
        mkdir -p -- "${link%/*}"
        readlink -- "$dst" > "$link"
        rm -- "$dst"
        note SOURCE_CHANGED_TO_LINK "$src: copied link removed; target recorded"
        rc=1
    fi
    after=$(stat --printf='type=%F mode=%a uid=%u gid=%g size=%s inode=%i device=%d mtime=%y ctime=%z atime=%x' -- "$src" 2>&1)
    state=collected; (( rc == 0 )) || state=partial_or_failed
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(stamp)" "$(esc "$src")" "$(esc "files$logical")" "$rc" "$state" "$(esc "$before")" "$(esc "$after")" >> "$CASE/meta/acquisitions.tsv"
    [[ $state == collected ]] || note COPY_NONZERO "$src exited $rc; copied bytes may be incomplete"
    [[ ! -f $dst ]] || USED=$(( USED + $(bytes "$dst") ))
    return 0
}

copy_tree() {
    local root=$1 p
    budget || return 1
    if [[ -L $root || ! -d $root ]]; then copy_file "$root"; return; fi
    # Inventory filenames to disk first; do not silently drop find failures.
    local list="$CASE/meta/tree-$TREE_SEQ.paths0"
    TREE_SEQ=$((TREE_SEQ+1))
    ( ulimit -c 0; ulimit -f 1024; timeout --signal=TERM --kill-after=5 "$CMD_TIMEOUT" find -P "$root" -xdev \( -type f -o -type l \) -print0 ) > "$list" 2>> "$CASE/meta/copy-errors.log"
    local rc=$?
    (( rc == 0 )) || note TREE_INCOMPLETE "$root: enumeration exited $rc"
    while IFS= read -r -d '' p; do
        budget || break
        copy_file "$p"
    done < "$list"
}

collect_hardening() {
    # openssl x509 prints only public certificate data, even when the source PEM
    # also holds a private key. Never copy this PEM or use cat on it.
    run_cmd security-local-certificate "$CMD_TIMEOUT" openssl x509 -in /etc/xensource/xapi-ssl.pem -noout -text -dates -subject -issuer -fingerprint -sha256
    if (( ${POOL_CONFIG:-1} == 0 )); then note DISABLED_BY_OPTION 'Pool hardening inventory omitted'; return; fi
    note POOL_CONFIG_QUERY 'Read-only xe metadata via local daemon/pool coordinator; not an atomic pool snapshot; no remote-host file acquisition'
    run_cmd security-pools "$CMD_TIMEOUT" xe pool-list params=uuid,name-label,master
    run_cmd security-hosts "$CMD_TIMEOUT" xe host-list params=uuid,name-label,hostname,address,software-version,external-auth-type,external-auth-service-name,logging
    run_cmd security-networks "$CMD_TIMEOUT" xe network-list params=uuid,name-label,bridge
    run_cmd security-pifs "$CMD_TIMEOUT" xe pif-list params=uuid,host-uuid,network-uuid,device,management,currently-attached,VLAN,IP,netmask
    run_cmd security-vifs "$CMD_TIMEOUT" xe vif-list params=uuid,vm-uuid,network-uuid,device,currently-attached,MAC
    run_cmd security-vms "$CMD_TIMEOUT" xe vm-list params=uuid,name-label,power-state,resident-on,is-control-domain,is-a-template,is-a-snapshot,platform,HVM-boot-policy,HVM-boot-params
    # Default vm-list omits templates; their VIFs still appear in vif-list.
    run_cmd security-templates "$CMD_TIMEOUT" xe template-list params=uuid,name-label,power-state,resident-on,is-control-domain,is-a-template,is-a-snapshot,platform,HVM-boot-policy,HVM-boot-params
    run_cmd security-snapshots "$CMD_TIMEOUT" xe snapshot-list params=uuid,name-label,power-state,resident-on,is-control-domain,is-a-template,is-a-snapshot,platform,HVM-boot-policy,HVM-boot-params
    run_cmd security-subjects "$CMD_TIMEOUT" xe subject-list params=uuid,subject-identifier,subject-information,roles
    run_cmd security-roles "$CMD_TIMEOUT" xe role-list params=uuid,name
    local field
    for field in https-only tls-verification-enabled; do
        run_cmd "security-pool-$field" "$CMD_TIMEOUT" xe pool-list "params=uuid,$field"
    done
    for field in ssh-auto-mode ssh-enabled; do
        run_cmd "security-host-$field" "$CMD_TIMEOUT" xe host-list "params=uuid,$field"
    done
    # Optional, release-dependent evidence is preserved even if unsupported.
    for field in latest-synced-updates-applied pending-guidances pending-guidances-recommended pending-guidances-full; do
        run_cmd "security-host-$field" "$CMD_TIMEOUT" xe host-list "params=uuid,$field"
    done
    for field in last-update-sync; do
        run_cmd "security-pool-$field" "$CMD_TIMEOUT" xe pool-list "params=uuid,$field"
    done
    for field in pending-guidances pending-guidances-recommended pending-guidances-full; do
        run_cmd "security-vm-$field" "$CMD_TIMEOUT" xe vm-list "params=uuid,$field"
    done
}

collect_authorized_keys() {
    local account_file=${1:-/etc/passwd} name password uid gid gecos home shell count=0 p
    local homes_seen=$'\n'
    while IFS=: read -r name password uid gid gecos home shell; do
        count=$((count+1)); (( count <= 2048 )) || { note ACCOUNT_LIMIT 'Account enumeration limited'; break; }
        [[ $home == /* && $home != / ]] || continue
        case "$homes_seen" in *$'\n'"$home"$'\n'*) continue;; esac
        homes_seen+="$home"$'\n'
        for p in .ssh/authorized_keys .ssh/authorized_keys2; do copy_file "$home/$p"; done
    done < "$account_file"
}

# Read only known non-secret endpoint keys for local storage attachments.
# Uses the existing PBD inventory; never list device-config or retrieve passwords.
# Each xe/ip query has its own timeout/ledger entry; at most 256 attachments.
collect_storage_paths() {
    local rows="$CASE/commands/security-storage-attachments.out" pbd host sr sr_type target count=0 local_id
    [[ -f $rows ]] || return 0
    local_id=$(sed -n "s/^INSTALLATION_UUID=['\"]\([^'\"]*\)['\"]$/\1/p" /etc/xensource-inventory)
    while IFS=$'\t' read -r pbd host sr; do
        [[ $host == "$local_id" && $pbd =~ ^[a-f0-9-]{36}$ && $sr =~ ^[a-f0-9-]{36}$ ]] || continue
        count=$((count+1)); (( count <= 256 )) || { note STORAGE_PATH_LIMIT 'Further endpoint queries omitted'; break; }
        sr_type=$(timeout "$CMD_TIMEOUT" xe sr-param-get "uuid=$sr" param-name=type 2>/dev/null) || continue
        case $sr_type in
            nfs|smb) run_cmd "security-storage-target-$pbd" "$CMD_TIMEOUT" xe pbd-param-get "uuid=$pbd" param-name=device-config param-key=server;;
            lvmoiscsi|gfs2) run_cmd "security-storage-target-$pbd" "$CMD_TIMEOUT" xe pbd-param-get "uuid=$pbd" param-name=device-config param-key=target;;
            *) continue;;
        esac
        [[ $LAST_RC == 0 ]] || continue
        target=$(cat -- "$CASE/commands/security-storage-target-$pbd.out")
        # Query only numeric destinations: do not introduce a DNS lookup or scan.
        [[ $target =~ ^[0-9.]+$ || ( $target == *:* && $target =~ ^[a-fA-F0-9:]+$ ) ]] || continue
        run_cmd "security-storage-route-$pbd" "$CMD_TIMEOUT" ip -o route get "$target"
    done < <(awk '
      function emit() {if (id && host && sr) print id "\t" host "\t" sr; id=host=sr=""}
      /^uuid[[:space:]]/ {emit(); id=$NF}
      /^host-uuid[[:space:]]/ {host=$NF}
      /^sr-uuid[[:space:]]/ {sr=$NF}
      END {emit()}' "$rows")
}

collect_configuration() {
    local p
    for p in /etc/xensource-inventory /etc/passwd /etc/chrony.conf \
        /etc/ssh/sshd_config /etc/rsyslog.conf /etc/syslog.conf; do copy_file "$p"; done
    for p in /etc/rsyslog.d /etc/ssh/sshd_config.d; do copy_tree "$p"; done
    # Public authorization configuration only. No private keys or password database.
    collect_authorized_keys
    for p in /sys/firmware/efi/efivars/SecureBoot-*; do [[ ! -e $p ]] || copy_file "$p"; done
    # Record sudoers permissions without acquiring its contents.
    if [[ -f /etc/sudoers && ! -L /etc/sudoers ]]; then
        local mode
        mode=$(stat --printf='mode=%a uid=%u gid=%g' -- /etc/sudoers)
        printf '%s\t/etc/sudoers\t\t0\tmetadata_only\t%s\t%s\n' "$(stamp)" "$mode" "$mode" >> "$CASE/meta/acquisitions.tsv"
    fi
    run_cmd sshd-effective "$CMD_TIMEOUT" sshd -T
    run_cmd chronyc-tracking "$CMD_TIMEOUT" chronyc -n tracking
    run_cmd chronyc-sources "$CMD_TIMEOUT" chronyc -n sources
    run_cmd systemd-units "$CMD_TIMEOUT" systemctl list-unit-files --no-pager
    run_cmd rpm-inventory "$CMD_TIMEOUT" rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{INSTALLTIME}\n'
    # Paths only; plugin content is not acquired or inspected.
    run_cmd config-plugin-paths "$CMD_TIMEOUT" find -P /etc/xapi.d/plugins -xdev -type f -print
    if (( POOL_CONFIG == 1 )); then
        run_cmd security-pif-addresses "$CMD_TIMEOUT" xe pif-list params=uuid,host-uuid,network-uuid,IP,netmask,IPv6,currently-attached
        run_cmd security-network-locking "$CMD_TIMEOUT" xe network-list params=uuid,default-locking-mode
        run_cmd security-vif-locking "$CMD_TIMEOUT" xe vif-list params=uuid,vm-uuid,network-uuid,locking-mode,ipv4-allowed,ipv6-allowed
        run_cmd security-storage-repositories "$CMD_TIMEOUT" xe sr-list params=uuid,name-label,type,shared
        run_cmd security-storage-attachments "$CMD_TIMEOUT" xe pbd-list params=uuid,host-uuid,sr-uuid,currently-attached
        run_cmd security-guest-tools "$CMD_TIMEOUT" xe vm-list params=uuid,PV-drivers-detected,PV-drivers-version,guest-metrics-last-updated
    fi
    run_cmd security-ip-addresses "$CMD_TIMEOUT" ip -o address show
    run_cmd security-ip-routes "$CMD_TIMEOUT" ip -o route show table all
    if (( POOL_CONFIG == 1 )); then collect_storage_paths; fi

}

finalize() {
    # Called once, including on handled interruption. No further evidence commands.
    (( FINALIZED == 0 )) || return
    FINALIZED=1
    printf 'end_reported_utc=%s\nend_uptime_seconds=%s\napprox_data_bytes=%s\ncollection_stopped_by_limit=%s\n' \
        "$(stamp)" "$(uptick)" "$USED" "$STOP" >> "$CASE/meta/session.txt"
    printf '%s\n' 'Host-reported configuration snapshot; validate settings and approved exceptions with the owner.' \
        'Read meta/coverage.tsv, meta/commands.tsv and meta/acquisitions.tsv before interpreting outputs.' \
        'Empty output is not success unless exit status and context support that interpretation.' \
        'No historical logs, process data, executable bytes or integrity scans are collected.' \
        'Symlink targets were recorded rather than recursively followed.' \
        'Collection uses bounded read-only queries; only snapshot output is written.' > "$CASE/READ_ME_FIRST.txt"
    (
        cd -- "$CASE" || exit 1
        find . -type f ! -path ./SHA256SUMS ! -path ./meta/hash-errors.log -print0 | sort -z | \
            xargs -0 -r sha256sum -- > SHA256SUMS 2> meta/hash-errors.log
    )
    local rc=$?
    # Hash error log is deliberately outside the manifest; it may still be written.
    printf 'Evidence directory: %s\n' "$CASE"
    if (( rc != 0 )); then printf 'Hash manifest incomplete: inspect meta/hash-errors.log\n' >&2; return 1; fi
    if (( ARCHIVE == 1 )); then
        local archive="$CASE.tar.gz" parent=${CASE%/*} base=${CASE##*/}
        local free_kib dir_kib
        free_kib=$(df -Pk -- "$CASE" | awk 'NR==2 {print $4}')
        dir_kib=$(du -sk -- "$CASE" | awk '{print $1}')
        if [[ $free_kib =~ ^[0-9]+$ && $dir_kib =~ ^[0-9]+$ ]] && (( free_kib > dir_kib + 131072 )); then
            timeout --signal=TERM --kill-after=5 "$RPM_TIMEOUT" tar -czf "$archive" -C "$parent" -- "$base"
            rc=$?
            if (( rc == 0 )); then
                ( cd -- "$parent" && sha256sum -- "$base.tar.gz" > "$base.tar.gz.sha256" )
                printf 'Archive: %s\nHash: %s.sha256\n' "$archive" "$archive"
            else
                printf 'Archive incomplete (exit %s); use original directory; partial archive: %s\n' "$rc" "$archive" >&2
                return 1
            fi
        else
            printf 'Packaging omitted: insufficient free space; collect the directory.\n' >&2
            return 1
        fi
    fi
    return 0
}

main() {
    set +o posix
    set -u
    set -o pipefail
    umask 077
    export LC_ALL=C TZ=UTC SYSTEMD_PAGER=cat PAGER=cat
    # Prefer system utilities; do not execute programs from root's working directory.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    # Prevent inherited xe connection credentials/target overrides from silently
    # redirecting local collection to another system. Do not record their value.
    unset XE_EXTRA_ARGS
    local OUTPUT_ROOT='' CASE_ID=case
    CMD_TIMEOUT=30 RPM_TIMEOUT=120 MAX_FILE_MIB=4 MAX_TOTAL_MIB=64 MAX_FILES=512
    ARCHIVE=1 POOL_CONFIG=1 DEBUG_MODE=0
    while (( $# )); do
        case $1 in
            --help|-h) usage; return 0;;
            --debug) DEBUG_MODE=1; shift;;
            --no-pool-config) POOL_CONFIG=0; shift;;
            --no-archive) ARCHIVE=0; shift;;
            --output-root|--case-id|--command-timeout|--max-file-mib|--max-total-mib|--max-files)
                (( $# >= 2 )) || { printf 'Missing value for %s\n' "$1" >&2; return 2; }
                case $1 in
                    --output-root) OUTPUT_ROOT=$2;; --case-id) CASE_ID=$2;;
                    --command-timeout) CMD_TIMEOUT=$2;;
                    --max-file-mib) MAX_FILE_MIB=$2;; --max-total-mib) MAX_TOTAL_MIB=$2;;
                    --max-files) MAX_FILES=$2;;
                esac; shift 2;;
            *) printf 'Unknown option: %s\n' "$1" >&2; return 2;;
        esac
    done
    [[ ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Bash 4+ required\n' >&2; return 2; }
    local value
    for value in "$CMD_TIMEOUT" "$RPM_TIMEOUT" "$MAX_FILE_MIB" "$MAX_TOTAL_MIB" "$MAX_FILES"; do
        [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { printf 'Limits must be positive integers <= 999999\n' >&2; return 2; }
    done
    [[ $CASE_ID =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { printf 'Invalid case ID\n' >&2; return 2; }
    (( EUID == 0 )) || { printf 'Run as root on the XenServer host\n' >&2; return 2; }
    [[ -d $OUTPUT_ROOT ]] || { printf 'Specify an existing --output-root directory\n' >&2; return 2; }
    local required
    for required in date stat timeout sha256sum cp find sort xargs tar mktemp mkdir readlink ls mv rm df du awk cat; do
        command -v "$required" >/dev/null 2>&1 || { printf 'Required utility unavailable: %s\n' "$required" >&2; return 2; }
    done
    [[ -f /etc/xensource-inventory ]] || { printf 'XenServer inventory not found; refusing live collection on another OS\n' >&2; return 2; }
    OUTPUT_ROOT=$(cd -P -- "$OUTPUT_ROOT" && pwd) || return 2
    case "$OUTPUT_ROOT/" in
        /etc/*|/usr/*|/boot/*|/proc/*|/sys/*|/run/*|/root/*|/home/*|/var/log/*|/var/spool/*)
            printf 'Destination overlaps collection sources; use a dedicated evidence mount, /mnt, or /var/tmp\n' >&2; return 2;;
    esac
    local idstamp
    idstamp=$(date -u +%Y%m%dT%H%M%SZ)
    CASE=$(mktemp -d -- "$OUTPUT_ROOT/xen-config-$CASE_ID-$idstamp.XXXXXX") || return 2
    mkdir -p -- "$CASE/meta" "$CASE/commands" "$CASE/files" "$CASE/links"
    USED=0 STOP=0 SEQ=0 ATTEMPTS=0 TREE_SEQ=0 FINALIZED=0
    FILE_LIMIT=$((MAX_FILE_MIB * 1024 * 1024)); TOTAL_LIMIT=$((MAX_TOTAL_MIB * 1024 * 1024))
    printf 'reported_utc\tstatus\tdetail\n' > "$CASE/meta/coverage.tsv"
    printf 'sequence\tlabel\tstart_reported_utc\tend_reported_utc\tstart_uptime_s\tend_uptime_s\texit_status\tstdout\tstderr\targv_shell_escaped\n' > "$CASE/meta/commands.tsv"
    printf 'reported_utc\tsource\tdestination\texit_status\tstatus\tsource_stat_before\tsource_stat_after\n' > "$CASE/meta/acquisitions.tsv"
    printf 'schema=xenserver-config-collection/1\ncollector_version=%s\ncase_id=%s\nstart_reported_utc=%s\nstart_uptime_seconds=%s\ncommand_timeout_s=%s\nfile_limit_bytes=%s\ndata_budget_bytes=%s\nmax_files=%s\npool_config=%s\n' \
        "$VERSION" "$CASE_ID" "$(stamp)" "$(uptick)" "$CMD_TIMEOUT" "$FILE_LIMIT" "$TOTAL_LIMIT" "$MAX_FILES" "$POOL_CONFIG" > "$CASE/meta/session.txt"
    trap 'note INTERRUPTED "Signal received; collection partial"; STOP=1; finalize; exit 130' INT TERM
    check_space || { finalize; return 1; }
    printf 'Collecting into %s\n' "$CASE"
    copy_file "$(readlink -f -- "${BASH_SOURCE[0]}")" /collector/xen_config_collect.sh
    collect_hardening
    collect_configuration
    local final_rc=0
    finalize || final_rc=1
    trap - INT TERM
    (( STOP == 0 )) || final_rc=1
    return "$final_rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
CHECKER_4EF9736FDCEFF6331EEDC7EC34F54E075BF92781D77ECA9863E9436FDD899BD5
cat > "$work/pool_member_capture.sh" <<'CHECKER_DD0813AE588143E51ACAF578EE4811ADEA9B68F7FB1052118494B27B3BAD10E1'
#!/bin/bash
# Internal SSH transport template. collect_pool.sh inserts the collector payload.
# Output files are retained on the member for verification/manual cleanup.
# Stages: validate argv/identities -> capture locally -> verify -> frame archive.
# stdout belongs exclusively to the protocol; all diagnostics go to stderr.
set -u
set -o pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C TZ=UTC
unset XE_EXTRA_ARGS
[[ ${BASH_VERSINFO[0]} -ge 4 && $EUID == 0 && $# == 8 ]] || { printf 'Root, Bash 4+ and protocol arguments required\n' >&2; exit 65; }
expected_host=$1 expected_pool=$2 expected_coordinator=$3 case_id=$4 remote_root=$5 command_timeout=$6 max_total_mib=$7 host_timeout=$8
for ident in "$expected_host" "$expected_pool" "$expected_coordinator"; do
    [[ $ident =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || exit 65
done
[[ $case_id =~ ^[A-Za-z0-9._-]{1,64}$ ]] || exit 65
for limit in "$command_timeout" "$max_total_mib" "$host_timeout"; do [[ $limit =~ ^[1-9][0-9]{0,5}$ ]] || exit 65; done
[[ -f /etc/xensource-inventory ]] || { printf 'XenServer inventory missing\n' >&2; exit 65; }
actual_host=$(sed -n "s/^INSTALLATION_UUID=['\"]\([^'\"]*\)['\"]$/\1/p" /etc/xensource-inventory)
[[ ${actual_host,,} == "$expected_host" ]] || { printf 'Member host UUID mismatch; no collection started\n' >&2; exit 66; }
actual_pool=$(timeout 30 xe pool-list --minimal) || exit 67
[[ ${actual_pool,,} == "$expected_pool" ]] || { printf 'Pool UUID mismatch; no collection started\n' >&2; exit 66; }
actual_coordinator=$(timeout 30 xe pool-param-get "uuid=$expected_pool" param-name=master) || exit 67
[[ ${actual_coordinator,,} == "$expected_coordinator" ]] || { printf 'Coordinator changed; no collection started\n' >&2; exit 66; }
remote_root=$(cd -P -- "$remote_root" && pwd) || exit 65
case "$remote_root/" in
    /|/etc/*|/usr/*|/boot/*|/proc/*|/sys/*|/run/*|/root/*|/home/*|/var/log/*|/var/spool/*) printf 'Unsafe output root\n' >&2; exit 65;;
esac
work=$(mktemp -d -- "$remote_root/xen-pool-member.XXXXXX") || exit 68
printf 'Member output retained at %s\n' "$work" >&2
__XEN_COLLECTOR_PAYLOAD__
timeout --signal=TERM --kill-after=5 "$host_timeout" bash "$work/xen_config_collect.sh" --output-root "$work" --case-id "$case_id" --command-timeout "$command_timeout" --max-total-mib "$max_total_mib" > "$work/collector-console.log" 2>&1
rc=$?
if (( rc != 0 )); then cat -- "$work/collector-console.log" >&2; printf 'Member collection failed with exit %s\n' "$rc" >&2; exit 70; fi
shopt -s nullglob
archives=("$work"/xen-config-*.tar.gz)
(( ${#archives[@]} == 1 )) || { printf 'Expected exactly one output archive\n' >&2; exit 70; }
archive=${archives[0]}
# VERIFY_TRANSFER inspection point: the archive is complete before its header
# is emitted. Pausing after this point can invalidate the caller's deadline.
(cd -- "$work" && sha256sum -c -- "$archive.sha256") >&2 || exit 71
size=$(stat -Lc '%s' -- "$archive") || exit 71
read -r hash _ < <(sha256sum -- "$archive")
[[ $size =~ ^[1-9][0-9]*$ && $hash =~ ^[a-f0-9]{64}$ ]] || exit 71
printf 'XENPOOL/1\t%s\t%s\t%s\n' "$size" "$hash" "$work"
cat -- "$archive"
CHECKER_DD0813AE588143E51ACAF578EE4811ADEA9B68F7FB1052118494B27B3BAD10E1
(cd -- "$work" && printf '%s\n' '04b9b55c1bef54562ccf723b80643b225d26949437d68100cec5c0bf4e982819  collect_pool.sh' '4ef9736fdceff6331eedc7ec34f54e075bf92781d77eca9863e9436fdd899bd5  xen_config_collect.sh' 'dd0813ae588143e51acaf578ee4811adea9b68f7fb1052118494b27b3bad10e1  pool_member_capture.sh' | sha256sum --check --status) || { printf 'Embedded collection scripts failed verification\n' >&2; exit 2; }
export XEN_CHECKER_PACKAGED=1
if [[ ${1:-} == --snapshot ]]; then
  shift
  bash "$work/xen_config_collect.sh" "$@"
else
  bash "$work/collect_pool.sh" "$@"
fi
exit $?
