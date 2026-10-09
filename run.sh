#!/bin/bash

# Directory script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST_IP="$DIR/list_ip.csv"
NEW_IP="$DIR/new_ip.csv"
TEMP_FILE="$DIR/.temp_ip.csv"
GENERATE_MD_SCRIPT="$DIR/generate_md.py"

# Pastikan file list_ip.csv ada
if [ ! -f "$LIST_IP" ]; then
    touch "$LIST_IP"
fi

# Cek apakah file new_ip.csv ada
if [ ! -f "$NEW_IP" ]; then
    echo "Error: File $NEW_IP tidak ditemukan!"
    exit 1
fi

# Hitung jumlah IP sebelum proses
COUNT_BEFORE=$(grep -v '^[[:space:]]*$' "$LIST_IP" 2>/dev/null | wc -l | tr -d ' ')

# Gabungkan list_ip.csv dan new_ip.csv, bersihkan whitespace & baris kosong,
# lalu urutkan (sort) secara numerik per oktet IP dan ambil nilai unik (unique)
cat "$LIST_IP" "$NEW_IP" 2>/dev/null \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"

# Ganti list_ip.csv dengan hasil yang sudah di-sort dan deduplikasi
mv "$TEMP_FILE" "$LIST_IP"

# Hitung jumlah IP setelah proses
COUNT_AFTER=$(grep -v '^[[:space:]]*$' "$LIST_IP" 2>/dev/null | wc -l | tr -d ' ')
ADDED=$((COUNT_AFTER - COUNT_BEFORE))

echo "=========================================="
echo "         PROSES PENYORTIRAN IP            "
echo "=========================================="
echo "Jumlah IP sebelumnya            : $COUNT_BEFORE"
echo "Jumlah IP baru yang ditambahkan : $ADDED"
echo "Total IP unik sekarang          : $COUNT_AFTER"
echo "------------------------------------------"

# Update list_ip.md secara otomatis
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Memperbarui list_ip.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi

echo "=========================================="
echo "Proses selesai dengan sukses!"
