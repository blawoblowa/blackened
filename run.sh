#!/bin/bash

# Directory script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST_IP="$DIR/ip_list.csv"
NEW_IP="$DIR/ip_new.csv"
EXCEPTION_IP="$DIR/ip_exception.csv"
TEMP_FILE="$DIR/.temp_ip.csv"
GENERATE_MD_SCRIPT="$DIR/generate_md.py"

# Pastikan file ip_list.csv dan ip_exception.csv ada
if [ ! -f "$LIST_IP" ]; then
    touch "$LIST_IP"
fi

if [ ! -f "$EXCEPTION_IP" ]; then
    touch "$EXCEPTION_IP"
fi

# Cek apakah file ip_new.csv ada
if [ ! -f "$NEW_IP" ]; then
    echo "Error: File $NEW_IP tidak ditemukan!"
    exit 1
fi

# Hitung jumlah IP sebelum proses
COUNT_BEFORE=$(grep -v '^[[:space:]]*$' "$LIST_IP" 2>/dev/null | wc -l | tr -d ' ')
COUNT_EXCEPTION=$(grep -v '^[[:space:]]*$' "$EXCEPTION_IP" 2>/dev/null | wc -l | tr -d ' ')

# Gabungkan ip_list.csv dan ip_new.csv, filter pengecualian (ip_exception.csv),
# bersihkan whitespace & baris kosong, lalu urutkan secara numerik per oktet IP (unique)
awk '
    # Tahap 1: Baca file ip_exception.csv
    NR==FNR {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") exc[$0] = 1
        next
    }
    # Tahap 2: Baca gabungan ip_list.csv & ip_new.csv
    {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in exc)) {
            print $0
        }
    }
' "$EXCEPTION_IP" <(cat "$LIST_IP" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"

# Ganti ip_list.csv dengan hasil yang sudah di-sort dan deduplikasi
mv "$TEMP_FILE" "$LIST_IP"

# Hitung jumlah IP setelah proses
COUNT_AFTER=$(grep -v '^[[:space:]]*$' "$LIST_IP" 2>/dev/null | wc -l | tr -d ' ')
DIFF=$((COUNT_AFTER - COUNT_BEFORE))

echo "=========================================="
echo "         PROSES PENYORTIRAN IP            "
echo "=========================================="
echo "Jumlah IP sebelumnya            : $COUNT_BEFORE"
echo "Jumlah aturan pengecualian      : $COUNT_EXCEPTION"
echo "Perubahan IP bersih             : $DIFF"
echo "Total IP unik sekarang          : $COUNT_AFTER"
echo "------------------------------------------"

# Update ip_list.md secara otomatis
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Memperbarui ip_list.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi

echo "=========================================="
echo "Proses selesai dengan sukses!"
