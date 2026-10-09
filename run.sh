#!/bin/bash

# Directory script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST_IP="$DIR/list_ip.csv"
NEW_IP="$DIR/new_ip.csv"
EXCEPTION_IP="$DIR/exception_ip.csv"
TEMP_FILE="$DIR/.temp_ip.csv"
GENERATE_MD_SCRIPT="$DIR/generate_md.py"

# Pastikan file list_ip.csv dan exception_ip.csv ada
if [ ! -f "$LIST_IP" ]; then
    touch "$LIST_IP"
fi

if [ ! -f "$EXCEPTION_IP" ]; then
    touch "$EXCEPTION_IP"
fi

# Cek apakah file new_ip.csv ada
if [ ! -f "$NEW_IP" ]; then
    echo "Error: File $NEW_IP tidak ditemukan!"
    exit 1
fi

# Hitung jumlah IP sebelum proses
COUNT_BEFORE=$(grep -v '^[[:space:]]*$' "$LIST_IP" 2>/dev/null | wc -l | tr -d ' ')
COUNT_EXCEPTION=$(grep -v '^[[:space:]]*$' "$EXCEPTION_IP" 2>/dev/null | wc -l | tr -d ' ')

# Gabungkan list_ip.csv dan new_ip.csv, filter pengecualian (exception_ip.csv),
# bersihkan whitespace & baris kosong, lalu urutkan secara numerik per oktet IP (unique)
awk '
    # Tahap 1: Baca file exception_ip.csv
    NR==FNR {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") exc[$0] = 1
        next
    }
    # Tahap 2: Baca gabungan list_ip.csv & new_ip.csv
    {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in exc)) {
            print $0
        }
    }
' "$EXCEPTION_IP" <(cat "$LIST_IP" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"

# Ganti list_ip.csv dengan hasil yang sudah di-sort dan deduplikasi
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

# Update list_ip.md secara otomatis
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Memperbarui list_ip.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi

echo "=========================================="
echo "Proses selesai dengan sukses!"
