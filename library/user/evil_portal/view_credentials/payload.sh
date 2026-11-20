#!/bin/bash
# Title: View Credentials
# Description: Browse captured credentials from all Evil Portal sessions.
#   Scans /root/logs/credentials.json (standard evil_portal) and all
#   portal subdirectory *.jsonl / auth.jsonl logs. Displays count per
#   portal, navigate entries with joystick, formatted field display.
# Version: 1.0.0
# Category: user/evil_portal

INPUT=/dev/input/event0

# Non-blocking button check
check_button_ab() {
    local d
    d=$(timeout 0.02 dd if="$INPUT" bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [[ -z "$d" ]] && return 1
    local t; t=$(echo "$d" | cut -d' ' -f9-10)
    local v; v=$(echo "$d" | cut -d' ' -f13)
    local k; k=$(echo "$d" | cut -d' ' -f11-12)
    [[ "$t" == "01 00" && "$v" == "01" && ( "$k" == "31 01" || "$k" == "30 01" ) ]]
}

# ── Credential sources ───────────────────────────────────────────────────────────────────────────
declare -a SOURCES=()
declare -a SOURCE_LABELS=()
declare -a SOURCE_COUNTS=()
SOURCE_COUNT=0

find_sources() {
    SOURCES=(); SOURCE_LABELS=(); SOURCE_COUNTS=(); SOURCE_COUNT=0

    # Standard evil_portal: /root/logs/credentials.json
    if [[ -f "/root/logs/credentials.json" ]]; then
        local n; n=$(wc -l < "/root/logs/credentials.json" 2>/dev/null || echo 0)
        if (( n > 0 )); then
            SOURCES+=("/root/logs/credentials.json")
            SOURCE_LABELS+=("evil_portal (main)")
            SOURCE_COUNTS+=("$n")
            (( SOURCE_COUNT++ ))
        fi
    fi

    # Portal subdirectory logs: /opt/evilportal/portals/*/logs/auth.jsonl
    if [[ -d "/opt/evilportal/portals" ]]; then
        while IFS= read -r logf; do
            [[ -s "$logf" ]] || continue
            local n; n=$(wc -l < "$logf" 2>/dev/null || echo 0)
            (( n == 0 )) && continue
            local portal; portal=$(basename "$(dirname "$(dirname "$logf")")") 
            SOURCES+=("$logf")
            SOURCE_LABELS+=("portal:$portal")
            SOURCE_COUNTS+=("$n")
            (( SOURCE_COUNT++ ))
        done < <(find /opt/evilportal/portals -name "auth.jsonl" -o -name "credentials.json" \
            -o -name "*.jsonl" 2>/dev/null | sort)
    fi

    # Also check /root/evilportal and /pineapple/modules/EvilPortal style paths
    for try_base in "/root/evilportal" "/pineapple/modules/EvilPortal"; do
        [[ -d "$try_base" ]] || continue
        while IFS= read -r logf; do
            [[ -s "$logf" ]] || continue
            local n; n=$(wc -l < "$logf" 2>/dev/null || echo 0)
            (( n == 0 )) && continue
            local portal; portal=$(basename "$(dirname "$logf")")
            SOURCES+=("$logf")
            SOURCE_LABELS+=("portal:$portal")
            SOURCE_COUNTS+=("$n")
            (( SOURCE_COUNT++ ))
        done < <(find "$try_base" -name "*.jsonl" -o -name "*.json" 2>/dev/null | \
            grep -viE "(config|template|schema)" | sort)
    done
}

# ── JSON field extractor ────────────────────────────────────────────────────────────────────────────
json_field() {
    local json="$1" field="$2"
    echo "$json" | grep -o "\"${field}\":[[:space:]]*\"[^\"]*\"" | \
        sed "s/\"${field}\":[[:space:]]*\"//;s/\"$//" | head -1
}

parse_cred_line() {
    local line="$1"
    local ts="" portal="" ip="" user="" pass=""

    ts=$(json_field "$line" "timestamp")
    [[ -z "$ts" ]] && ts=$(json_field "$line" "time")
    [[ -z "$ts" ]] && ts=$(json_field "$line" "date")

    portal=$(json_field "$line" "portal")
    ip=$(json_field "$line" "ip")

    user=$(json_field "$line" "username")
    [[ -z "$user" ]] && user=$(json_field "$line" "user")
    [[ -z "$user" ]] && user=$(json_field "$line" "email")
    [[ -z "$user" ]] && user=$(json_field "$line" "login")

    pass=$(json_field "$line" "password")
    [[ -z "$pass" ]] && pass=$(json_field "$line" "pass")
    [[ -z "$pass" ]] && pass=$(json_field "$line" "passwd")

    echo "TS:$ts|PORTAL:$portal|IP:$ip|USER:$user|PASS:$pass"
}

# ── Source picker ─────────────────────────────────────────────────────────────────────────────────────
SEL_SRC=0

show_source_list() {
    LOG ""
    LOG "  ╔══════════════════════════════╗"
    LOG "  ║  Credential Logs  v1.0.0    ║"
    LOG "  ╚══════════════════════════════╝"
    LOG ""
    if [[ $SOURCE_COUNT -eq 0 ]]; then
        LOG "  No credential logs found."
        LOG ""
        LOG "  Checked:"
        LOG "   /root/logs/credentials.json"
        LOG "   /opt/evilportal/portals/*/logs/"
        return
    fi
    LOG "  Found $SOURCE_COUNT log source(s):"
    LOG "  ──────────────────────────────"
    local i
    for (( i=0; i<SOURCE_COUNT; i++ )); do
        local arrow="   "
        [[ $i -eq $SEL_SRC ]] && arrow=" >>"
        LOG "$arrow  [${SOURCE_COUNTS[$i]}] ${SOURCE_LABELS[$i]}"
    done
    LOG ""
    LOG "  [UP/DOWN] select  [A] open"
    LOG "  [B] exit"
}

pick_source() {
    SEL_SRC=0
    show_source_list
    [[ $SOURCE_COUNT -eq 0 ]] && return 1
    while true; do
        case "$(WAIT_FOR_INPUT)" in
            UP|LEFT)
                (( SEL_SRC-- ))
                (( SEL_SRC < 0 )) && SEL_SRC=$(( SOURCE_COUNT - 1 ))
                show_source_list ;;
            DOWN|RIGHT)
                (( SEL_SRC++ ))
                (( SEL_SRC >= SOURCE_COUNT )) && SEL_SRC=0
                show_source_list ;;
            A) return 0 ;;
            B|BACK) return 1 ;;
        esac
    done
}

# ── Credential browser ────────────────────────────────────────────────────────────────────────────────────
browse_source() {
    local filepath="$1" label="$2"
    local -a entries=()
    local idx=0

    LOG ""
    LOG "  Loading $label..."
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        entries+=("$line")
    done < "$filepath"

    local total=${#entries[@]}
    if (( total == 0 )); then
        LOG "  No entries found in log."
        WAIT_FOR_INPUT >/dev/null
        return
    fi

    idx=0

    _show_cred() {
        local parsed; parsed=$(parse_cred_line "${entries[$idx]}")
        local ts; ts=$(echo "$parsed" | grep -o 'TS:[^|]*' | sed 's/TS://')
        local portal; portal=$(echo "$parsed" | grep -o 'PORTAL:[^|]*' | sed 's/PORTAL://')
        local ip; ip=$(echo "$parsed" | grep -o 'IP:[^|]*' | sed 's/IP://')
        local user; user=$(echo "$parsed" | grep -o 'USER:[^|]*' | sed 's/USER://')
        local pass; pass=$(echo "$parsed" | grep -o 'PASS:[^|]*' | sed 's/PASS://')

        [[ -z "$portal" ]] && portal="$label"

        LOG ""
        LOG "  [$((idx+1))/$total]  $label"
        LOG "  ──────────────────────────"
        [[ -n "$ts"     ]] && LOG "  TIME   : $ts"
        [[ -n "$portal" ]] && LOG "  PORTAL : $portal"
        [[ -n "$ip"     ]] && LOG "  IP     : $ip"
        LOG "  USER   : ${user:-(none)}"
        LOG "  PASS   : ${pass:-(none)}"
        LOG ""
        LOG "  [UP/DOWN] navigate"
        LOG "  [A] copy path  [B] back"
    }

    _show_cred
    while true; do
        case "$(WAIT_FOR_INPUT)" in
            UP|LEFT)
                (( idx-- ))
                (( idx < 0 )) && idx=$(( total - 1 ))
                _show_cred ;;
            DOWN|RIGHT)
                (( idx++ ))
                (( idx >= total )) && idx=0
                _show_cred ;;
            A)
                LOG ""
                LOG "  File: $filepath"
                LOG "  Total entries: $total"
                LOG "  Current: #$((idx+1))"
                ALERT "Log file:\n$filepath\n\nEntries: $total\n\nExport:\ncat $filepath"
                ;;
            B|BACK) return ;;
        esac
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
LOG ""
LOG "  Scanning for credential logs..."
find_sources
LOG "  Found $SOURCE_COUNT source(s)"

if ! pick_source; then
    LOG "  Exited."
    exit 0
fi

while true; do
    browse_source "${SOURCES[$SEL_SRC]}" "${SOURCE_LABELS[$SEL_SRC]}"
    if [[ "$(CONFIRMATION_DIALOG "View another log?\n\n[A]=Yes  [B]=Exit")" != "1" ]]; then
        break
    fi
    if ! pick_source; then
        break
    fi
done

LOG ""
LOG "  View Credentials -- done."
