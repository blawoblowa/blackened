# Blackened - IP Management & Threat Intelligence Utility

Blackened adalah utilitas otomatisasi berbasis shell script (`run.sh`) dan Python (`generate_md.py`) yang dirancang untuk mengelola, menyortir, membersihkan (sanitasi), mendeduplikasi, mengecualikan (*whitelist*), serta memperkaya daftar IP address (blacklist/threat feed) dengan data geolokasi, ISP, ASN, dan reputasi ancaman AbuseIPDB secara otomatis.

Hasil penyortiran basis data IP disimpan secara simultan dalam **dua format file**: `.txt` (`ip_list.txt`) dan `.csv` (`ip_list.csv`).

---

## Gambaran Umum & Fungsi `run.sh`

Script `run.sh` berfungsi sebagai *orchestrator* dan *core processing engine* utama. Script ini bertanggung jawab penuh atas integritas data, siklus hidup file input-output, pemfilteran aturan pengecualian, pembuatan ganda format file basis data, dan orkestrasi pembaruan dokumentasi intelijen.

### Fungsi Utama:
1. **Penggabungan Data Input**: Menggabungkan IP dari basis data aktif (`ip_list.txt` / `ip_list.csv`) dengan IP baru (`ip_new.txt`).
2. **Penerapan Aturan Pengecualian (*Exception/Whitelist*)**: Mengeliminasi seluruh IP yang terdaftar pada `ip_exception.txt` secara deterministik.
3. **Normalisasi & Sanitasi Format**: Membersihkan karakter baris Windows (`\r`), spasi awal/akhir (*trimming*), dan baris kosong.
4. **Pengurutan Numerik per Oktet & Deduplikasi**: Mengurutkan alamat IP berdasarkan urutan numerik empat oktet IPv4 sekaligus memastikan tidak ada duplikasi entri.
5. **Output Ganda Otomatis (*Dual Format Generation*)**: Menyimpan hasil pemrosesan ke dalam dua file basis data secara bersamaan: `ip_list.txt` dan `ip_list.csv`.
6. **Pembaruan Atomik (*Atomic Update*)**: Menjaga keutuhan file basis data dengan mekanisme penulisan berkas temporer sebelum proses pergantian (*file swap*).
7. **Pelaporan Metrik Eksekusi**: Menghitung dan mencetak metrik perubahan data secara transparan pada antarmuka terminal.
8. **Pemicu Otomatis Modul Intelijen**: Mengeksekusi modul pengayaan `generate_md.py` untuk menyinkronkan laporan `ip_list.md`.

---

## Rincian Teknis & Arsitektur `run.sh`

### 1. Struktur File Proyek

```text
blackened/
|-- ip_list.txt        # Database utama daftar IP unik dan terurut (Format TXT)
|-- ip_list.csv        # Database utama daftar IP unik dan terurut (Format CSV)
|-- ip_list.md         # Laporan intelijen IP (tabel & statistik)
|-- ip_new.txt         # File input untuk memasukkan daftar IP baru
|-- ip_exception.txt   # File whitelist/pengecualian IP yang diabaikan
|-- run.sh             # Entrypoint bash script utama
|-- generate_md.py     # Engine pengayaan metadata & AbuseIPDB
|-- .env.example       # Template konfigurasi API Key
|-- .env               # File environment API Key (opsional)
|-- .ip_cache.json     # Cache lokal respons API (otomatis dibuat)
|-- LICENSE            # Lisensi proyek
`-- README.md          # Dokumentasi teknis
```

---

### 2. Bedah Teknis Baris Kode `run.sh`

#### A. Inisialisasi Jalur & Variabel Berkas
```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_IP_TXT="$DIR/ip_list.txt"
LIST_IP_CSV="$DIR/ip_list.csv"
NEW_IP="$DIR/ip_new.txt"
EXCEPTION_IP="$DIR/ip_exception.txt"
TEMP_FILE="$DIR/.temp_ip.txt"
GENERATE_MD_SCRIPT="$DIR/generate_md.py"
```
- Menentukan absolute path direktori kerja untuk menjamin eksekusi portabel dari direktori mana saja.

#### B. Validasi & Auto-Inisialisasi Berkas
```bash
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

if [ ! -f "$NEW_IP" ]; then
    echo "Error: File $NEW_IP tidak ditemukan!"
    exit 1
fi
```
- Menjamin kedua berkas basis data (`ip_list.txt` dan `ip_list.csv`) serta berkas pengecualian (`ip_exception.txt`) selalu sinkron dan tersedia.

#### C. Pengambilan Metrik Baseline
```bash
COUNT_BEFORE=$(grep -v '^[[:space:]]*$' "$LIST_IP_TXT" 2>/dev/null | wc -l | tr -d ' ')
COUNT_EXCEPTION=$(grep -v '^[[:space:]]*$' "$EXCEPTION_IP" 2>/dev/null | wc -l | tr -d ' ')
```
- Menghitung total entri IP valid sebelum operasi dijalankan.

#### D. Pipeline Pemrosesan Data Terpadu
```bash
awk '
    # Tahap 1: Muat seluruh IP pengecualian ke dalam hash table memori
    NR==FNR {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "") exc[$0] = 1
        next
    }
    # Tahap 2: Baca stream gabungan ip_list.txt dan ip_new.txt
    {
        gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 != "" && !($0 in exc)) {
            print $0
        }
    }
' "$EXCEPTION_IP" <(cat "$LIST_IP_TXT" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"
```

Tahapan pipeline:
1. **Pengecualian Hash Table (`awk`)**: Mengecualikan seluruh IP yang terdaftar di `ip_exception.txt` secara instan dan deterministik.
2. **Pengurutan Numerik & Deduplikasi (`sort`)**:
   - `-n`: Pengurutan numerik.
   - `-t .`: Tanda titik (`.`) sebagai pembatas oktet IP.
   - `-k 1,1 -k 2,2 -k 3,3 -k 4,4`: Membandingkan nilai numerik oktet ke-1 hingga ke-4.
   - `-u`: Menyaring hanya entri unik.
3. **Penyimpanan Berkas Sementara**: Output ditulis ke berkas temporer `.temp_ip.txt`.

#### E. Sinkronisasi Berkas Ganda (TXT & CSV) & Kalkulasi Metrik
```bash
cp "$TEMP_FILE" "$LIST_IP_TXT"
cp "$TEMP_FILE" "$LIST_IP_CSV"
rm -f "$TEMP_FILE"

COUNT_AFTER=$(grep -v '^[[:space:]]*$' "$LIST_IP_TXT" 2>/dev/null | wc -l | tr -d ' ')
DIFF=$((COUNT_AFTER - COUNT_BEFORE))
```
- Menyalin hasil pemrosesan bersih ke `ip_list.txt` dan `ip_list.csv` secara bersamaan, lalu menghapus file temporer.

#### F. Pemicu Generator Laporan
```bash
if [ -f "$GENERATE_MD_SCRIPT" ]; then
    echo "Memperbarui ip_list.md..."
    python3 "$GENERATE_MD_SCRIPT"
fi
```
- Mengeksekusi `generate_md.py` untuk memperbarui laporan intelijen `ip_list.md`.

---

### 3. Diagram Alur Pemrosesan Data

```mermaid
flowchart TD
    A[Mulai: bash run.sh] --> B[Resolve Absolute Path Direktori]
    B --> C{ip_new.txt Ditemukan?}
    C -- Tidak --> D[Cetak Error & Exit 1]
    C -- Ya --> E[Hitung COUNT_BEFORE & COUNT_EXCEPTION]
    E --> F[awk: Muat ip_exception.txt ke Memory Hash Table]
    F --> G[awk: Baca Aliran cat ip_list.txt + ip_new.txt]
    G --> H[awk: Sanitasi Whitespace & Filter Non-Exception]
    H --> I[sort -n -t . -k 1-4 -u: Urutkan Numerik per Oktet & Deduplikasi]
    I --> J[Tulis Stream ke .temp_ip.txt]
    J --> K[cp ke ip_list.txt & cp ke ip_list.csv]
    K --> L[Hapus .temp_ip.txt]
    L --> M[Hitung COUNT_AFTER & Selisih DIFF]
    M --> N[Cetak Ringkasan Metrik ke Terminal]
    N --> O{generate_md.py Tersedia?}
    O -- Ya --> P[Eksekusi python3 generate_md.py]
    P --> Q[Query API Caching & Update ip_list.md]
    O -- Tidak --> R[Selesai]
    Q --> R[Selesai dengan Sukses]
```

---

## Panduan Penggunaan

### 1. Konfigurasi API AbuseIPDB (Opsional)
Jika ingin mengaktifkan data reputasi ancaman siber pada `ip_list.md`:
1. Salin berkas template:
   ```bash
   cp .env.example .env
   ```
2. Buka `.env` dan masukkan API Key:
   ```env
   ABUSEIPDB_API_KEY=masukkan_api_key_disini
   ```

### 2. Manajemen Data IP
- **Menambah IP Baru**: Masukkan daftar IP ke dalam file `ip_new.txt` (satu IP per baris).
- **Mengecualikan IP (*Whitelist*)**: Masukkan IP yang ingin dihapus atau dikecualikan ke dalam `ip_exception.txt`.

### 3. Eksekusi Script
Pastikan izin eksekusi aktif:
```bash
chmod +x run.sh
```

Jalankan script:
```bash
./run.sh
```
atau
```bash
bash run.sh
```

### 4. Contoh Output Eksekusi Terminal
```text
==========================================
         PROSES PENYORTIRAN IP            
==========================================
Jumlah IP sebelumnya            : 58
Jumlah aturan pengecualian      : 2
Perubahan IP bersih             : -1
Total IP unik sekarang          : 57
Format database tersimpan       : ip_list.txt & ip_list.csv
------------------------------------------
Memperbarui ip_list.md...
Berhasil memperbarui /Users/hard13/labs/blackened/ip_list.md (Total: 57 IP)
==========================================
Proses selesai dengan sukses!
```
