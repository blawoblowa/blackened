#!/bin/bash

# Directory script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST_IP_TXT="$DIR/ip_list.txt"
LIST_IP_CSV="$DIR/ip_list.csv"
NEW_IP="$DIR/ip_new.txt"
EXCEPTION_IP="$DIR/ip_exception.txt"
MERCHANT_IP="$DIR/ip_merchant.txt"
TEMP_FILE="$DIR/.temp_ip.txt"
GENERATE_MD_SCRIPT="$DIR/generate_md.py"
ENV_FILE="$DIR/.env"

# Muat konfigurasi .env jika tersedia
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ ! "$line" =~ ^# ]] && [[ "$line" == *"="* ]]; then
            key=$(echo "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^["'"'"']//;s/["'"'"']$//')
            export "$key"="$val"
        fi
    done < "$ENV_FILE"
fi

# Pastikan file basis data (ip_list.txt & ip_list.csv), ip_exception.txt, dan ip_merchant.txt ada
if [ ! -f "$LIST_IP_TXT" ] && [ -f "$LIST_IP_CSV" ]; then
    cp "$LIST_IP_CSV" "$LIST_IP_TXT"
elif [ ! -f "$LIST_IP_TXT" ]; then
    touch "$LIST_IP_TXT"
fi

if [ ! -f "$LIST_IP_CSV" ]; then
    cp "$LIST_IP_TXT" "$LIST_IP_CSV"
fi

if [ ! -f "$EXCEPTION_IP" ]; then
    touch "$EXCEPTION_IP"
fi

if [ ! -f "$MERCHANT_IP" ]; then
    touch "$MERCHANT_IP"
fi

# Cek apakah file ip_new.txt ada
if [ ! -f "$NEW_IP" ]; then
    echo "Error: File $NEW_IP tidak ditemukan!"
    exit 1
fi

# 1. Deteksi apakah ada IP Merchant di dalam ip_new.txt
MERCHANT_CONFLICTS=$(awk '
    # Baca file ip_merchant.txt
    NR==FNR {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") merchant[$0] = 1
        next
    }
    # Periksa isi ip_new.txt
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && ($0 in merchant)) {
            print $0
        }
    }
' "$MERCHANT_IP" "$NEW_IP" 2>/dev/null | sort -u)

if [ -n "$MERCHANT_CONFLICTS" ]; then
    CONFLICT_COUNT=$(echo "$MERCHANT_CONFLICTS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo "=========================================="
    echo "    PERINGATAN: IP MERCHANT TERDETEKSI!   "
    echo "=========================================="
    echo "Ditemukan $CONFLICT_COUNT IP pada $NEW_IP yang terdaftar sebagai IP Merchant:"
    echo "$MERCHANT_CONFLICTS" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  - [DITOLAK] $ip"
        fi
    done
    echo "Seluruh IP di atas OTOMATIS DITOLAK dan TIDAK dimasukkan ke database."
    echo "------------------------------------------"
fi

# Hitung jumlah IP sebelum proses
COUNT_BEFORE=$(grep -v '^[[:space:]]*$' "$LIST_IP_TXT" 2>/dev/null | wc -l | tr -d ' ')
COUNT_EXCEPTION=$(grep -v '^[[:space:]]*$' "$EXCEPTION_IP" 2>/dev/null | wc -l | tr -d ' ')
COUNT_MERCHANT=$(grep -v '^[[:space:]]*$' "$MERCHANT_IP" 2>/dev/null | wc -l | tr -d ' ')

# Gabungkan ip_list.txt dan ip_new.txt, filter pengecualian (ip_exception.txt) & proteksi merchant (ip_merchant.txt),
# bersihkan whitespace, baris kosong & UTF-8 BOM, lalu urutkan secara numerik per oktet IP (unique)
awk '
    # Tahap 1: Baca file ip_exception.txt
    FILENAME == ARGV[1] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") exc[$0] = 1
        next
    }
    # Tahap 2: Baca file ip_merchant.txt
    FILENAME == ARGV[2] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") merchant[$0] = 1
        next
    }
    # Tahap 3: Baca gabungan ip_list.txt & ip_new.txt
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in exc) && !($0 in merchant)) {
            print $0
        }
    }
' "$EXCEPTION_IP" "$MERCHANT_IP" <(cat "$LIST_IP_TXT" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"

# Sinkronkan hasil pemrosesan ke kedua format: ip_list.txt dan ip_list.csv
cp "$TEMP_FILE" "$LIST_IP_TXT"
cp "$TEMP_FILE" "$LIST_IP_CSV"
rm -f "$TEMP_FILE"

# Hitung jumlah IP setelah proses
COUNT_AFTER=$(grep -v '^[[:space:]]*$' "$LIST_IP_TXT" 2>/dev/null | wc -l | tr -d ' ')
DIFF=$((COUNT_AFTER - COUNT_BEFORE))

echo "=========================================="
echo "         PROSES PENYORTIRAN IP            "
echo "=========================================="
echo "Jumlah IP sebelumnya            : $COUNT_BEFORE"
echo "Jumlah aturan pengecualian      : $COUNT_EXCEPTION"
echo "Jumlah IP Merchant terproteksi  : $COUNT_MERCHANT"
echo "Perubahan IP bersih             : $DIFF"
echo "Total IP unik sekarang          : $COUNT_AFTER"
echo "Format database tersimpan       : ip_list.txt & ip_list.csv"
echo "------------------------------------------"

# Update ip_list.md secara otomatis
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Memperbarui ip_list.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi

# Auto commit & push ke GitHub jika diaktifkan di .env (AUTO_GIT_PUSH=true)
AUTO_PUSH_LOWER=$(echo "$AUTO_GIT_PUSH" | tr '[:upper:]' '[:lower:]')
if [ "$AUTO_PUSH_LOWER" = "true" ] || [ "$AUTO_PUSH_LOWER" = "1" ] || [ "$AUTO_PUSH_LOWER" = "yes" ]; then
    echo "------------------------------------------"
    echo "Memeriksa status git untuk ip_list.*..."
    git add "$LIST_IP_TXT" "$LIST_IP_CSV" "$DIR/ip_list.md"
    if ! git diff --cached --quiet; then
        COMMIT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
        echo "Melakukan auto-commit dan push ke GitHub..."
        git commit -m "Update IP intelligence list (Total: ${COUNT_AFTER} IPs - ${COMMIT_DATE})"
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
        if git push origin "$CURRENT_BRANCH"; then
            echo "Berhasil push ke GitHub (branch: $CURRENT_BRANCH)"
        else
            echo "Peringatan: Gagal melakukan push ke GitHub."
        fi
    else
        echo "Tidak ada perubahan data IP untuk di-commit."
    fi
fi

echo "=========================================="
echo "Proses selesai dengan sukses!"
