#!/bin/bash

# ==============================================================================
# Cloudflare Rules Lists Manager (test_cf.sh)
# Mengelola penambahan, pengecekan, dan penghapusan IP pada Cloudflare List
# ==============================================================================

# Direktori skrip
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fungsi untuk memuat file .env dengan aman (membersihkan \r dan whitespace)
load_env_file() {
    local target_file="$1"
    if [ -f "$target_file" ]; then
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            # Bersihkan carriage return (\r) dan whitespace di ujung
            local line
            line=$(echo "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ ! "$line" =~ ^# ]] && [[ "$line" == *"="* ]]; then
                local key val
                key=$(echo "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Hapus tanda kutip tunggal atau ganda pembungkus nilai jika ada
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
if [ -z "$CLOUDFLARE_ACCOUNT_ID" ] || [ -z "$CLOUDFLARE_API_TOKEN" ] || [ -z "$CLOUDFLARE_LIST_ID" ]; then
    load_env_file "$DIR/../.env"
fi

# Validasi variabel konfigurasi Cloudflare
validate_config() {
    if [ -z "$CLOUDFLARE_ACCOUNT_ID" ] || [ -z "$CLOUDFLARE_API_TOKEN" ] || [ -z "$CLOUDFLARE_LIST_ID" ]; then
        echo "=========================================="
        echo "ERROR: Konfigurasi Cloudflare belum lengkap!"
        echo "=========================================="
        echo "Pastikan variabel berikut sudah diset di .env:"
        [ -z "$CLOUDFLARE_ACCOUNT_ID" ] && echo "  - CLOUDFLARE_ACCOUNT_ID (Belum diisi)"
        [ -z "$CLOUDFLARE_API_TOKEN" ] && echo "  - CLOUDFLARE_API_TOKEN (Belum diisi)"
        [ -z "$CLOUDFLARE_LIST_ID" ] && echo "  - CLOUDFLARE_LIST_ID (Belum diisi)"
        echo "--------------------------------"
        exit 1
    fi
}

# Helper untuk menyiapkan header otentikasi (Otomatis deteksi API Token vs Global API Key)
build_auth_headers() {
    AUTH_HEADERS=()
    if [[ "$CLOUDFLARE_API_TOKEN" =~ ^cfk_ ]] || [ -n "$CLOUDFLARE_EMAIL" ]; then
        local cf_email="${CLOUDFLARE_EMAIL:-$GIT_USER_EMAIL}"
        if [ -z "$cf_email" ]; then
            echo "=========================================="
            echo "ERROR: Global API Key (cfk_...) terdeteksi!"
            echo "=========================================="
            echo "Global API Key memerlukan email akun Cloudflare."
            echo "Pastikan variabel berikut diset di .env:"
            echo "  CLOUDFLARE_EMAIL=\"email_anda@domain.com\""
            echo "--------------------------------"
            exit 1
        fi
        AUTH_HEADERS=(-H "X-Auth-Email: $cf_email" -H "X-Auth-Key: $CLOUDFLARE_API_TOKEN")
    else
        AUTH_HEADERS=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
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

# Fungsi: Cari ID item berdasarkan IP di Cloudflare List
find_item_id_by_ip() {
    local ip="$1"
    build_auth_headers
    local response
    response=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/rules/lists/${CLOUDFLARE_LIST_ID}/items?search=${ip}" \
        "${AUTH_HEADERS[@]}" \
        -H "Content-Type: application/json")

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, json
try:
    data = json.loads('''$response''')
    items = data.get('result', [])
    for it in items:
        if it.get('ip') == '$ip':
            print(it.get('id', ''))
            sys.exit(0)
except Exception:
    pass
print('')
" 2>/dev/null
    else
        echo "$response" | grep -o '"id":"[a-f0-9]*"' | head -n1 | cut -d'"' -f4
    fi
}

# Fungsi: Tambah IP ke List (POST)
action_add() {
    local target_ip="$1"
    local comment="${2:-Added via Blackened Threat Intel}"

    if [ -z "$target_ip" ]; then
        echo "ERROR: Alamat IP target tidak boleh kosong."
        echo "Penggunaan: $0 add <ip_address> [komentar]"
        exit 1
    fi

    echo "Menambahkan IP ke Cloudflare List..."
    echo "Target List ID : $CLOUDFLARE_LIST_ID"
    echo "Target IP      : $target_ip"
    echo "Komentar       : $comment"
    echo "--------------------------------"

    build_auth_headers
    local response http_code body
    response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
        "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/rules/lists/${CLOUDFLARE_LIST_ID}/items" \
        "${AUTH_HEADERS[@]}" \
        -H "Content-Type: application/json" \
        --data "[
            {
                \"ip\": \"${target_ip}\",
                \"comment\": \"${comment}\"
            }
        ]")

    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"
    echo "--------------------------------"
}

# Fungsi: Hapus IP dari List (DELETE via Item ID)
action_delete() {
    local target_ip="$1"

    if [ -z "$target_ip" ]; then
        echo "ERROR: Alamat IP target tidak boleh kosong."
        echo "Penggunaan: $0 delete <ip_address>"
        exit 1
    fi

    echo "Mencari ID untuk IP: $target_ip pada Cloudflare List..."
    local item_id
    item_id=$(find_item_id_by_ip "$target_ip")

    if [ -z "$item_id" ]; then
        echo "Peringatan: IP $target_ip tidak ditemukan dalam List ID $CLOUDFLARE_LIST_ID."
        echo "Tidak ada item yang perlu dihapus."
        return 0
    fi

    echo "Ditemukan Item ID: $item_id"
    echo "Mengirim request penghapusan ke Cloudflare..."
    echo "--------------------------------"

    build_auth_headers
    local response http_code body
    response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X DELETE \
        "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/rules/lists/${CLOUDFLARE_LIST_ID}/items" \
        "${AUTH_HEADERS[@]}" \
        -H "Content-Type: application/json" \
        --data "{
            \"items\": [
                {
                    \"id\": \"${item_id}\"
                }
            ]
        }")

    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"
    echo "--------------------------------"
}

# Fungsi: Cari / Cek IP di List (GET)
action_search() {
    local target_ip="$1"
    echo "Mencari IP di Cloudflare List ($CLOUDFLARE_LIST_ID)..."
    echo "Target Query: ${target_ip:-<Semua Item>}"
    echo "--------------------------------"

    local url="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/rules/lists/${CLOUDFLARE_LIST_ID}/items"
    if [ -n "$target_ip" ]; then
        url="${url}?search=${target_ip}"
    fi

    build_auth_headers
    local response http_code body
    response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X GET "$url" \
        "${AUTH_HEADERS[@]}" \
        -H "Content-Type: application/json")

    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"
    echo "--------------------------------"
}

# Fungsi: Ambil Informasi & Total Item List (GET metadata)
action_info() {
    echo "Mengambil Informasi & Total IP List ($CLOUDFLARE_LIST_ID)..."
    echo "--------------------------------"

    local url="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/rules/lists/${CLOUDFLARE_LIST_ID}"

    build_auth_headers
    local response http_code body
    response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X GET "$url" \
        "${AUTH_HEADERS[@]}" \
        -H "Content-Type: application/json")

    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"

    if command -v python3 >/dev/null 2>&1; then
        local total_items list_name
        total_items=$(python3 -c "import sys, json; data = json.loads('''$body'''); print(data.get('result', {}).get('num_items', ''))" 2>/dev/null)
        list_name=$(python3 -c "import sys, json; data = json.loads('''$body'''); print(data.get('result', {}).get('name', ''))" 2>/dev/null)
        if [ -n "$total_items" ]; then
            echo "--------------------------------"
            echo "Nama List      : $list_name"
            echo "Total IP (Result): $total_items IP"
        fi
    fi
    echo "--------------------------------"
}

# Tampilkan petunjuk penggunaan
show_usage() {
    echo "Cloudflare Rules List Management Tool"
    echo "Penggunaan:"
    echo "  $0 add <ip_address> [komentar]    Tambah IP ke list"
    echo "  $0 delete <ip_address>            Hapus IP dari list"
    echo "  $0 search [ip_address]            Cari item di dalam list"
    echo "  $0 list                           Tampilkan daftar item di list (per halaman)"
    echo "  $0 info / count                   Lihat total keseluruhan IP & informasi list"
    echo ""
    echo "Contoh:"
    echo "  $0 add 213.232.122.217 \"Manual Blocked Scanner\""
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
        action_info
        ;;
    *)
        # Jika argumen pertama langsung berupa IP, jalankan action add sebagai default
        if [[ "$ACTION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ACTION" =~ : ]]; then
            action_add "$@"
        elif [ -z "$ACTION" ]; then
            show_usage
        else
            echo "Aksi tidak dikenal: $ACTION"
            echo ""
            show_usage
            exit 1
        fi
        ;;
esac
