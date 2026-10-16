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
6. Memiliki mekanisme *HTTP universal* (otomatis menggunakan `curl` atau fallback ke `python3 urllib` jika `curl` tidak tersedia di container Docker).

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
| **Ambil Data Group** | `GET` | `/api/open/ipgroup` | `X-SLCE-API-TOKEN: <TOKEN>` | (Kosong) |
| **Perbarui IP Group** | `PUT` | `/api/open/ipgroup` | `X-SLCE-API-TOKEN: <TOKEN>` | `{"id": 12, "comment": "...", "reference": "", "ips": ["1.1.1.1", ...]}` |

### Logika Penambahan IP (`add`)
1. Mengambil data IP Group saat ini via `GET /api/open/ipgroup`.
2. Memeriksa apakah IP target sudah ada dalam array `ips`.
3. Jika belum ada, menyisipkan IP target ke dalam array `ips` tanpa menghapus IP lama.
4. Mengirimkan request `PUT /api/open/ipgroup` dengan array `ips` yang telah diperbarui.

### Logika Penghapusan IP (`delete`)
1. Mengambil data IP Group saat ini via `GET /api/open/ipgroup`.
2. Mencari dan mengeluarkan IP target dari array `ips`.
3. Mengirimkan request `PUT /api/open/ipgroup` dengan sisa array `ips` yang masih aktif.

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

---

## 5. Integrasi Otomatis dengan Bot WhatsApp (`run.sh`)

Skrip `run.sh` telah diintegrasikan untuk menjalankan pemblokiran ganda secara otomatis:
- Saat perintah WhatsApp `/block <ip>` diterima:
  1. IP disimpan ke database lokal (`ip_list.txt` & `ip_list.csv`).
  2. Data intelijen `ip_list.md` diperbarui.
  3. Skrip `test_cf.sh add <ip>` dieksekusi untuk memblokir di Cloudflare WAF.
  4. Skrip `test_safeline.sh add <ip>` dieksekusi untuk memblokir di SafeLine WAF.
- Saat perintah WhatsApp `/unblock <ip>` diterima:
  1. IP dihapus dari database lokal.
  2. Skrip `test_cf.sh delete <ip>` dieksekusi untuk menghapus dari Cloudflare WAF.
  3. Skrip `test_safeline.sh delete <ip>` dieksekusi untuk menghapus dari SafeLine WAF.
