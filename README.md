# Sistem Permintaan Meterai — General Affairs

Platform internal untuk pengajuan, pelacakan, dan pengelolaan permintaan meterai. Dibangun sebagai **Progressive Web App** single-file dengan backend Supabase, sehingga dapat diinstal di perangkat mobile, dapat diakses offline (untuk halaman yang sudah dimuat), dan dideploy di hosting statis manapun.

---

## ✨ Fitur Utama

### 🌐 Halaman Publik (Landing Page)

- **Statistik real-time** — total meterai keluar, total permintaan bulan ini, jumlah pending, dan total stok seluruh lokasi
- **Grafik bulanan** — top 10 departemen berdasarkan jumlah permintaan, dapat difilter per bulan
- **Form permintaan meterai** dengan field:
  - Kode permintaan auto-generate format `MET-DDMMYYYY###` (mis. `MET-08052026001`)
  - Nama pemohon, departemen, divisi, lokasi kerja
  - Jumlah meterai dengan kontrol increment/decrement
  - Tujuan penggunaan
  - Konfirmasi kebenaran data wajib dicentang sebelum submit
- **Modal sukses** dengan animasi checkmark, tombol salin kode, dan pesan instruksi
- **Pelacakan status** — input kode permintaan, lihat status terkini beserta keterangan dari admin
- **Panduan penggunaan** 4 langkah bergambar
- **Footer institusional**

### 🔐 Admin Panel

- **Login** via Supabase Auth (email + password)
- **Dashboard**
  - 4 kartu statistik (total meterai keluar, permintaan bulan ini, pending, total stok)
  - 3 kartu stok per lokasi dengan indikator status (Aman/Menipis/Habis)
  - Tabel permintaan pending (maksimal 5, dengan pagination)
- **Data Permintaan**
  - Tabel permintaan lengkap dengan pencarian dan filter status
  - Pagination
  - Edit status via modal dengan keterangan wajib dan info stok kontekstual
- **Manajemen Stok**
  - 3 kartu lokasi (Wisma Nusantara, Transport Hub, Depo Lebak Bulus)
  - Operasi: Tambah, Kurangi, Edit (set absolut)
  - Setiap mutasi tercatat di audit log dengan keterangan dan timestamp
  - Tabel histori perubahan stok dengan pagination
- **Log Aktivitas**
  - Riwayat lengkap: login, logout, update status, mutasi stok
  - Filter per jenis aksi + pencarian bebas (user/target/deskripsi)
  - Pagination, refresh manual
  - Tampil siapa yang melakukan apa, kapan, dan detail metadata-nya

### 🔄 Sinkronisasi Stok Otomatis

- **Status diubah ke `Selesai`** → stok berkurang otomatis di lokasi sesuai `lokasi_kerja` permintaan, tercatat di `stock_log`
- **Status `Selesai` diubah ke status lain** → stok dikembalikan otomatis (rollback), tercatat sebagai `TAMBAH` di audit log
- **Validasi stok** — kalau stok tidak cukup, transaksi ditolak dengan pesan jelas: `"Stok tidak cukup di X. Tersedia: Y, dibutuhkan: Z"`
- **Idempotent** — aman dari double-deduction (flag `stock_deducted` mencegah pengurangan ganda)
- **Concurrency-safe** — pakai `FOR UPDATE` row lock, aman jika dua admin update bersamaan

### 📱 Progressive Web App

- Dapat di-install ke home screen di Android/iOS/desktop
- Service worker terdaftar inline (single-file architecture)
- Manifest embedded sebagai data URL dengan ikon SVG
- Theme color & viewport meta untuk pengalaman native

### 🎨 Design System

- Tone warna **MRT Jakarta**: deep blue (`#0F4C81`) + green (`#00A651`)
- Typography: **Plus Jakarta Sans** (Google Fonts)
- Iconography: **Material Symbols Rounded**
- Modern minimalist, gradient mesh, micro-interactions
- Responsive: mobile (≤768px), tablet, laptop/desktop
- Sidebar admin: collapsible (mini mode di desktop, drawer + overlay di mobile)
- Dark-mode-ready CSS variables (token-based)

---

## 📁 Struktur File

```
.
├── index.html                    # Aplikasi PWA single-file (HTML + CSS + JS)
├── database.sql                  # Skema lengkap Supabase (untuk install fresh)
├── migration_stock_sync.sql      # Migrasi v1.1: sinkronisasi otomatis stok
├── migration_activity_log.sql    # Migrasi v1.2: log aktivitas admin
└── README.md                     # File ini
```

---

## 🚀 Instalasi & Deployment

### 1. Setup Backend (Supabase)

**Untuk instalasi baru:**

1. Buat project baru di [supabase.com](https://supabase.com)
2. Buka **SQL Editor** → **New query**
3. Paste seluruh isi `database.sql` → klik **Run**
4. Verifikasi: tabel `requests`, `stock`, `stock_log` muncul di **Table Editor**

**Untuk database lama yang sudah berisi data:**

- Run `migration_stock_sync.sql` saja (idempotent, tidak hapus data)
- **Jangan** run ulang `database.sql` karena akan reset seluruh tabel

### 2. Buat Akun Admin

1. Sidebar Supabase → **Authentication** → **Users**
2. Klik **Add user** → **Create new user**
3. Isi email + password (centang **Auto Confirm User**)
4. Ulangi untuk admin tambahan jika diperlukan

### 3. Konfigurasi Frontend

Buka `index.html`, cari di bagian script paling atas:

```javascript
const SUPABASE_URL  = 'https://YOUR-PROJECT-ID.supabase.co';
const SUPABASE_ANON = 'YOUR-ANON-PUBLIC-KEY';
```

Ganti dengan kredensial dari **Supabase Settings → API**:
- **Project URL** → `SUPABASE_URL`
- **anon public** key → `SUPABASE_ANON`

### 4. Hosting

`index.html` adalah file tunggal yang berdiri sendiri. Bisa di-host di:

- **Netlify** — drag & drop folder
- **Vercel** — `vercel deploy`
- **GitHub Pages** — push ke repo, enable Pages
- **Cloudflare Pages** — connect repo
- **Server internal** — letakkan di Apache/Nginx
- **Local** — buka langsung di browser untuk testing

---

## 🗄️ Skema Database

### Tabel

| Tabel | Deskripsi |
|---|---|
| `requests` | Permintaan meterai (kode, pemohon, status, dll + flag `stock_deducted`) |
| `stock` | Stok per area (3 lokasi pre-seeded) |
| `stock_log` | Audit log seluruh perubahan stok |
| `activity_log` | Audit log aktivitas admin (login, status, stok) |

### RPC Functions

| Function | Akses | Kegunaan |
|---|---|---|
| `create_meterai_request(...)` | anon, authenticated | Submit form, generate kode atomik |
| `update_request_status(kode, status, keterangan)` | authenticated | Update status + auto-sync stok + auto-log |
| `adjust_stock(area, perubahan, tipe, keterangan)` | authenticated | Tambah/kurangi stok manual + auto-log |
| `set_stock(area, jumlah_baru, keterangan)` | authenticated | Set nilai stok absolut + auto-log |
| `log_activity(action, target, description, metadata)` | authenticated | Log LOGIN/LOGOUT dari frontend |

### Views

| View | Kegunaan |
|---|---|
| `v_dashboard_summary` | Agregat untuk dashboard (total keluar, pending, dll) |
| `v_monthly_stats` | Agregat per bulan + departemen untuk grafik |

### Row Level Security

- **anon** — INSERT permintaan, SELECT permintaan/stok/stock_log (untuk tracking & statistik publik)
- **authenticated** — Full access ke seluruh tabel & RPC, termasuk `activity_log`
- **`activity_log`** — admin-only (anon **tidak** bisa membaca log aktivitas demi privasi)

---

## 📋 Status Permintaan

| Status | Arti | Pengaruh ke Stok |
|---|---|---|
| `Belum Dikonfirmasi` | Default saat baru disubmit | Tidak ada |
| `Sedang Disiapkan` | Admin sedang menyiapkan | Tidak ada |
| `Tersedia` | Siap diambil pemohon | Tidak ada |
| `Ditolak` | Permintaan ditolak | Tidak ada (atau rollback jika sebelumnya Selesai) |
| `Selesai` | Sudah diserahkan ke pemohon | **Stok berkurang otomatis** |

---

## 📝 Changelog

### v1.2.0 — 8 Mei 2026

**Log aktivitas admin**

- ➕ Tabel baru `activity_log` untuk audit trail seluruh aktivitas admin
- ➕ RPC `log_activity` (frontend) untuk catat LOGIN/LOGOUT
- 🔄 RPC `update_request_status`, `adjust_stock`, `set_stock` sekarang otomatis menulis ke `activity_log` (siapa, kapan, apa, detail metadata JSONB)
- 🎨 Halaman baru di admin sidebar: **Log Aktivitas**
  - Tabel: Waktu | User | Aksi | Target | Deskripsi
  - Filter dropdown per jenis aksi (Login, Logout, Update Status, Stok Tambah/Kurangi/Edit)
  - Pencarian bebas (user / target / deskripsi)
  - Pagination + tombol refresh
  - Action chip warna-warni dengan ikon kontekstual
- 🔐 RLS: `activity_log` admin-only — anon tidak bisa lihat siapa login kapan
- 📁 File baru: `migration_activity_log.sql` untuk apply ke database lama tanpa reset

### v1.1.0 — 8 Mei 2026

**Sinkronisasi otomatis stok**

- ➕ Tambah kolom `stock_deducted` di tabel `requests`
- 🔄 Update function `update_request_status`:
  - Status → `Selesai` otomatis kurangi stok di lokasi sesuai `lokasi_kerja`
  - Status `Selesai` → status lain otomatis rollback stok
  - Validasi stok cukup sebelum kurangi (transaction abort jika tidak cukup)
  - Pakai `FOR UPDATE` lock untuk concurrency safety
  - Idempotent — flag `stock_deducted` mencegah double-deduction
- 🎨 Modal edit status sekarang menampilkan info banner kontekstual:
  - 🟢 Hijau: stok cukup, akan dikurangi
  - 🔴 Merah: stok tidak cukup, peringatan jelas
  - 🟡 Kuning: rollback stok karena dibatalkan dari Selesai
  - 🔵 Biru: info stok biasa
- ♻️ Refresh otomatis dashboard, daftar permintaan, dan halaman stok setelah update status — UI selalu sinkron tanpa reload manual
- 📁 File baru: `migration_stock_sync.sql` untuk apply ke database lama tanpa reset data

### v1.0.0 — 7 Mei 2026

**Initial release**

- 🎉 Landing page dengan statistik, form permintaan, tracking, dan panduan
- 🔐 Admin panel: dashboard, data permintaan, manajemen stok
- 🆔 Auto-generate kode permintaan format `MET-DDMMYYYY###` (atomic, race-condition safe)
- 📊 Grafik permintaan bulanan per departemen (Chart.js)
- 📦 CRUD stok per lokasi dengan audit log lengkap
- 🔍 Pencarian & filter di tabel permintaan dengan pagination
- 📱 PWA: installable, manifest embedded, service worker inline
- 🎨 Design system MRT Jakarta (blue/green) dengan Plus Jakarta Sans
- 🌐 Bahasa Indonesia full
- 🔒 Row Level Security: anon untuk submit/read, authenticated untuk admin
- 📍 3 lokasi pre-seeded: Wisma Nusantara, Transport Hub, Depo Lebak Bulus
- 5️⃣ status flow: Belum Dikonfirmasi → Sedang Disiapkan → Tersedia → Selesai (atau Ditolak)

---

## 🛠️ Tech Stack

- **Frontend** — Vanilla HTML/CSS/JS (single file, ~2100 lines)
- **CSS** — Custom design tokens (CSS variables), no framework
- **Charts** — Chart.js v4 via CDN
- **Backend** — Supabase (PostgreSQL + Auth + RLS + RPC)
- **Auth** — Supabase Auth (email/password)
- **PWA** — Manifest data URL + Service Worker via Blob URL
- **Fonts** — Plus Jakarta Sans + Material Symbols Rounded (Google Fonts)
- **SDK** — `@supabase/supabase-js` v2 via CDN

---

## 🔧 Troubleshooting

**Login admin gagal "Invalid login credentials"**
→ Pastikan user sudah dibuat di Supabase Authentication dan **Auto Confirm User** dicentang. Kalau belum, edit user di dashboard Supabase dan klik "Send confirmation email" atau set `email_confirmed_at` manual.

**Form submit gagal "permission denied"**
→ Cek RLS policies sudah aktif. Run ulang bagian `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` dan `CREATE POLICY ...` di `database.sql`.

**Statistik tidak muncul / loading terus**
→ Cek `SUPABASE_URL` dan `SUPABASE_ANON` di `index.html` sudah benar. Buka DevTools Console untuk lihat error spesifik.

**Stok tidak berkurang saat status Selesai**
→ Run `migration_stock_sync.sql` di Supabase SQL Editor. Versi lama (sebelum v1.1.0) tidak punya logika auto-sync.

**Kode permintaan duplikat / collision**
→ Tidak mungkin terjadi — RPC `create_meterai_request` pakai table-level lock. Kalau muncul error, cek apakah trigger atau function di-modifikasi manual.

**PWA tidak bisa diinstal**
→ Pastikan akses via HTTPS (atau localhost). PWA tidak bekerja di HTTP non-localhost.

---

## 📜 Lisensi

Internal use — General Affairs Department.

---

## 👥 Kontak

Untuk laporan bug atau permintaan fitur, hubungi tim General Affairs.

© General Affairs Department — 2026
