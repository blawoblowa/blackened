#!/bin/bash

# Directory scripts
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST_IP_TXT="$DIR/ip_list.txt"
LIST_IP_CSV="$DIR/ip_list.csv"
NEW_IP="$DIR/ip_new.txt"
UNBLOCK_IP="$DIR/ip_unblock.txt"
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

# Fallback muat dari app/.env jika GITHUB_TOKEN belum terdefinisi
if [ -z "$GITHUB_TOKEN" ] && [ -f "$DIR/../.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ ! "$line" =~ ^# ]] && [[ "$line" == *"="* ]]; then
            key=$(echo "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^["'"'"']//;s/["'"'"']$//')
            if [ -z "${!key}" ]; then
                export "$key"="$val"
            fi
        fi
    done < "$DIR/../.env"
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

if [ ! -f "$UNBLOCK_IP" ]; then
    touch "$UNBLOCK_IP"
fi

# Cek apakah file ip_new.txt ada
if [ ! -f "$NEW_IP" ]; then
    echo "Error: File ip_new.txt tidak ditemukan!"
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
    echo "==================================="
    echo "PERINGATAN: IP MERCHANT TERDETEKSI!"
    echo "==================================="
    echo "Ditemukan $CONFLICT_COUNT IP pada ip_new.txt yang terdaftar sebagai IP Merchant:"
    echo "$MERCHANT_CONFLICTS" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  - [DITOLAK] $ip"
        fi
    done
    echo "Seluruh IP di atas OTOMATIS DITOLAK dan TIDAK dimasukkan ke database."
    echo "--------------------------------"
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
    # Tahap 3: Baca file ip_unblock.txt (IP yang diminta di-unblock / dihapus)
    FILENAME == ARGV[3] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") unblock[$0] = 1
        next
    }
    # Tahap 4: Baca gabungan ip_list.txt & ip_new.txt
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in exc) && !($0 in merchant) && !($0 in unblock)) {
            print $0
        }
    }
' "$EXCEPTION_IP" "$MERCHANT_IP" "$UNBLOCK_IP" <(cat "$LIST_IP_TXT" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"

# Analisis detail status setiap IP masukan dari ip_new.txt
NEW_INPUT_ANALYSIS=$(awk '
    # Tahap 1: Baca file ip_merchant.txt
    FILENAME == ARGV[1] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") merchant[$0] = 1
        next
    }
    # Tahap 2: Baca file ip_exception.txt
    FILENAME == ARGV[2] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") exc[$0] = 1
        next
    }
    # Tahap 3: Baca file ip_list.txt (database sebelum pembaruan)
    FILENAME == ARGV[3] {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") old[$0] = 1
        next
    }
    # Tahap 4: Analisis baris ip_new.txt
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !seen[$0]++) {
            if ($0 in merchant) {
                # Sudah diproses pada banner peringatan merchant
                next
            } else if ($0 in exc) {
                print "EXC:" $0
            } else if ($0 in old) {
                print "EXIST:" $0
            } else {
                print "NEW:" $0
            }
        }
    }
' "$MERCHANT_IP" "$EXCEPTION_IP" "$LIST_IP_TXT" "$NEW_IP" 2>/dev/null)

NEW_IPS=$(echo "$NEW_INPUT_ANALYSIS" | grep '^NEW:' | cut -d: -f2-)
EXIST_IPS=$(echo "$NEW_INPUT_ANALYSIS" | grep '^EXIST:' | cut -d: -f2-)
EXC_IPS=$(echo "$NEW_INPUT_ANALYSIS" | grep '^EXC:' | cut -d: -f2-)

# Deteksi IP yang dikeluarkan dari database lama (jika ada)
REMOVED_IPS=$(awk '
    NR==FNR {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") current[$0] = 1
        next
    }
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in current)) {
            print $0
        }
    }
' "$TEMP_FILE" "$LIST_IP_TXT" 2>/dev/null)

# Deteksi IP pada ip_unblock.txt yang tidak ditemukan di database
NOT_FOUND_UNBLOCK=$(awk '
    NR==FNR {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") old[$0] = 1
        next
    }
    {
        gsub(/\r/, ""); gsub(/^\xef\xbb\xbf/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in old)) {
            print $0
        }
    }
' "$LIST_IP_TXT" "$UNBLOCK_IP" 2>/dev/null)

# Sinkronkan hasil pemrosesan ke kedua format: ip_list.txt dan ip_list.csv jika ada perbedaan
if ! cmp -s "$TEMP_FILE" "$LIST_IP_TXT" 2>/dev/null; then
    cp "$TEMP_FILE" "$LIST_IP_TXT"
    cp "$TEMP_FILE" "$LIST_IP_CSV"
fi
rm -f "$TEMP_FILE"

# Kosongkan file ip_unblock.txt setelah selesai diproses
if [ -f "$UNBLOCK_IP" ]; then
    > "$UNBLOCK_IP"
fi

# Hitung jumlah IP setelah proses
COUNT_AFTER=$(grep -v '^[[:space:]]*$' "$LIST_IP_TXT" 2>/dev/null | wc -l | tr -d ' ')
DIFF=$((COUNT_AFTER - COUNT_BEFORE))

# Update ip_list.md secara otomatis & lengkapi data intelijen IP baru ke cache
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Update data intelijen ip_list.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi
echo "--------------------------------"
echo "Jumlah IP sebelumnya: $COUNT_BEFORE"
echo "Jumlah aturan pengecualian: $COUNT_EXCEPTION"
echo "Jumlah IP Merchant terproteksi: $COUNT_MERCHANT"
if [ "$DIFF" -gt 0 ]; then
    echo "Perubahan IP bersih: +$DIFF"
else
    echo "Perubahan IP bersih: $DIFF"
fi
echo "Total IP unik sekarang: $COUNT_AFTER"
echo "Format database tersimpan: ip_list.txt & ip_list.csv"
echo "--------------------------------"

# Tampilkan detail penambahan IP baru beserta informasi intelijen lengkap
if [ -n "$NEW_IPS" ]; then
    COUNT_NEW=$(echo "$NEW_IPS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo "Detail Penambahan IP Baru ($COUNT_NEW IP):"
    if [ -f "$GENERATE_MD_SCRIPT" ]; then
        python3 "$GENERATE_MD_SCRIPT" --print-details "$NEW_IPS" "BARU"
    else
        echo "$NEW_IPS" | while read -r ip; do
            if [ -n "$ip" ]; then
                echo "  + [BARU] $ip"
            fi
        done
    fi
else
    echo "Detail Penambahan IP:"
    echo "  (Tidak ada IP baru yang ditambahkan ke database)"
fi

# Tampilkan IP yang sudah ada sebelumnya di database
if [ -n "$EXIST_IPS" ]; then
    COUNT_EXIST=$(echo "$EXIST_IPS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo ""
    echo "IP yang Sudah Ada di Database ($COUNT_EXIST IP):"
    echo "$EXIST_IPS" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  * [SUDAH ADA] $ip"
        fi
    done
fi

# Tampilkan IP yang dilewati karena masuk daftar pengecualian
if [ -n "$EXC_IPS" ]; then
    COUNT_EXC=$(echo "$EXC_IPS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo ""
    echo "IP Masuk Daftar Pengecualian / Whitelist ($COUNT_EXC IP):"
    echo "$EXC_IPS" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  - [DILEWATI] $ip"
        fi
    done
fi

# Tampilkan IP yang dihapus/dikeluarkan dari database (jika ada)
if [ -n "$REMOVED_IPS" ]; then
    COUNT_REMOVED=$(echo "$REMOVED_IPS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo ""
    echo "IP Dikeluarkan dari Database ($COUNT_REMOVED IP):"
    echo "$REMOVED_IPS" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  - [DIHAPUS] $ip"
        fi
    done
fi

# Tampilkan IP unblock yang tidak ditemukan di database
if [ -n "$NOT_FOUND_UNBLOCK" ]; then
    COUNT_NF=$(echo "$NOT_FOUND_UNBLOCK" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    echo ""
    echo "IP Unblock Tidak Ditemukan di Database ($COUNT_NF IP):"
    echo "$NOT_FOUND_UNBLOCK" | while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  ? [TIDAK DITEMUKAN] $ip"
        fi
    done
fi
echo "--------------------------------"

# Auto commit & push ke GitHub jika diaktifkan di .env (AUTO_GIT_PUSH=true)
AUTO_PUSH_LOWER=$(echo "$AUTO_GIT_PUSH" | tr '[:upper:]' '[:lower:]')
if [ "$AUTO_PUSH_LOWER" = "true" ] || [ "$AUTO_PUSH_LOWER" = "1" ] || [ "$AUTO_PUSH_LOWER" = "yes" ]; then
    echo "Memeriksa status git untuk ip_list.*..."

    # Hindari safe.directory error di lingkungan Docker container
    git config --global --add safe.directory "$DIR" 2>/dev/null || true

    # Pastikan identitas git commit terkonfigurasi
    if ! git config user.name >/dev/null 2>&1; then
        git config user.name "${GIT_USER_NAME:-blawoblowa}"
    fi
    if ! git config user.email >/dev/null 2>&1; then
        git config user.email "${GIT_USER_EMAIL:-blowablawo@gmail.com}"
    fi

    # Cek apakah ada perubahan pada file ip_list (ip_list.txt, ip_list.csv, ip_list.md)
    if [ -n "$(git status --porcelain "$LIST_IP_TXT" "$LIST_IP_CSV" "$DIR/ip_list.md" 2>/dev/null)" ]; then
        git pull --rebase 2>/dev/null || git pull 2>/dev/null || true
        git add "$LIST_IP_TXT" "$LIST_IP_CSV" "$DIR/ip_list.md"
        if ! git diff --cached --quiet -- "$LIST_IP_TXT" "$LIST_IP_CSV" "$DIR/ip_list.md"; then
            COMMIT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
            echo "Auto-commit & push ke GitHub..."
            if [ -n "$REMOVED_IPS" ] && [ -z "$NEW_IPS" ]; then
                git commit -m "Remove IP from intelligence list (Total: ${COUNT_AFTER} IPs - ${COMMIT_DATE})"
            else
                git commit -m "Update IP intelligence list (Total: ${COUNT_AFTER} IPs - ${COMMIT_DATE})"
            fi
            CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")

            ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
            PUSH_TARGET="origin"

            if [ -n "$GITHUB_TOKEN" ]; then
                if [[ "$ORIGIN_URL" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
                    REPO_PATH="${BASH_REMATCH[1]}"
                    PUSH_TARGET="https://${GITHUB_TOKEN}@github.com/${REPO_PATH}.git"
                elif [ -n "$ORIGIN_URL" ]; then
                    PUSH_TARGET=$(echo "$ORIGIN_URL" | sed "s#https://github.com/#https://${GITHUB_TOKEN}@github.com/#")
                fi
            fi

            if GIT_TERMINAL_PROMPT=0 git push "$PUSH_TARGET" "$CURRENT_BRANCH"; then
                echo "Berhasil push ke GitHub (branch: $CURRENT_BRANCH)"
            else
                echo "Peringatan: Gagal melakukan push ke GitHub."
                if [ -z "$GITHUB_TOKEN" ]; then
                    echo "Penyebab: Kredensial git / GITHUB_TOKEN belum dikonfigurasi di file .env."
                    echo "Panduan: Tambahkan GITHUB_TOKEN=<personal_access_token> di app/blackened/.env atau app/.env"
                else
                    echo "Penyebab: Token GitHub ditolak atau tidak memiliki hak akses tulis (write/push) ke repositori."
                fi
            fi
        else
            echo "Tidak ada perubahan pada file ip_list (csv, md, txt). Commit dan push dilewati."
        fi
    else
        echo "Tidak ada perubahan pada file ip_list (csv, md, txt). Commit dan push dilewati."
    fi
fi

echo "--------------------------------"
echo "Proses selesai dengan sukses!"
