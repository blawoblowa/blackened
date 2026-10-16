# Dokumentasi Teknis SafeLine WAF IP Group Manager (`test_safeline.sh`)

Dokumen ini menjelaskan arsitektur teknis, spesifikasi Open API, serta panduan operasional skrip `test_safeline.sh` untuk mengelola daftar pemblokiran alamat IP pada **SafeLine WAF IP Group**.

---

## 1. Gambaran Umum

SafeLine WAF (*Chaitin SafeLine Community / Enterprise Edition*) menggunakan konsep **IP Group** untuk mengelompokkan alamat IP yang akan dikenakan aturan keamanan (Blacklist/Whitelist/Drop).

Skrip `test_safeline.sh` berfungsi sebagai antarmuka baris perintah (CLI) yang:
1. Membaca konfigurasi SafeLine secara aman dari file `.env`.
2. Menambahkan IP baru ke dalam IP Group SafeLine tanpa menimpa (*overwrite*) IP yang sudah ada sebelumnya.
3. Mencari status keberadaan IP tertentu di dalam IP Group SafeLine.
4. Menghapus IP dari IP Group SafeLine secara selektif.
5. Menampilkan seluruh IP yang terdaftar di dalam IP Group.
6. Menyinkronkan basis data IP lokal (misalnya `ip_list.txt`) ke SafeLine WAF secara massal (*sync*).
7. Memiliki mekanisme *HTTP universal* (otomatis menggunakan `curl` atau fallback ke `python3 urllib` jika `curl` tidak tersedia di container Docker).

---

## 2. Prasyarat & Konfigurasi Lingkungan

### Variabel Environment (`.env`)

Tambahkan variabel berikut ke dalam file `.env`:

```env
# Alamat SafeLine Management Console (Port default 9443)
# Format dapat berupa IP:Port atau Domain
SAFELINE_URL="10.20.89.110:9443"

# API Token SafeLine (dibuat di System Settings > API Token)
SAFELINE_TOKEN="your_safeline_api_token"

# ID Numeric IP Group target yang terdaftar di SafeLine WAF
SAFELINE_GROUP="12"
```

---

## 3. Spesifikasi Teknis SafeLine WAF Open API

| Operasi | HTTP Method | Endpoint | Header | Payload Request |
| :--- | :--- | :--- | :--- | :--- |
| **Ambil Data Group** | `GET` | `/api/open/ipgroup?top=50000` | `X-SLCE-API-TOKEN: <TOKEN>` | (Kosong) |
| **Perbarui IP Group** | `PUT` | `/api/open/ipgroup` | `X-SLCE-API-TOKEN: <TOKEN>` | `{"id": 12, "comment": "...", "reference": "", "ips": ["1.1.1.1", ...]}` |

### Catatan Penting Mengenai SafeLine Open API
1. **Perilaku PUT Overwrite**: SafeLine Open API memperlakukan request `PUT /api/open/ipgroup` sebagai penggantian menyeluruh (*full replacement*) terhadap daftar IP pada grup tersebut. Setiap request `PUT` yang hanya mengirim 1 IP akan menimpa seluruh IP lama.
2. **Kebutuhan Parameter Query `top`**: Pada request `GET /api/open/ipgroup` tanpa parameter `top`, SafeLine mengembalikan ringkasan dengan array `ips: []` kosong. Oleh karena itu, skrip secara eksplisit menggunakan query parameter `?top=50000` untuk memastikan seluruh IP existing berhasil ditarik ke dalam memori sebelum digabungkan.
3. **Mekanisme Fail-Safe**: Jika SafeLine melaporkan jumlah `total` IP yang lebih besar daripada jumlah array `ips` yang berhasil ditarik, skrip akan membatalkan pembaruan secara otomatis untuk mencegah pemotongan data secara tidak sengaja.

### Logika Penambahan IP (`add`)
1. Mengambil data IP Group saat ini via `GET /api/open/ipgroup?top=50000`.
2. Memeriksa apakah IP target sudah ada dalam daftar IP existing:
   - Jika sudah ada, skrip memberikan informasi bahwa IP telah terdaftar dan tidak melakukan pembaruan redundan.
3. Jika belum ada, menyisipkan IP target ke dalam daftar IP lama:
   - Jumlah IP sebelum penambahan dicatat.
   - Array baru dibentuk: `[...existing_ips, target_ip]`.
4. Mengirimkan request `PUT /api/open/ipgroup` dengan daftar gabungan lengkap sehingga semua IP lama tetap terlindungi dan tersimpan di SafeLine WAF.

### Logika Penghapusan IP (`delete`)
1. Mengambil data IP Group saat ini via `GET /api/open/ipgroup?top=50000`.
2. Mencari IP target di dalam daftar IP:
   - Jika tidak ditemukan, skrip menginformasikan bahwa IP tidak ada di dalam grup.
3. Jika ditemukan, mengeluarkan hanya IP target tersebut: `[ip for ip in existing_ips if ip != target_ip]`.
4. Mengirimkan request `PUT /api/open/ipgroup` dengan sisa daftar IP yang masih aktif.

---

## 4. Panduan Penggunaan CLI

### A. Menambahkan IP ke SafeLine Blacklist

```bash
./test_safeline.sh add 213.232.122.217
```

*Shorthand:* Jika argumen pertama langsung berupa alamat IP, skrip secara otomatis menjalankan aksi `add`:
```bash
./test_safeline.sh 213.232.122.217
```

### B. Menghapus IP dari SafeLine Blacklist

```bash
./test_safeline.sh delete 213.232.122.217
```
Alias yang didukung: `del`, `remove`, `rm`.

### C. Mencari / Memeriksa Status IP

```bash
./test_safeline.sh search 213.232.122.217
```

### D. Menampilkan Seluruh IP di Group

```bash
./test_safeline.sh list
```

### E. Melihat Ringkasan Metadata Group (info / count)

```bash
./test_safeline.sh info
```

### F. Sinkronisasi File IP Lokal ke SafeLine WAF

Untuk menyinkronkan seluruh daftar IP lokal (misalnya `ip_list.txt`) ke SafeLine WAF tanpa menghapus IP yang sudah ada di SafeLine:

```bash
./test_safeline.sh sync ip_list.txt
```

---

## 5. Integrasi Otomatis dengan Bot WhatsApp (`run.sh`)

Skrip `run.sh` telah diintegrasikan untuk menjalankan pemblokiran ganda secara otomatis:
- Saat perintah WhatsApp `/block <ip>` diterima:
  1. IP disimpan ke database lokal (`ip_list.txt` & `ip_list.csv`).
  2. Data intelijen `ip_list.md` diperbarui.
  3. Skrip `test_cf.sh add <ip>` dieksekusi untuk memblokir di Cloudflare WAF.
  4. Skrip `test_safeline.sh add <ip>` dieksekusi untuk memblokir di SafeLine WAF (mempertahankan IP lama dan menambah IP baru).
- Saat perintah WhatsApp `/unblock <ip>` diterima:
  1. IP dihapus dari database lokal.
  2. Skrip `test_cf.sh delete <ip>` dieksekusi untuk menghapus dari Cloudflare WAF.
  3. Skrip `test_safeline.sh delete <ip>` dieksekusi untuk menghapus dari SafeLine WAF.
