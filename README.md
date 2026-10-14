# Blackened - IP Management & Threat Intelligence Utility

Blackened adalah utilitas otomatisasi berbasis *shell script* (`run.sh`) dan modul Python (`generate_md.py`) yang dirancang untuk mengelola, memvalidasi sintaks, menyortir, membersihkan (sanitasi), mendeduplikasi, mengecualikan (*whitelist*), memproteksi IP Merchant resmi, meng-unblock (menghapus IP), serta memperkaya daftar IP address (*threat intelligence feed*) dengan data geolokasi, ISP, ASN, reputasi ancaman AbuseIPDB, dan riwayat waktu penambahan (*timestamp* GMT+7) secara otomatis.

Hasil penyortiran basis data IP disimpan secara simultan dalam **dua format file**: `.txt` (`ip_list.txt`) dan `.csv` (`ip_list.csv`), serta menghasilkan dokumen laporan intelijen komprehensif (`ip_list.md`).

---

## Daftar Isi
- [1. Fitur Utama](#1-fitur-utama)
  - [A. Modul Orkestrasi & Pemrosesan (run.sh)](#a-modul-orkestrasi--pemrosesan-runsh)
  - [B. Modul Pengayaan Intelijen (generate_md.py)](#b-modul-pengayaan-intelijen-generate_mdpy)
- [2. Spesifikasi Kebutuhan Sistem](#2-spesifikasi-kebutuhan-sistem)
- [3. Struktur Direktori Proyek](#3-struktur-direktori-proyek)
- [4. Rincian Teknis & Arsitektur](#4-rincian-teknis--arsitektur)
  - [A. Bedah Logika & Pipeline run.sh](#a-bedah-logika--pipeline-runsh)
  - [B. Bedah Engine generate_md.py](#b-bedah-engine-generate_mdpy)
  - [C. Struktur Penyimpanan Cache (.ip_cache.json)](#c-struktur-penyimpanan-cache-ip_cachejson)
  - [D. Diagram Alur Kerja Sistem](#d-diagram-alur-kerja-sistem)
- [5. Panduan Penggunaan & Konfigurasi](#5-panduan-penggunaan--konfigurasi)
  - [A. Konfigurasi Environment (.env)](#a-konfigurasi-environment-env)
  - [B. Manajemen Berkas Masukan (Input Files)](#b-manajemen-berkas-masukan-input-files)
  - [C. Menjalankan Skrip](#c-menjalankan-skrip)
  - [D. Contoh Output Eksekusi Terminal](#d-contoh-output-eksekusi-terminal)
- [6. Praktik Terbaik & Pemeliharaan](#6-praktik-terbaik--pemeliharaan)

---

## 1. Fitur Utama

### A. Modul Orkestrasi & Pemrosesan (`run.sh`)
- **Resolusi Jalur Dinamis (*Dynamic Path Resolution*)**: Mengidentifikasi direktori kerja secara independen dari lokasi pemanggilan terminal (`pwd`), memungkinkan skrip dijalankan dari direktori mana pun atau via cron job.
- **Validasi Sintaks Format Alamat IP**: Memvalidasi integritas alamat IPv4 (4 oktet 0-255 tanpa ambiguitas leading zero) dan IPv6. Baris masukan yang bukan format IP valid (misalnya nama domain atau string cacat) otomatis ditolak dan dilaporkan di terminal.
- **Proteksi IP Merchant & Peringatan Otomatis**: Memindai file input `ip_new.txt` terhadap daftar `ip_merchant.txt`. Jika terdeteksi adanya IP merchant resmi, sistem menampilkan banner peringatan di terminal, menandai IP sebagai ditolak (`[DITOLAK]`), dan secara otomatis mengecualikannya dari database.
- **Penyaringan Pengecualian (*Whitelist / Exception Filtering*)**: Mengecualikan IP yang terdaftar di `ip_exception.txt` menggunakan *in-memory hash table* berbasis `awk` berkinerja tinggi.
- **Mekanisme Penghapusan / Unblock IP (`ip_unblock.txt`)**: Mengeluarkan IP dari database secara langsung, mengosongkan antrean unblock secara otomatis setelah eksekusi, serta menghasilkan pesan commit khusus saat hanya ada proses penghapusan.
- **Pembersihan Cache Otomatis untuk IP yang Dikeluarkan**: IP yang dikeluarkan/di-unblock dari database otomatis dihapus dari berkas cache lokal `.ip_cache.json` untuk menjaga efisiensi penyimpanan.
- **Sanitasi Data Multi-Tahap**: Menghapus karakter Line Ending Windows (`\r`), UTF-8 BOM (`\xef\xbb\xbf`), spasi awal/akhir (*trimming*), dan baris kosong.
- **Pengurutan Numerik per Oktet & Deduplikasi**: Mengurutkan alamat IPv4 berdasarkan nilai numerik 4 oktet secara hierarkis (`sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4`) dan menghapus duplikasi entri dalam satu lintasan (*single-pass*).
- **Sinkronisasi Format Ganda (*Dual Database Output*)**: Menyimpan hasil pemrosesan bersih ke `ip_list.txt` dan `ip_list.csv` secara bersamaan dan konsisten.
- **Pembaruan Atomik (*Atomic Update*)**: Menulis berkas temporer (`.temp_ip.txt`) sebelum proses pergantian (*file swap*) untuk mencegah korupsi data saat eksekusi terputus.
- **Auto Commit & Push GitHub (Non-Blocking)**: Mendukung pengunggahan otomatis berkas `ip_list.txt`, `ip_list.csv`, dan `ip_list.md` ke repositori remote (`AUTO_GIT_PUSH=true`) dengan proteksi *non-blocking* (`GIT_TERMINAL_PROMPT=0`) serta integrasi `GITHUB_TOKEN`.

### B. Modul Pengayaan Intelijen (`generate_md.py`)
- **Pengayaan Geografis & Jaringan (GeoIP Batch Lookup)**: Mengambil metadata negara, provinsi/wilayah, kota, ISP, organisasi/cloud tenant, ASN, dan indikator proxy/VPN dalam batch 50 IP per *request* (`http://ip-api.com/batch`).
- **Integrasi AbuseIPDB (Threat Intelligence)**: Mengambil skor kepastian ancaman (*Abuse Confidence Score*), total akumulasi laporan serangan global, dan jenis penggunaan jaringan (*usage type*) secara otomatis jika API Key dikonfigurasi.
- **Sistem Caching Persisten (`.ip_cache.json`)**: Menyimpan seluruh metadata hasil query API secara lokal. IP yang telah ada di-*cache* tidak akan di-query ulang, sehingga pemrosesan berkala berlangsung instan dan hemat kuota API.
- **Utilitas Pembersihan Cache CLI (`--clean-cache`)**: Modul mendukung sub-perintah untuk menghapus entri cache spesifik saat IP dikeluarkan dari database.
- **Pelacakan Riwayat Timestamp (GMT+7)**: Mencatat waktu penambahan IP ke database dalam format zona waktu GMT+7 / WIB (`YYYY-MM-DD HH:MM:SS (GMT+7)`).
- **Ringkasan Eksekutif & Analisis Statistik**: Menyajikan klasifikasi tingkat risiko ancaman (Tinggi, Sedang, Bersih), total akumulasi insiden serangan global, distribusi tipe infrastruktur jaringan (Hosting/Data Center, Mobile, Residential), serta Top 5 Negara dan Top 5 ISP/Cloud Provider.
- **Sanitasi Tabel Markdown**: Mengonversi karakter pipe (`|`) pada nama ISP, organisasi, dan ASN menjadi slash (`/`) agar format tabel Markdown tetap rapi dan tidak rusak.

---

## 2. Spesifikasi Kebutuhan Sistem

- **Sistem Operasi**: Linux / macOS / BSD (lingkungan POSIX-compliant)
- **Shell**: Bash 3.2 atau lebih baru
- **Utilitas Core**: `awk`, `sed`, `sort`, `grep`, `wc`, `tr`, `git`
- **Python Runtime**: Python 3.7+ (menggunakan modul bawaan: `datetime`, `json`, `os`, `sys`, `time`, `urllib`, `collections` tanpa memerlukan *third-party dependencies*)
- **Konektivitas Jaringan**: Akses HTTP/HTTPS ke `ip-api.com` dan `api.abuseipdb.com`

---

## 3. Struktur Direktori Proyek

```text
blackened/
|-- ip_list.txt        # Basis data daftar IP bersih dan terurut (Format TXT)
|-- ip_list.csv        # Basis data daftar IP bersih dan terurut (Format CSV)
|-- ip_list.md         # Laporan intelijen IP lengkap (tabel & analitik)
|-- ip_new.txt         # Berkas masukan daftar IP baru yang akan diproses
|-- ip_unblock.txt     # Berkas masukan daftar IP yang akan di-unblock / dihapus
|-- ip_exception.txt   # Berkas whitelist/pengecualian manual (diabaikan dari database)
|-- ip_merchant.txt    # Berkas whitelist resmi IP Merchant terproteksi
|-- run.sh             # Skrip orkestrasi utama (Bash entrypoint)
|-- generate_md.py     # Modul pengayaan intelijen & generator dokumen Markdown
|-- .env.example       # Template konfigurasi environment
|-- .env               # Berkas konfigurasi lokal (API Key & Auto Push)
|-- .ip_cache.json     # Berkas cache lokal metadata IP (dibuat otomatis)
|-- LICENSE            # Lisensi proyek
`-- README.md          # Dokumentasi teknis proyek
```

---

## 4. Rincian Teknis & Arsitektur

### A. Bedah Logika & Pipeline `run.sh`

#### 1. Inisialisasi Jalur & Pemuatan Variabel Lingkungan
Skrip menentukan direktori absolut berdasarkan lokasi berkas `run.sh` berada, lalu memuat variabel dari `.env` dan direktori induk:
```bash
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
```

#### 2. Validasi Sintaks IP & Pemindaian Proteksi IP Merchant
Sebelum pemrosesan, skrip memvalidasi format IP pada `ip_new.txt` dan memindai konflik terhadap `ip_merchant.txt`:
```bash
# Validasi sintaks format IPv4 / IPv6
function is_valid_ipv4(ip,   octets, n, i, v) {
    if (ip !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) return 0
    n = split(ip, octets, ".")
    if (n != 4) return 0
    for (i = 1; i <= 4; i++) {
        v = octets[i] + 0
        if (v < 0 || v > 255) return 0
        if (octets[i] ~ /^0[0-9]+$/) return 0
    }
    return 1
}
function is_valid_ipv6(ip) {
    if (ip !~ /^[0-9a-fA-F:]+$/) return 0
    if (ip !~ /:/) return 0
    if (ip ~ /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/) return 1
    return 0
}
```
Jika ditemukan IP tidak valid atau terdaftar sebagai merchant, skrip menampilkan banner peringatan dan menolak IP tersebut secara otomatis.

#### 3. Pembersihan Data, Filter Whitelist Ganda, Unblock, dan Sort Numerik
Pemrosesan dilakukan dalam satu *stream pipeline* berkinerja tinggi:
```bash
awk '
    # Tahap 1: Muat aturan pengecualian
    FILENAME == ARGV[1] { exc[$0] = 1; next }
    # Tahap 2: Muat daftar merchant terproteksi
    FILENAME == ARGV[2] { merchant[$0] = 1; next }
    # Tahap 3: Muat daftar unblock
    FILENAME == ARGV[3] { unblock[$0] = 1; next }
    # Tahap 4: Filter gabungan data
    {
        if ($0 != "" && is_valid_ip($0) && !($0 in exc) && !($0 in merchant) && !($0 in unblock)) {
            print $0
        }
    }
' "$EXCEPTION_IP" "$MERCHANT_IP" "$UNBLOCK_IP" <(cat "$LIST_IP_TXT" "$NEW_IP" 2>/dev/null) \
    | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 -u > "$TEMP_FILE"
```

Penjelasan opsi utilitas `sort`:
- `-n`: Pengurutan berdasarkan nilai numerik (bukan abjad/leksikografis).
- `-t .`: Tanda titik (`.`) ditetapkan sebagai pemisah (*delimiter*) antar oktet IPv4.
- `-k 1,1 -k 2,2 -k 3,3 -k 4,4`: Mengurutkan kolom oktet ke-1, dilanjutkan oktet ke-2, ke-3, hingga ke-4.
- `-u`: Menghilangkan seluruh duplikasi entri (*unique*).

#### 4. Pembaruan Atomik, Pembersihan Cache, & Eksekusi Generator
1. Hasil dari `.temp_ip.txt` disalin ke `ip_list.txt` dan `ip_list.csv` jika ada perbedaan (`cmp -s`).
2. Berkas `ip_unblock.txt` dikosongkan secara otomatis setelah seluruh entri selesai diproses.
3. Modul `generate_md.py` dipanggil untuk memperbarui laporan `ip_list.md`.
4. Jika ada IP yang di-unblock (`REMOVED_IPS`), skrip mengeksekusi `python3 generate_md.py --clean-cache "$REMOVED_IPS"` untuk membersihkan cache lokal.

#### 5. Integrasi Git Otomatis (*Auto Push*)
Jika `AUTO_GIT_PUSH=true`, skrip menambahkan perubahan database ke *staging area*, membuat *commit* (dengan deteksi pesan commit khusus penambahan atau penghapusan unblock), dan melakukan `git push` secara aman menggunakan `GITHUB_TOKEN`.

---

### B. Bedah Engine `generate_md.py`

#### 1. Manajemen Waktu & Zona Waktu GMT+7
Modul mendefinisikan zona waktu presisi:
```python
TZ_GMT7 = datetime.timezone(datetime.timedelta(hours=7))

def get_current_time_gmt7():
    return datetime.datetime.now(TZ_GMT7).strftime("%Y-%m-%d %H:%M:%S (GMT+7)")
```

#### 2. Mekanisme Batch Lookup GeoIP & Caching
Permintaan geolokasi dikirim dalam blok 50 IP per panggilan HTTP POST ke `http://ip-api.com/batch`. Seluruh hasil disimpan persisten di `.ip_cache.json`.

#### 3. Integrasi AbuseIPDB API
Jika variabel `ABUSEIPDB_API_KEY` tersedia, script mengambil informasi reputasi keamanan via endpoint:
`https://api.abuseipdb.com/api/v2/check?ipAddress={ip}&maxAgeInDays=90`

Data yang diekstrak meliputi:
- `abuseConfidenceScore`: Persentase kepastian indikasi serangan (0 - 100%).
- `totalReports`: Jumlah total insiden serangan yang dilaporkan komunitas global.
- `lastReportedAt`: Waktu laporan terakhir tercatat.
- `usageType`: Kategori penggunaan jaringan oleh penyedia IP.

#### 4. Penyusunan Tabel 13 Kolom & Statistik Analitik
Modul merender dokumen `ip_list.md` dengan struktur tabel komprehensif:
- Kolom Tabel: `No`, `IP Address`, `Skor Abuse`, `Total Laporan`, `Tipe`, `ISP / Provider`, `Organisasi / Cloud Tenant`, `Negara`, `Provinsi / Wilayah`, `Kota`, `ASN`, `Proxy/VPN`, `Waktu Ditambahkan`.
- Analitik: Klasifikasi Ancaman (*High Risk*, *Suspicious*, *Clean*), Tipe Infrastruktur (*Data Center/Hosting*, *Mobile/Cellular*, *Residential/ISP*), Top 5 Negara Asal, dan Top 5 Provider/ISP.

---

### C. Struktur Penyimpanan Cache (`.ip_cache.json`)

Struktur penyimpanan JSON lokal dirancang terstruktur dan menyimpan *state* waktu penambahan masing-masing IP:
```json
{
  "20.24.217.162": {
    "status": "success",
    "country": "Hong Kong",
    "countryCode": "HK",
    "regionName": "Central and Western District",
    "city": "Hong Kong",
    "isp": "Microsoft Corporation",
    "org": "Microsoft Azure Cloud (eastasia)",
    "as": "AS8075 Microsoft Corporation",
    "mobile": false,
    "proxy": false,
    "hosting": true,
    "query": "20.24.217.162",
    "added_at": "2026-10-09 10:42:58 (GMT+7)",
    "abuse_data": {
      "abuseConfidenceScore": 100,
      "totalReports": 137,
      "lastReportedAt": "2026-10-09T00:53:57+00:00",
      "usageType": "Data Center/Web Hosting/Transit"
    }
  }
}
```

---

### D. Diagram Alur Kerja Sistem

```mermaid
flowchart TD
    A[Mulai: bash run.sh] --> B[Inisialisasi Path & Baca .env]
    B --> C{ip_new.txt Ditemukan?}
    C -- Tidak --> D[Tampilkan Error & Keluar]
    C -- Ya --> E[Pindai Format IP & Cek IP Merchant]
    E --> F{Ada Format Tidak Valid / Merchant?}
    F -- Ya --> G[Tampilkan Banner Peringatan & Daftar Ditolak]
    F -- Tidak --> H[Lanjutkan Proses]
    G --> H
    H --> I[awk: Filter Exception, Merchant, Unblock + Validasi IP + sort -u]
    I --> J[Tulis Hasil ke .temp_ip.txt]
    J --> K[Sinkronisasi ke ip_list.txt & ip_list.csv]
    K --> L[Hapus .temp_ip.txt & Kosongkan ip_unblock.txt]
    L --> M[Update ip_list.md via generate_md.py]
    M --> N{Ada IP Di-unblock?}
    N -- Ya --> O[Panggil generate_md.py --clean-cache]
    N -- Tidak --> P[Cetak Detail & Metrik ke Terminal]
    O --> P
    P --> Q{AUTO_GIT_PUSH Diaktifkan?}
    Q -- Ya --> R[git add, commit & push ke Remote Repository]
    Q -- Tidak --> S[Selesai]
    R --> S[Selesai dengan Sukses]
```

---

## 5. Panduan Penggunaan & Konfigurasi

### A. Konfigurasi Environment (`.env`)
Buat berkas `.env` dari template:
```bash
cp .env.example .env
```

Sesuaikan parameter di `.env`:
```env
# API Key AbuseIPDB untuk pengambilan skor reputasi ancaman
ABUSEIPDB_API_KEY=masukkan_api_key_disini

# Aktifkan auto commit & push ke GitHub (true / false)
AUTO_GIT_PUSH=true

# Personal Access Token GitHub (opsional untuk autentikasi push)
GITHUB_TOKEN=ghp_masukkan_token_disini
```

### B. Manajemen Berkas Masukan (*Input Files*)

1. **Memasukkan IP Baru**: Masukkan daftar alamat IPv4 atau IPv6 ke dalam `ip_new.txt` (satu IP per baris).
2. **Menghapus / Meng-unblock IP**: Masukkan daftar IP yang ingin dihapus dari database ke dalam `ip_unblock.txt`. Skrip akan mengeluarkan IP tersebut dari database, membersihkan cache lokalnya, dan mengosongkan berkas `ip_unblock.txt` secara otomatis.
3. **Mengecualikan IP Manual (*Whitelist*)**: Masukkan IP yang ingin dicegah masuk ke database secara permanen ke dalam `ip_exception.txt`.
4. **Proteksi IP Merchant Resmi**: Masukkan IP merchant ke dalam `ip_merchant.txt`. IP ini akan otomatis terdeteksi, diberi peringatan penolakan, dan diproteksi dari pemblokiran.

### C. Menjalankan Skrip
Pastikan izin eksekusi skrip telah diberikan:
```bash
chmod +x run.sh
```

Eksekusi skrip:
```bash
./run.sh
```
atau
```bash
bash run.sh
```

### D. Contoh Output Eksekusi Terminal

```text
===================================
PERINGATAN: FORMAT IP TIDAK VALID!
===================================
Ditemukan 1 entri pada ip_new.txt dengan format IP tidak valid:
  ! [TIDAK VALID] google.com
Seluruh entri di atas OTOMATIS DIABAIKAN dan TIDAK dimasukkan ke database.
--------------------------------
===================================
PERINGATAN: IP MERCHANT TERDETEKSI!
===================================
Ditemukan 1 IP pada ip_new.txt yang terdaftar sebagai IP Merchant:
  - [DITOLAK] 85.187.128.33
Seluruh IP di atas OTOMATIS DITOLAK dan TIDAK dimasukkan ke database.
--------------------------------
Update data intelijen ip_list.md...
Berhasil update ip_list.md (Total: 219 IP)
--------------------------------
Jumlah IP sebelumnya: 212
Jumlah aturan pengecualian: 2
Jumlah IP Merchant terproteksi: 1309
Perubahan IP bersih: +7
Total IP unik sekarang: 219
Format database tersimpan: ip_list.txt & ip_list.csv
--------------------------------
Detail Penambahan IP Baru (1 IP):
  + [BARU] 34.187.181.50
    - Skor Abuse: 100% (50 laporan)
    - ISP / Provider: Google LLC
    - Organisasi / Cloud Tenant: Google Cloud (us-west1)
    - Negara: United States
    - Provinsi: Oregon
    - Kota: The Dalles
    - ASN: AS396982 Google LLC
    - Proxy/VPN                 : Tidak

Format IP Tidak Valid (1 IP):
  ! [TIDAK VALID] google.com
--------------------------------
Memeriksa status git untuk ip_list.*...
Auto-commit & push ke GitHub...
[main bd45e03] Update IP intelligence list (Total: 219 IPs - 2026-10-14 15:30:29)
 3 files changed, 209 insertions(+), 188 deletions(-)
Berhasil push ke GitHub (branch: main)
--------------------------------
Proses selesai dengan sukses!
```

---

## 6. Praktik Terbaik & Pemeliharaan

1. **Pembersihan `ip_new.txt`**: Setelah `run.sh` selesai dieksekusi dan seluruh IP telah masuk ke database, Anda dapat mengosongkan atau menghapus isi `ip_new.txt` sebelum menambahkan daftar IP berikutnya.
2. **Kerahasiaan Kredensial**: Jangan pernah melakukan commit file `.env`, `ip_merchant.txt`, atau `ip_exception.txt` yang memuat data sensitif ke repositori publik. Pastikan file-file tersebut terdaftar dalam `.gitignore`.
3. **Penyimpanan Cache**: Berkas `.ip_cache.json` dirawat secara otomatis (entri unblock dibersihkan dan entri baru di-cache). Jangan menghapus `.ip_cache.json` secara manual kecuali jika ingin memperbarui seluruh data intelijen dari awal.
4. **Pembaruan Berkala**: Skrip `run.sh` dapat dijadwalkan secara berkala menggunakan `cron` untuk otomatisasi sinkronisasi data intelijen ancaman IP secara berkelanjutan.
