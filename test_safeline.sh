#!/bin/bash

# ==============================================================================
# SafeLine WAF IP Group Manager (test_safeline.sh)
# Mengelola penambahan, pengecekan, dan penghapusan IP pada SafeLine WAF IP Group
# Memastikan seluruh IP existing tetap dipertahankan saat menambahkan IP baru.
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
        echo "--------------------------------"
        exit 1
    fi
}

BASE_URL=$(normalize_url)

# Eksekutor HTTP Universal (Curl dengan timeout & fallback ke Python jika curl tidak ada)
http_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local full_url="${BASE_URL}${endpoint}"

    if command -v curl >/dev/null 2>&1; then
        local curl_args=(-k -s --connect-timeout 10 --max-time 30 -w "\nHTTP_STATUS:%{http_code}" -X "$method" "$full_url" \
            -H "X-SLCE-API-TOKEN: ${SAFELINE_TOKEN}" \
            -H "Content-Type: application/json")
        if [ -n "$data" ]; then
            curl_args+=(--data "$data")
        fi
        curl "${curl_args[@]}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys, urllib.request, ssl, json

full_url = sys.argv[1]
method = sys.argv[2]
token = sys.argv[3]
data_str = sys.argv[4].strip() if len(sys.argv) > 4 else ""

ctx = ssl._create_unverified_context()
req = urllib.request.Request(full_url, method=method)
req.add_header("X-SLCE-API-TOKEN", token)
req.add_header("Content-Type", "application/json")
if data_str:
    req.data = data_str.encode("utf-8")

try:
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        body = resp.read().decode("utf-8")
        code = resp.getcode()
        print(body)
        print(f"HTTP_STATUS:{code}")
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8") if e.fp else ""
    print(body)
    print(f"HTTP_STATUS:{e.code}")
except Exception as e:
    print(json.dumps({"error": str(e)}))
    print("HTTP_STATUS:000")
' "$full_url" "$method" "$SAFELINE_TOKEN" "$data"
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
# Catatan penting: SafeLine memerlukan parameter query ?top=... agar array ips dikembalikan lengkap.
# Jika query tanpa ?top, SafeLine secara default hanya mengembalikan ips: [] (ringkasan kosong).
get_ip_group_data() {
    local response
    response=$(http_request "GET" "/api/open/ipgroup?top=50000" "")
    local body
    body=$(echo "$response" | grep -v "HTTP_STATUS:")
    echo "$body"
}

# Fungsi: Cari apakah IP ada di dalam SafeLine Group
action_search() {
    local target_ip="$1"
    echo "===> Mencari IP di SafeLine IP Group ($SAFELINE_GROUP)..."
    echo "Target Query : ${target_ip:-<Semua Item>}"
    echo "--------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    if command -v python3 >/dev/null 2>&1; then
        echo "$raw_data" | python3 -c '
import sys, json

target_group_raw = sys.argv[1]
target_group = int(target_group_raw) if target_group_raw.isdigit() else target_group_raw
target_ip = sys.argv[2].strip() if len(sys.argv) > 2 else ""

try:
    res = json.load(sys.stdin)
    data = res.get("data", {})
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get("nodes", [])
        if not nodes and data.get("id") == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get("id") == target_group:
            matched_group = g
            break

    if not matched_group:
        print(f"ERROR: IP Group ID {target_group} tidak ditemukan di SafeLine WAF.")
        sys.exit(1)

    group_name = matched_group.get("comment") or matched_group.get("name") or f"Group #{target_group}"
    ips = matched_group.get("ips") or []
    total = matched_group.get("total", len(ips))

    print(f"Group ID      : {target_group} ({group_name})")
    print(f"Total IP      : {len(ips)} IP (Laporan API: {total})")
    print("--------------------------------")

    if target_ip:
        if target_ip in ips:
            print(f"Status        : DITEMUKAN (IP {target_ip} ada di dalam SafeLine Group #{target_group})")
        else:
            print(f"Status        : TIDAK DITEMUKAN (IP {target_ip} belum terdaftar)")
    else:
        print("Daftar IP di dalam Group:")
        for ip in ips:
            print(f"  - {ip}")
except Exception as e:
    print("Gagal memproses data SafeLine:", e)
    sys.exit(1)
' "$SAFELINE_GROUP" "$target_ip"
    else
        format_json "$raw_data"
    fi
    echo "--------------------------------"
}

# Fungsi: Tambah IP ke SafeLine IP Group (PUT array dengan mempertahankan seluruh IP existing)
action_add() {
    local target_ip="$1"
    local comment="${2:-Added via Blackened Threat Intel}"

    if [ -z "$target_ip" ]; then
        echo "ERROR: Alamat IP target tidak boleh kosong."
        echo "Penggunaan: $0 add <ip_address> [komentar]"
        exit 1
    fi

    echo "===> Menambahkan IP ke SafeLine WAF Group ($SAFELINE_GROUP)..."
    echo "Target IP    : $target_ip"
    echo "--------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    local py_output
    py_output=$(echo "$raw_data" | python3 -c '
import sys, json

target_group_raw = sys.argv[1]
target_group = int(target_group_raw) if target_group_raw.isdigit() else target_group_raw
target_ip = sys.argv[2].strip()
comment_arg = sys.argv[3].strip() if len(sys.argv) > 3 else "Managed by Blackened Threat Intel"

try:
    res = json.load(sys.stdin)
    data = res.get("data", {})
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get("nodes", [])
        if not nodes and data.get("id") == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get("id") == target_group:
            matched_group = g
            break

    if not matched_group:
        print("GROUP_NOT_FOUND")
        sys.exit(0)

    existing_ips = list(matched_group.get("ips") or [])
    total_reported = matched_group.get("total", len(existing_ips))

    # FAIL-SAFE: Cegah penimpaan/overwrite jika data SafeLine belum lengkap
    if total_reported > len(existing_ips):
        print(f"ERROR:Data tidak lengkap. SafeLine melaporkan {total_reported} IP namun hanya {len(existing_ips)} yang terambil. Batalkan update untuk mencegah data hilang.")
        sys.exit(0)

    if target_ip in existing_ips:
        print(f"ALREADY_EXISTS:{len(existing_ips)}")
        sys.exit(0)

    # Tambahkan IP baru ke daftar existing tanpa menghapus IP lama
    new_ips = list(existing_ips)
    new_ips.append(target_ip)

    group_comment = matched_group.get("comment") or comment_arg
    payload = {
        "id": matched_group.get("id", target_group),
        "comment": group_comment,
        "reference": matched_group.get("reference", ""),
        "ips": new_ips
    }

    result = {
        "status": "OK",
        "count_before": len(existing_ips),
        "count_after": len(new_ips),
        "group_name": group_comment,
        "payload": payload
    }
    print("SUCCESS:" + json.dumps(result))
except Exception as e:
    print("ERROR:" + str(e))
' "$SAFELINE_GROUP" "$target_ip" "$comment")

    if [ "$py_output" = "GROUP_NOT_FOUND" ]; then
        echo "ERROR: IP Group ID $SAFELINE_GROUP tidak ditemukan di SafeLine WAF."
        exit 1
    elif [[ "$py_output" =~ ^ALREADY_EXISTS: ]]; then
        local current_count
        current_count=$(echo "$py_output" | cut -d: -f2)
        echo "Info: IP $target_ip sudah terdaftar di SafeLine IP Group $SAFELINE_GROUP (Total: $current_count IP)."
        echo "Tidak ada perubahan yang diperlukan."
        return 0
    elif [[ "$py_output" =~ ^ERROR: ]]; then
        echo "Gagal menyiapkan payload SafeLine: ${py_output#ERROR:}"
        exit 1
    elif [[ ! "$py_output" =~ ^SUCCESS: ]]; then
        echo "Respons parsing SafeLine tidak terduga: $py_output"
        exit 1
    fi

    local json_result count_before count_after update_payload
    json_result="${py_output#SUCCESS:}"
    count_before=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_before'])" "$json_result")
    count_after=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_after'])" "$json_result")
    update_payload=$(python3 -c "import sys, json; print(json.dumps(json.loads(sys.argv[1])['payload']))" "$json_result")

    echo "Jumlah IP sebelum penambahan: $count_before"
    echo "Jumlah IP setelah penambahan: $count_after (mempertahankan semua IP lama + 1 IP baru)"
    echo "Mengirim pembaruan ke SafeLine WAF..."

    local response http_code body
    response=$(http_request "PUT" "/api/open/ipgroup" "$update_payload")
    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"

    if [ "$http_code" = "200" ]; then
        echo "Sukses: IP $target_ip berhasil ditambahkan ke SafeLine IP Group $SAFELINE_GROUP."
    else
        echo "Peringatan: SafeLine mengembalikan HTTP status $http_code."
    fi
    echo "--------------------------------"
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
    echo "Target IP    : $target_ip"
    echo "--------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    local py_output
    py_output=$(echo "$raw_data" | python3 -c '
import sys, json

target_group_raw = sys.argv[1]
target_group = int(target_group_raw) if target_group_raw.isdigit() else target_group_raw
target_ip = sys.argv[2].strip()

try:
    res = json.load(sys.stdin)
    data = res.get("data", {})
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get("nodes", [])
        if not nodes and data.get("id") == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get("id") == target_group:
            matched_group = g
            break

    if not matched_group:
        print("GROUP_NOT_FOUND")
        sys.exit(0)

    existing_ips = list(matched_group.get("ips") or [])
    total_reported = matched_group.get("total", len(existing_ips))

    if total_reported > len(existing_ips):
        print(f"ERROR:Data tidak lengkap. SafeLine melaporkan {total_reported} IP namun hanya {len(existing_ips)} yang terambil. Batalkan update untuk mencegah data hilang.")
        sys.exit(0)

    if target_ip not in existing_ips:
        print(f"NOT_IN_GROUP:{len(existing_ips)}")
        sys.exit(0)

    # Hapus HANYA target_ip dan pertahankan seluruh IP lainnya
    new_ips = [ip for ip in existing_ips if ip != target_ip]

    group_comment = matched_group.get("comment", "Managed by Blackened Threat Intel")
    payload = {
        "id": matched_group.get("id", target_group),
        "comment": group_comment,
        "reference": matched_group.get("reference", ""),
        "ips": new_ips
    }

    result = {
        "status": "OK",
        "count_before": len(existing_ips),
        "count_after": len(new_ips),
        "group_name": group_comment,
        "payload": payload
    }
    print("SUCCESS:" + json.dumps(result))
except Exception as e:
    print("ERROR:" + str(e))
' "$SAFELINE_GROUP" "$target_ip")

    if [ "$py_output" = "GROUP_NOT_FOUND" ]; then
        echo "ERROR: IP Group ID $SAFELINE_GROUP tidak ditemukan di SafeLine WAF."
        exit 1
    elif [[ "$py_output" =~ ^NOT_IN_GROUP: ]]; then
        local current_count
        current_count=$(echo "$py_output" | cut -d: -f2)
        echo "Info: IP $target_ip tidak ditemukan dalam SafeLine IP Group $SAFELINE_GROUP (Total: $current_count IP)."
        echo "Tidak ada item yang perlu dihapus."
        return 0
    elif [[ "$py_output" =~ ^ERROR: ]]; then
        echo "Gagal menyiapkan payload SafeLine: ${py_output#ERROR:}"
        exit 1
    elif [[ ! "$py_output" =~ ^SUCCESS: ]]; then
        echo "Respons parsing SafeLine tidak terduga: $py_output"
        exit 1
    fi

    local json_result count_before count_after update_payload
    json_result="${py_output#SUCCESS:}"
    count_before=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_before'])" "$json_result")
    count_after=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_after'])" "$json_result")
    update_payload=$(python3 -c "import sys, json; print(json.dumps(json.loads(sys.argv[1])['payload']))" "$json_result")

    echo "Jumlah IP sebelum penghapusan: $count_before"
    echo "Jumlah IP setelah penghapusan: $count_after (hanya menghapus IP $target_ip)"
    echo "Mengirim pembaruan ke SafeLine WAF..."

    local response http_code body
    response=$(http_request "PUT" "/api/open/ipgroup" "$update_payload")
    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"

    if [ "$http_code" = "200" ]; then
        echo "Sukses: IP $target_ip berhasil dihapus dari SafeLine IP Group $SAFELINE_GROUP."
    else
        echo "Peringatan: SafeLine mengembalikan HTTP status $http_code."
    fi
    echo "--------------------------------"
}

# Fungsi: Sinkronisasi seluruh IP dari file lokal (misal: ip_list.txt) ke SafeLine WAF
action_sync() {
    local source_file="${1:-$DIR/ip_list.txt}"
    if [ ! -f "$source_file" ]; then
        echo "ERROR: File sumber IP $source_file tidak ditemukan."
        exit 1
    fi

    echo "===> Sinkronisasi IP dari $source_file ke SafeLine IP Group ($SAFELINE_GROUP)..."
    echo "--------------------------------"

    local raw_data
    raw_data=$(get_ip_group_data)

    local py_output
    py_output=$(echo "$raw_data" | python3 -c '
import sys, json

target_group_raw = sys.argv[1]
target_group = int(target_group_raw) if target_group_raw.isdigit() else target_group_raw
source_file = sys.argv[2]

try:
    file_ips = set()
    with open(source_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                file_ips.add(line)

    res = json.load(sys.stdin)
    data = res.get("data", {})
    nodes = []
    if isinstance(data, list):
        nodes = data
    elif isinstance(data, dict):
        nodes = data.get("nodes", [])
        if not nodes and data.get("id") == target_group:
            nodes = [data]

    matched_group = None
    for g in nodes:
        if g.get("id") == target_group:
            matched_group = g
            break

    if not matched_group:
        print("GROUP_NOT_FOUND")
        sys.exit(0)

    existing_ips = list(matched_group.get("ips") or [])
    
    # Gabungkan existing SafeLine IP dengan IP dari file sumber (deduplikasi union)
    merged_ips = sorted(list(set(existing_ips).union(file_ips)))

    group_comment = matched_group.get("comment", "Managed by Blackened Threat Intel")
    payload = {
        "id": matched_group.get("id", target_group),
        "comment": group_comment,
        "reference": matched_group.get("reference", ""),
        "ips": merged_ips
    }

    result = {
        "status": "OK",
        "count_before": len(existing_ips),
        "count_source": len(file_ips),
        "count_after": len(merged_ips),
        "group_name": group_comment,
        "payload": payload
    }
    print("SUCCESS:" + json.dumps(result))
except Exception as e:
    print("ERROR:" + str(e))
' "$SAFELINE_GROUP" "$source_file")

    if [ "$py_output" = "GROUP_NOT_FOUND" ]; then
        echo "ERROR: IP Group ID $SAFELINE_GROUP tidak ditemukan di SafeLine WAF."
        exit 1
    elif [[ "$py_output" =~ ^ERROR: ]]; then
        echo "Gagal menyiapkan payload sync SafeLine: ${py_output#ERROR:}"
        exit 1
    elif [[ ! "$py_output" =~ ^SUCCESS: ]]; then
        echo "Respons parsing sync tidak terduga: $py_output"
        exit 1
    fi

    local json_result count_before count_source count_after update_payload
    json_result="${py_output#SUCCESS:}"
    count_before=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_before'])" "$json_result")
    count_source=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_source'])" "$json_result")
    count_after=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['count_after'])" "$json_result")
    update_payload=$(python3 -c "import sys, json; print(json.dumps(json.loads(sys.argv[1])['payload']))" "$json_result")

    echo "Jumlah IP SafeLine sebelum sync: $count_before"
    echo "Jumlah IP dari file sumber      : $count_source"
    echo "Total IP gabungan setelah sync : $count_after"
    echo "Mengirim pembaruan ke SafeLine WAF..."

    local response http_code body
    response=$(http_request "PUT" "/api/open/ipgroup" "$update_payload")
    http_code=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$response" | grep -v "HTTP_STATUS:")

    echo "HTTP Status Code: $http_code"
    echo "Response Body:"
    format_json "$body"

    if [ "$http_code" = "200" ]; then
        echo "Sukses: Sinkronisasi ke SafeLine IP Group $SAFELINE_GROUP berhasil."
    else
        echo "Peringatan: SafeLine mengembalikan HTTP status $http_code."
    fi
    echo "--------------------------------"
}

# Tampilkan petunjuk penggunaan
show_usage() {
    echo "SafeLine WAF IP Group Management Tool"
    echo "Penggunaan:"
    echo "  $0 add <ip_address> [komentar]    Tambah IP ke SafeLine IP Group (tetap menjaga IP existing)"
    echo "  $0 delete <ip_address>            Hapus IP dari SafeLine IP Group (hanya menghapus target IP)"
    echo "  $0 sync [file_ip]                 Sinkronisasi file IP (default: ip_list.txt) ke SafeLine Group"
    echo "  $0 search [ip_address]            Cari IP di dalam SafeLine Group"
    echo "  $0 list                           Tampilkan seluruh IP di group"
    echo "  $0 info / count                   Lihat total IP & info group"
    echo ""
    echo "Contoh:"
    echo "  $0 add 103.253.27.215"
    echo "  $0 delete 103.253.27.215"
    echo "  $0 sync ip_list.txt"
    echo "  $0 search 103.253.27.215"
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
    sync)
        shift
        action_sync "$@"
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
