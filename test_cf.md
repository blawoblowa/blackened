# Dokumentasi Teknis Cloudflare Rules List Manager (`test_cf.sh`)

Dokumen ini menjelaskan arsitektur teknis, spesifikasi API, serta panduan operasional skrip `test_cf.sh` untuk mengelola daftar alamat IP pada fitur **Cloudflare Rules Lists (WAF Custom Lists)**.

---

## 1. Gambaran Umum

Cloudflare Rules Lists memungkinkan administrator menyimpan kumpulan alamat IP atau CIDR yang dapat dirujuk secara dinamis oleh aturan WAF (Web Application Firewall). 

Skrip `test_cf.sh` berfungsi sebagai antarmuka baris perintah (CLI) untuk:
1. Membaca kredensial Cloudflare secara aman dari file konfigurasi `.env`.
2. Menambahkan alamat IP baru ke dalam daftar pemblokiran Cloudflare.
3. Mencari status dan `id` dari alamat IP yang terdaftar.
4. Menghapus alamat IP dari daftar Cloudflare secara otomatis tanpa perlu mencari `id` manual.
5. Menampilkan seluruh item yang ada di dalam list.

---

## 2. Prasyarat & Konfigurasi Lingkungan

### A. Variabel Environment (`.env`)

Skrip memerlukan tiga variabel lingkungan utama yang disimpan dalam file `.env`:

```env
# Cloudflare Account ID (dapat disalin dari dashboard Cloudflare pada menu Overview domain atau akun)
CLOUDFLARE_ACCOUNT_ID="your_account_id_here"

# Cloudflare API Token (Rekomendasi: Token dari menu Create Token)
# Atau Global API Key (berawalan cfk_)
CLOUDFLARE_API_TOKEN="your_api_token_here"

# Email Akun Cloudflare (Wajib diisi jika menggunakan Global API Key berawalan cfk_)
CLOUDFLARE_EMAIL="email_akun_cloudflare@domain.com"

# ID Rules List Cloudflare target
CLOUDFLARE_LIST_ID="your_list_id_here"
```

### B. Izin API Token Cloudflare (Permissions)

API Token harus dibuat melalui menu **User Profile > API Tokens > Create Token** dengan tipe **Custom Token**, dan memiliki hak akses minimum berikut:
- **Account Permissions**:
  - `Account Filter Lists` (atau `Account Rules Lists`): **Edit** (untuk menambah dan menghapus)
  - `Account Filter Lists` (atau `Account Rules Lists`): **Read** (untuk mencari dan melihat daftar)
- **Account Resources**:
  - Sertakan akun Cloudflare terkait (*Include - All accounts* atau *Specific account*).

---

## 3. Spesifikasi Teknis Cloudflare API v4

Cloudflare Rules Lists menerapkan model data berbasis entitas:
- Setiap penambahan IP akan menghasilkan **`id` unik (32 karakter hex)** yang dibuat oleh Cloudflare.
- **Operasi penambahan (POST)** menerima parameter `ip` dan `comment`.
- **Operasi penghapusan (DELETE)** **tidak menerima string IP langsung**, melainkan mewajibkan pengiriman array objek yang berisi `id` item.

### Alur Endpoint REST API

| Aksi | HTTP Method | Endpoint | Payload Request |
| :--- | :--- | :--- | :--- |
| **Tambah IP** | `POST` | `/accounts/{account_id}/rules/lists/{list_id}/items` | `[{"ip": "1.2.3.4", "comment": "Catatan"}]` |
| **Cari IP** | `GET` | `/accounts/{account_id}/rules/lists/{list_id}/items?search={query}` | Query string parameter `search` |
| **Hapus IP** | `DELETE` | `/accounts/{account_id}/rules/lists/{list_id}/items` | `{"items": [{"id": "<32_hex_item_id>"}]}` |

### Penanganan Operasi Asinkron

Operasi penambahan dan penghapusan item pada Cloudflare Rules Lists diproses secara asinkron di sisi Cloudflare:
- Respons sukses biasanya mengembalikan status HTTP `200` atau `201` beserta `operation_id`.
- Cloudflare menerapkan batas konkurensi **maksimum 1 operasi bulk tertunda per akun**.

---

## 4. Cara Kerja Skrip `test_cf.sh`

```
                  +--------------------------------+
                  |         Mulai Eksekusi         |
                  +---------------+----------------+
                                  |
                                  v
                  +--------------------------------+
                  |      Muat Variabel .env        |
                  |  (Bersihkan \r & Whitespace)   |
                  +---------------+----------------+
                                  |
                                  v
                   /------------------------------\
                  < Apakah Perintah Bantuan/Help?  >
                   \------------------------------/
                             /          \
                       Ya   /            \  Tidak
                           v              v
                  +---------------+ +--------------------------------+
                  | Tampilkan     | |      Validasi Kredensial       |
                  | Pesan Bantuan | | (CLOUDFLARE_ACCOUNT_ID, TOKEN, |
                  +---------------+ |      CLOUDFLARE_LIST_ID)       |
                                    +---------------+----------------+
                                                    |
                                                    v
                                      /---------------------------\
                                     <        Pilihan Aksi         >
                                      \---------------------------/
                                        /          |          \
                                  add  /    delete |           \ search/list
                                      v            v            v
                           +-------------+  +-------------+  +-------------+
                           |  Kirim POST |  | 1. Cari ID  |  |  Kirim GET  |
                           |  Array IP   |  |    via GET  |  |  Query IP   |
                           +-------------+  | 2. Kirim    |  +-------------+
                                            |    DELETE   |
                                            +-------------+
```

### Logika Penghapusan Otomatis (`action_delete`)
1. Pengguna hanya perlu memberikan input alamat IP target (contoh: `213.232.122.217`).
2. Fungsi `find_item_id_by_ip` mengeksekusi request `GET` ke Cloudflare dengan parameter `?search=213.232.122.217`.
3. Skrip mem-parsing JSON respons dan mencocokkan entitas yang memiliki properti `ip` identik untuk mengekstrak `id`.
4. Jika `id` ditemukan, skrip mengirim request `DELETE` dengan format `{"items": [{"id": "<id>"}]}`.
5. Jika `id` tidak ditemukan, skrip menginformasikan bahwa IP tersebut tidak ada di dalam list tanpa melakukan panggilan `DELETE` yang sia-sia.

---

## 5. Panduan Penggunaan CLI

### A. Menambahkan Alamat IP ke List

Menambahkan IP tunggal dengan komentar opsional:

```bash
./test_cf.sh add 213.232.122.217 "Manual Blocked Scanner"
```

Jika tidak menyertakan komentar, skrip menggunakan komentar standar `Added via Blackened Threat Intel`:

```bash
./test_cf.sh add 213.232.122.217
```

*Shorthand:* Jika argumen pertama langsung berupa alamat IP, skrip secara otomatis menjalankan aksi `add`:

```bash
./test_cf.sh 213.232.122.217
```

### B. Menghapus Alamat IP dari List

Menghapus IP berdasarkan alamatnya:

```bash
./test_cf.sh delete 213.232.122.217
```

Alias yang didukung: `del`, `remove`, `rm`.

```bash
./test_cf.sh del 213.232.122.217
```

### C. Mencari / Memeriksa IP di List

Memeriksa apakah suatu IP sudah terdaftar beserta status `id`-nya:

```bash
./test_cf.sh search 213.232.122.217
```

### D. Menampilkan Daftar Item List (Paginasi)

Melihat daftar item yang tersimpan di dalam Rules List (halaman pertama):

```bash
./test_cf.sh list
```

### E. Melihat Total Keseluruhan IP & Informasi List

Melihat ringkasan metadata list beserta jumlah total IP yang tersimpan di Cloudflare secara akurat:

```bash
./test_cf.sh info
# Atau alias: count, total
```

---

## 6. Contoh Output Respons

### Output Penambahan IP Berhasil
```
===> Menambahkan IP ke Cloudflare List...
Target List ID : a1b2c3d4e5f67890abcdef1234567890
Target IP      : 213.232.122.217
Komentar       : Manual Blocked Scanner
------------------------------------------
HTTP Status Code: 200
Response Body:
{
    "errors": [],
    "messages": [],
    "result": {
        "operation_id": "9876543210fedcba0987654321fedcba"
    },
    "success": true
}
------------------------------------------
```

### Output Penghapusan IP Berhasil
```
===> Mencari ID untuk IP: 213.232.122.217 pada Cloudflare List...
Ditemukan Item ID: f1e2d3c4b5a60718293a4b5c6d7e8f90
Mengirim request penghapusan ke Cloudflare...
------------------------------------------
HTTP Status Code: 200
Response Body:
{
    "errors": [],
    "messages": [],
    "result": {
        "operation_id": "5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d"
    },
    "success": true
}
------------------------------------------
```

---

## 7. Pemecahan Masalah (Troubleshooting)

| Kode HTTP / Gejala | Penyebab Umum | Solusi |
| :--- | :--- | :--- |
| **Konfigurasi belum lengkap** | Variabel `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, atau `CLOUDFLARE_LIST_ID` belum diisi di `.env`. | Buka file `.env` dan pastikan ketiga variabel sudah memiliki nilai yang valid. |
| **HTTP 401 Unauthorized** | Token API Cloudflare tidak valid atau sudah kedaluwarsa. | Buat token baru di Cloudflare Dashboard dengan izin yang sesuai. |
| **HTTP 403 Forbidden** | Token API valid, namun tidak memiliki hak akses *Edit* pada resource *Account Filter Lists*. | Tambahkan izin `Account Filter Lists: Edit` pada konfigurasi API Token di Cloudflare. |
| **HTTP 404 Not Found** | `CLOUDFLARE_ACCOUNT_ID` atau List ID (`CLOUDFLARE_LIST_ID`) salah. | Periksa kembali ID akun Cloudflare dan ID daftar pada dashboard. |
| **HTTP 400 Bad Request** | Format IP tidak valid atau IP sudah ada di dalam list (duplikasi). | Pastikan input IP memenuhi standar IPv4/IPv6 valid. Periksa duplikasi dengan `./test_cf.sh search <ip>`. |
| **HTTP 409 Conflict** | Ada operasi bulk lain yang sedang berlangsung di akun tersebut. | Tunggu beberapa detik hingga Cloudflare menyelesaikan operasi sebelumnya, kemudian jalankan kembali. |
| **Operasi Gagal: This account has reached the maximum number of items** | Total akumulasi IP dari seluruh Rules Lists di akun Cloudflare telah mencapai batas maksimum kuota (10.000 IP item). | Kurangi atau hapus IP tidak terpakai dari list lain di akun (seperti list `known_ip_vpn`), atau upgrade paket Cloudflare. |

