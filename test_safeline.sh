#!/bin/bash

# ==============================================================================
# SafeLine WAF IP Group Manager (test_safeline.sh)
# Mengelola penambahan, pengecekan, dan penghapusan IP pada SafeLine WAF IP Group
# ==============================================================================

# Direktori skrip
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fungsi untuk memuat file .env dengan aman (membersihkan \r dan whitespace)
load_env_file() {
    local target_file="$1"
    if [ -f "$target_file" ]; then
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            local line
            line=$(echo "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ ! "$line" =~ ^# ]] && [[ "$line" == *"="* ]]; then
                local key val
                key=$(echo "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                val=$(echo "$val" | sed 's/^["'"'"']//;s/["'"'"']$//')
                if [ -n "$key" ]; then
                    export "$key"="$val"
                fi
            fi
        done < "$target_file"
    fi
}

# 1. Muat dari .env lokal
load_env_file "$DIR/.env"

# 2. Fallback muat dari direktori induk jika belum lengkap
if [ -z "$SAFELINE_URL" ] || [ -z "$SAFELINE_TOKEN" ] || [ -z "$SAFELINE_GROUP" ]; then
    load_env_file "$DIR/../.env"
fi

# Normalisasi URL SafeLine (pastikan diawali https:// atau http:// dan tanpa trailing slash)
normalize_url() {
    local url="$SAFELINE_URL"
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi
    echo "${url%/}"
}

# Validasi variabel konfigurasi SafeLine
validate_config() {
    if [ -z "$SAFELINE_URL" ] || [ -z "$SAFELINE_TOKEN" ] || [ -z "$SAFELINE_GROUP" ]; then
        echo "=========================================="
        echo "ERROR: Konfigurasi SafeLine belum lengkap!"
        echo "=========================================="
        echo "Pastikan variabel berikut sudah diset di .env:"
        [ -z "$SAFELINE_URL" ] && echo "  - SAFELINE_URL (Belum diisi)"
        [ -z "$SAFELINE_TOKEN" ] && echo "  - SAFELINE_TOKEN (Belum diisi)"
        [ -z "$SAFELINE_GROUP" ] && echo "  - SAFELINE_GROUP (Belum diisi)"
        echo "------------------------------------------"
        exit 1
    fi
}

BASE_URL=$(normalize_url)

# Eksekutor HTTP Universal (Curl dengan fallback ke Python jika curl tidak ada)
http_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local full_url="${BASE_URL}${endpoint}"

    if command -v curl >/dev/null 2>&1; then
        local curl_args=(-k -s -w "\nHTTP_STATUS:%{http_code}" -X "$method" "$full_url" \
            -H "X-SLCE-API-TOKEN: ${SAFELINE_TOKEN}" \
            -H "Content-Type: application/json")
        if [ -n "$data" ]; then
            curl_args+=(--data "$data")
        fi
        curl "${curl_args[@]}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, urllib.request, ssl, json
ctx = ssl._create_unverified_context()
req = urllib.request.Request('''$full_url''', method='''$method''')
req.add_header('X-SLCE-API-TOKEN', '''$SAFELINE_TOKEN''')
req.add_header('Content-Type', 'application/json')
data_str = '''$data'''.strip()
if data_str:
    req.data = data_str.encode('utf-8')
try:
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
        body = resp.read().decode('utf-8')
        code = resp.getcode()
        print(body)
        print(f'HTTP_STATUS:{code}')
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8') if e.fp else ''
    print(body)
    print(f'HTTP_STATUS:{e.code}')
except Exception as e:
    print(json.dumps({'error': str(e)}))
    print('HTTP_STATUS:000')
"
    else
        echo '{"error": "curl atau python3 tidak ditemukan"}'
        echo "HTTP_STATUS:000"
    fi
}

# Helper untuk memformat output JSON
format_json() {
    local json_input="$1"
    if command -v python3 >/dev/null 2>&1; then
        echo "$json_input" | python3 -m json.tool 2>/dev/null || echo "$json_input"
    else
        echo "$json_input"
    fi
}

# Fungsi: Ambil detail data IP Group dari SafeLine
get_ip_group_data() {
    local response
    response=$(http_request "GET" "/api/open/ipgroup" "")
    local body
    body=$(echo "$response" | grep -v "HTTP_STATUS:")
    echo "$body"
}

# Fungsi: Cari apakah IP ada di dalam SafeLine Group
action_search() {
    local target_ip="$1"
    echo "===> Mencari IP di SafeLine IP Group ($SAFELINE_GROUP)..."
    echo "Target URL   : $BASE_URL"
    echo "Target Query : ${target_ip:-<Semua Item>}"
    echo "------------------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, json

target_group = int('$SAFELINE_GROUP') if '$SAFELINE_GROUP'.isdigit() else '$SAFELINE_GROUP'
target_ip = '$target_ip'.strip()

try:
    res = json.loads('''$raw_data''')
    data = res.get('data', [])
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get('nodes', [])
        if not nodes and data.get('id') == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get('id') == target_group:
            matched_group = g
            break

    if not matched_group:
        print(f'ERROR: IP Group ID {target_group} tidak ditemukan di SafeLine WAF.')
        sys.exit(1)

    group_name = matched_group.get('comment') or matched_group.get('name') or f'Group #{target_group}'
    ips = matched_group.get('ips', [])

    print(f'Group ID      : {target_group} ({group_name})')
    print(f'Total IP      : {len(ips)} IP')
    print('------------------------------------------')

    if target_ip:
        if target_ip in ips:
            print(f'Status        : DITEMUKAN (IP {target_ip} ada di dalam SafeLine Blacklist)')
        else:
            print(f'Status        : TIDAK DITEMUKAN (IP {target_ip} belum terdaftar)')
    else:
        print('Daftar IP di dalam Group:')
        for ip in ips:
            print(f'  - {ip}')
except Exception as e:
    print('Gagal memproses data SafeLine:', e)
    sys.exit(1)
"
    else
        format_json "$raw_data"
    fi
    echo "------------------------------------------"
}

# Fungsi: Tambah IP ke SafeLine IP Group (PUT array)
action_add() {
    local target_ip="$1"
    local comment="${2:-Added via Blackened Threat Intel}"

    if [ -z "$target_ip" ]; then
        echo "ERROR: Alamat IP target tidak boleh kosong."
        echo "Penggunaan: $0 add <ip_address> [komentar]"
        exit 1
    fi

    echo "===> Menambahkan IP ke SafeLine WAF Group ($SAFELINE_GROUP)..."
    echo "Target URL   : $BASE_URL"
    echo "Target IP    : $target_ip"
    echo "------------------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    local update_payload
    update_payload=$(python3 -c "
import sys, json

target_group = int('$SAFELINE_GROUP') if '$SAFELINE_GROUP'.isdigit() else '$SAFELINE_GROUP'
target_ip = '$target_ip'.strip()

try:
    res = json.loads('''$raw_data''')
    data = res.get('data', [])
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get('nodes', [])
        if not nodes and data.get('id') == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get('id') == target_group:
            matched_group = g
            break

    if not matched_group:
        print('GROUP_NOT_FOUND')
        sys.exit(0)

    ips = list(matched_group.get('ips', []))
    if target_ip in ips:
        print('ALREADY_EXISTS')
        sys.exit(0)

    ips.append(target_ip)
    payload = {
        'id': matched_group.get('id', target_group),
        'comment': matched_group.get('comment', 'Managed by Blackened Threat Intel'),
        'reference': matched_group.get('reference', ''),
        'ips': ips
    }
    print(json.dumps(payload))
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null)

    if [ "$update_payload" = "GROUP_NOT_FOUND" ]; then
        echo "ERROR: IP Group ID $SAFELINE_GROUP tidak ditemukan di SafeLine WAF."
        exit 1
    elif [ "$update_payload" = "ALREADY_EXISTS" ]; then
        echo "Info: IP $target_ip sudah terdaftar di SafeLine IP Group $SAFELINE_GROUP."
        echo "Tidak ada perubahan yang diperlukan."
        return 0
    elif [[ "$update_payload" =~ ^ERROR: ]]; then
        echo "Gagal menyiapkan payload SafeLine: $update_payload"
        exit 1
    fi

    local response http_code body
    response=$(http_request "PUT" "/api/open/ipgroup" "$update_payload")
    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"
    echo "------------------------------------------"
}

# Fungsi: Hapus IP dari SafeLine IP Group (PUT array tanpa IP tersebut)
action_delete() {
    local target_ip="$1"

    if [ -z "$target_ip" ]; then
        echo "ERROR: Alamat IP target tidak boleh kosong."
        echo "Penggunaan: $0 delete <ip_address>"
        exit 1
    fi

    echo "===> Menghapus IP dari SafeLine WAF Group ($SAFELINE_GROUP)..."
    echo "Target URL   : $BASE_URL"
    echo "Target IP    : $target_ip"
    echo "------------------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    local update_payload
    update_payload=$(python3 -c "
import sys, json

target_group = int('$SAFELINE_GROUP') if '$SAFELINE_GROUP'.isdigit() else '$SAFELINE_GROUP'
target_ip = '$target_ip'.strip()

try:
    res = json.loads('''$raw_data''')
    data = res.get('data', [])
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get('nodes', [])
        if not nodes and data.get('id') == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get('id') == target_group:
            matched_group = g
            break

    if not matched_group:
        print('GROUP_NOT_FOUND')
        sys.exit(0)

    ips = list(matched_group.get('ips', []))
    if target_ip not in ips:
        print('NOT_IN_GROUP')
        sys.exit(0)

    ips.remove(target_ip)
    payload = {
        'id': matched_group.get('id', target_group),
        'comment': matched_group.get('comment', 'Managed by Blackened Threat Intel'),
        'reference': matched_group.get('reference', ''),
        'ips': ips
    }
    print(json.dumps(payload))
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null)

    if [ "$update_payload" = "GROUP_NOT_FOUND" ]; then
        echo "ERROR: IP Group ID $SAFELINE_GROUP tidak ditemukan di SafeLine WAF."
        exit 1
    elif [ "$update_payload" = "NOT_IN_GROUP" ]; then
        echo "Info: IP $target_ip tidak ditemukan dalam SafeLine IP Group $SAFELINE_GROUP."
        echo "Tidak ada item yang perlu dihapus."
        return 0
    elif [[ "$update_payload" =~ ^ERROR: ]]; then
        echo "Gagal menyiapkan payload SafeLine: $update_payload"
        exit 1
    fi

    local response http_code body
    response=$(http_request "PUT" "/api/open/ipgroup" "$update_payload")
    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"
    echo "------------------------------------------"
}

# Tampilkan petunjuk penggunaan
show_usage() {
    echo "SafeLine WAF IP Group Management Tool"
    echo "Penggunaan:"
    echo "  $0 add <ip_address> [komentar]    Tambah IP ke SafeLine IP Group"
    echo "  $0 delete <ip_address>            Hapus IP dari SafeLine IP Group"
    echo "  $0 search [ip_address]            Cari IP di dalam SafeLine Group"
    echo "  $0 list                           Tampilkan seluruh IP di group"
    echo "  $0 info / count                   Lihat total IP & info group"
    echo ""
    echo "Contoh:"
    echo "  $0 add 213.232.122.217"
    echo "  $0 delete 213.232.122.217"
    echo "  $0 search 213.232.122.217"
    echo "  $0 list"
    echo "  $0 info"
}

# Main Dispatcher
ACTION="$1"

if [ -z "$ACTION" ] || [ "$ACTION" = "help" ] || [ "$ACTION" = "--help" ] || [ "$ACTION" = "-h" ]; then
    show_usage
    exit 0
fi

validate_config

case "$ACTION" in
    add)
        shift
        action_add "$@"
        ;;
    del|delete|remove|rm)
        shift
        action_delete "$@"
        ;;
    search|find)
        shift
        action_search "$@"
        ;;
    list|ls)
        action_search ""
        ;;
    info|count|total|status)
        action_search ""
        ;;
    *)
        if [[ "$ACTION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ACTION" =~ : ]]; then
            action_add "$@"
        else
            echo "Aksi tidak dikenal: $ACTION"
            echo ""
            show_usage
            exit 1
        fi
        ;;
esac
