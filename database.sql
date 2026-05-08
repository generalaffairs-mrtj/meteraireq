-- =============================================================================
-- DATABASE SCHEMA: Platform Permintaan Meterai
-- General Affairs Department
-- Target: Supabase (PostgreSQL 15+)
-- =============================================================================
-- CARA INSTALL:
-- 1. Buka Supabase Dashboard -> SQL Editor
-- 2. Copy-paste seluruh file ini lalu klik "Run"
-- 3. Buat akun admin di Authentication -> Users -> Add user (email + password)
-- 4. Salin Project URL dan anon public key ke index.html (cari "SUPABASE CONFIG")
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. CLEANUP (jika ingin reset, jalankan bagian ini)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_monthly_stats CASCADE;
DROP VIEW IF EXISTS public.v_dashboard_summary CASCADE;
DROP FUNCTION IF EXISTS public.create_meterai_request(text,text,text,text,integer,text) CASCADE;
DROP FUNCTION IF EXISTS public.update_request_status(text,text,text) CASCADE;
DROP FUNCTION IF EXISTS public.adjust_stock(text,integer,text,text) CASCADE;
DROP FUNCTION IF EXISTS public.set_stock(text,integer,text) CASCADE;
DROP FUNCTION IF EXISTS public.log_activity(text,text,text,jsonb) CASCADE;
DROP FUNCTION IF EXISTS public.set_updated_at() CASCADE;
DROP TABLE IF EXISTS public.activity_log CASCADE;
DROP TABLE IF EXISTS public.stock_log CASCADE;
DROP TABLE IF EXISTS public.requests CASCADE;
DROP TABLE IF EXISTS public.stock CASCADE;

-- -----------------------------------------------------------------------------
-- 1. TABEL: requests (permintaan meterai)
-- -----------------------------------------------------------------------------
CREATE TABLE public.requests (
    id                BIGSERIAL PRIMARY KEY,
    kode_permintaan   VARCHAR(30)  UNIQUE NOT NULL,
    nama_pemohon      VARCHAR(150) NOT NULL,
    departemen        VARCHAR(150) NOT NULL,
    divisi            VARCHAR(150) NOT NULL,
    lokasi_kerja      VARCHAR(100) NOT NULL,
    jumlah_meterai    INTEGER      NOT NULL CHECK (jumlah_meterai > 0 AND jumlah_meterai <= 9999),
    tujuan_penggunaan TEXT         NOT NULL,
    status            VARCHAR(50)  NOT NULL DEFAULT 'Belum Dikonfirmasi',
    keterangan        TEXT,
    stock_deducted    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_status   CHECK (status IN ('Belum Dikonfirmasi','Sedang Disiapkan','Tersedia','Ditolak','Selesai')),
    CONSTRAINT chk_lokasi   CHECK (lokasi_kerja IN ('Wisma Nusantara','Transport Hub','Depo Lebak Bulus'))
);

CREATE INDEX idx_requests_kode       ON public.requests (kode_permintaan);
CREATE INDEX idx_requests_status     ON public.requests (status);
CREATE INDEX idx_requests_created    ON public.requests (created_at DESC);
CREATE INDEX idx_requests_departemen ON public.requests (departemen);
CREATE INDEX idx_requests_lokasi     ON public.requests (lokasi_kerja);

-- -----------------------------------------------------------------------------
-- 2. TABEL: stock (stok meterai per area)
-- -----------------------------------------------------------------------------
CREATE TABLE public.stock (
    id          BIGSERIAL PRIMARY KEY,
    area        VARCHAR(100) UNIQUE NOT NULL,
    jumlah      INTEGER NOT NULL DEFAULT 0 CHECK (jumlah >= 0),
    minimum     INTEGER NOT NULL DEFAULT 50  CHECK (minimum >= 0),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_area CHECK (area IN ('Wisma Nusantara','Transport Hub','Depo Lebak Bulus'))
);

INSERT INTO public.stock (area, jumlah, minimum) VALUES
    ('Wisma Nusantara',   500, 100),
    ('Transport Hub',     350, 75),
    ('Depo Lebak Bulus',  250, 50);

-- -----------------------------------------------------------------------------
-- 3. TABEL: stock_log (audit log perubahan stok)
-- -----------------------------------------------------------------------------
CREATE TABLE public.stock_log (
    id            BIGSERIAL PRIMARY KEY,
    area          VARCHAR(100) NOT NULL,
    perubahan     INTEGER NOT NULL,
    stok_sebelum  INTEGER NOT NULL,
    stok_sesudah  INTEGER NOT NULL,
    tipe          VARCHAR(20) NOT NULL CHECK (tipe IN ('TAMBAH','KURANG','SET','EDIT')),
    keterangan    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stock_log_area    ON public.stock_log (area);
CREATE INDEX idx_stock_log_created ON public.stock_log (created_at DESC);

-- -----------------------------------------------------------------------------
-- 3b. TABEL: activity_log (audit log seluruh aktivitas admin)
-- -----------------------------------------------------------------------------
CREATE TABLE public.activity_log (
    id           BIGSERIAL PRIMARY KEY,
    user_email   VARCHAR(255),
    user_id      UUID,
    action_type  VARCHAR(50)  NOT NULL,
    target       VARCHAR(255),
    description  TEXT         NOT NULL,
    metadata     JSONB,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_activity_action CHECK (action_type IN (
        'LOGIN','LOGOUT','LOGIN_FAILED',
        'UPDATE_STATUS',
        'STOCK_TAMBAH','STOCK_KURANG','STOCK_EDIT',
        'OTHER'
    ))
);

CREATE INDEX idx_activity_created ON public.activity_log (created_at DESC);
CREATE INDEX idx_activity_user    ON public.activity_log (user_email);
CREATE INDEX idx_activity_action  ON public.activity_log (action_type);

-- -----------------------------------------------------------------------------
-- 4. TRIGGER: auto-update updated_at
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_requests_updated
    BEFORE UPDATE ON public.requests
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_stock_updated
    BEFORE UPDATE ON public.stock
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- -----------------------------------------------------------------------------
-- 5. FUNCTION: create_meterai_request
--    Generate kode MET-DDMMYYYY+NNN secara atomic & insert request
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_meterai_request(
    p_nama_pemohon      TEXT,
    p_departemen        TEXT,
    p_divisi            TEXT,
    p_lokasi_kerja      TEXT,
    p_jumlah_meterai    INTEGER,
    p_tujuan_penggunaan TEXT
)
RETURNS TABLE(kode VARCHAR, request_id BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_today_str TEXT;
    v_counter   INTEGER;
    v_new_code  VARCHAR(30);
    v_new_id    BIGINT;
BEGIN
    -- Validasi input dasar
    IF p_nama_pemohon IS NULL OR length(trim(p_nama_pemohon)) = 0 THEN
        RAISE EXCEPTION 'Nama pemohon wajib diisi';
    END IF;
    IF p_jumlah_meterai IS NULL OR p_jumlah_meterai <= 0 THEN
        RAISE EXCEPTION 'Jumlah meterai harus lebih dari 0';
    END IF;

    -- Format DDMMYYYY berdasarkan zona Asia/Jakarta
    v_today_str := TO_CHAR((NOW() AT TIME ZONE 'Asia/Jakarta')::date, 'DDMMYYYY');

    -- Lock untuk hindari race-condition pada counter
    LOCK TABLE public.requests IN SHARE ROW EXCLUSIVE MODE;

    -- Hitung counter berikutnya untuk hari ini
    SELECT COALESCE(MAX(
        CAST(SUBSTRING(kode_permintaan FROM 13 FOR 3) AS INTEGER)
    ), 0) + 1
    INTO v_counter
    FROM public.requests
    WHERE kode_permintaan LIKE ('MET-' || v_today_str || '%');

    v_new_code := 'MET-' || v_today_str || LPAD(v_counter::TEXT, 3, '0');

    INSERT INTO public.requests (
        kode_permintaan, nama_pemohon, departemen, divisi,
        lokasi_kerja, jumlah_meterai, tujuan_penggunaan
    ) VALUES (
        v_new_code,
        trim(p_nama_pemohon),
        trim(p_departemen),
        trim(p_divisi),
        p_lokasi_kerja,
        p_jumlah_meterai,
        trim(p_tujuan_penggunaan)
    ) RETURNING id INTO v_new_id;

    RETURN QUERY SELECT v_new_code, v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_meterai_request(TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. FUNCTION: update_request_status (admin only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_request_status(
    p_kode       TEXT,
    p_status     TEXT,
    p_keterangan TEXT
)
RETURNS public.requests
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_row          public.requests;
    v_old_status   TEXT;
    v_old_deducted BOOLEAN;
    v_stock_now    INTEGER;
BEGIN
    IF p_keterangan IS NULL OR length(trim(p_keterangan)) = 0 THEN
        RAISE EXCEPTION 'Keterangan wajib diisi saat update status';
    END IF;

    IF p_status NOT IN ('Belum Dikonfirmasi','Sedang Disiapkan','Tersedia','Ditolak','Selesai') THEN
        RAISE EXCEPTION 'Status tidak valid: %', p_status;
    END IF;

    -- Lock the request row to prevent concurrent updates
    SELECT * INTO v_row
    FROM public.requests
    WHERE kode_permintaan = p_kode
    FOR UPDATE;

    IF v_row.id IS NULL THEN
        RAISE EXCEPTION 'Kode permintaan % tidak ditemukan', p_kode;
    END IF;

    v_old_status   := v_row.status;
    v_old_deducted := v_row.stock_deducted;

    -- ---- CASE A: status berubah MENJADI 'Selesai' (dan belum pernah dikurangi) ----
    IF p_status = 'Selesai' AND NOT v_old_deducted THEN
        -- Lock stok di lokasi terkait
        SELECT jumlah INTO v_stock_now
        FROM public.stock
        WHERE area = v_row.lokasi_kerja
        FOR UPDATE;

        IF v_stock_now IS NULL THEN
            RAISE EXCEPTION 'Stok untuk lokasi % tidak ditemukan', v_row.lokasi_kerja;
        END IF;

        IF v_stock_now < v_row.jumlah_meterai THEN
            RAISE EXCEPTION 'Stok tidak cukup di %. Tersedia: %, dibutuhkan: %',
                v_row.lokasi_kerja, v_stock_now, v_row.jumlah_meterai;
        END IF;

        UPDATE public.stock
        SET jumlah = jumlah - v_row.jumlah_meterai
        WHERE area = v_row.lokasi_kerja;

        INSERT INTO public.stock_log (area, perubahan, stok_sebelum, stok_sesudah, tipe, keterangan)
        VALUES (
            v_row.lokasi_kerja,
            -v_row.jumlah_meterai,
            v_stock_now,
            v_stock_now - v_row.jumlah_meterai,
            'KURANG',
            'Auto: permintaan ' || v_row.kode_permintaan || ' (' || v_row.nama_pemohon || ') diselesaikan'
        );

        v_row.stock_deducted := TRUE;
    END IF;

    -- ---- CASE B: status berubah DARI 'Selesai' ke status lain (rollback stok) ----
    IF v_old_status = 'Selesai' AND p_status <> 'Selesai' AND v_old_deducted THEN
        SELECT jumlah INTO v_stock_now
        FROM public.stock
        WHERE area = v_row.lokasi_kerja
        FOR UPDATE;

        UPDATE public.stock
        SET jumlah = jumlah + v_row.jumlah_meterai
        WHERE area = v_row.lokasi_kerja;

        INSERT INTO public.stock_log (area, perubahan, stok_sebelum, stok_sesudah, tipe, keterangan)
        VALUES (
            v_row.lokasi_kerja,
            v_row.jumlah_meterai,
            v_stock_now,
            v_stock_now + v_row.jumlah_meterai,
            'TAMBAH',
            'Rollback: permintaan ' || v_row.kode_permintaan || ' status diubah dari Selesai ke ' || p_status
        );

        v_row.stock_deducted := FALSE;
    END IF;

    -- Update status, keterangan, dan flag stock_deducted dalam satu UPDATE
    UPDATE public.requests
    SET status         = p_status,
        keterangan     = trim(p_keterangan),
        stock_deducted = v_row.stock_deducted
    WHERE kode_permintaan = p_kode
    RETURNING * INTO v_row;

    -- Audit log aktivitas admin
    INSERT INTO public.activity_log (user_email, user_id, action_type, target, description, metadata)
    VALUES (
        COALESCE(auth.jwt() ->> 'email', 'unknown'),
        auth.uid(),
        'UPDATE_STATUS',
        p_kode,
        'Update status ' || p_kode || ' (' || v_row.nama_pemohon || '): ' || v_old_status || ' → ' || p_status,
        jsonb_build_object(
            'kode_permintaan', p_kode,
            'pemohon',         v_row.nama_pemohon,
            'departemen',      v_row.departemen,
            'lokasi_kerja',    v_row.lokasi_kerja,
            'jumlah_meterai',  v_row.jumlah_meterai,
            'old_status',      v_old_status,
            'new_status',      p_status,
            'keterangan',      trim(p_keterangan),
            'stock_changed',   (v_row.stock_deducted IS DISTINCT FROM v_old_deducted)
        )
    );

    RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_request_status(TEXT,TEXT,TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. FUNCTION: adjust_stock (TAMBAH/KURANG) & set_stock (SET/EDIT)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjust_stock(
    p_area       TEXT,
    p_perubahan  INTEGER,   -- positive = TAMBAH, negative = KURANG
    p_tipe       TEXT,      -- 'TAMBAH' atau 'KURANG'
    p_keterangan TEXT
)
RETURNS public.stock
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_before INTEGER;
    v_after  INTEGER;
    v_row    public.stock;
BEGIN
    SELECT jumlah INTO v_before FROM public.stock WHERE area = p_area FOR UPDATE;
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'Area % tidak ditemukan', p_area;
    END IF;

    v_after := v_before + p_perubahan;
    IF v_after < 0 THEN
        RAISE EXCEPTION 'Stok tidak boleh negatif (sekarang %, perubahan %)', v_before, p_perubahan;
    END IF;

    UPDATE public.stock SET jumlah = v_after WHERE area = p_area RETURNING * INTO v_row;

    INSERT INTO public.stock_log (area, perubahan, stok_sebelum, stok_sesudah, tipe, keterangan)
    VALUES (p_area, p_perubahan, v_before, v_after, p_tipe, p_keterangan);

    INSERT INTO public.activity_log (user_email, user_id, action_type, target, description, metadata)
    VALUES (
        COALESCE(auth.jwt() ->> 'email', 'unknown'),
        auth.uid(),
        CASE WHEN p_tipe = 'TAMBAH' THEN 'STOCK_TAMBAH' ELSE 'STOCK_KURANG' END,
        p_area,
        p_tipe || ' stok ' || p_area || ': ' || v_before || ' → ' || v_after || ' (' ||
            CASE WHEN p_perubahan >= 0 THEN '+' ELSE '' END || p_perubahan || ')',
        jsonb_build_object(
            'area', p_area, 'tipe', p_tipe,
            'perubahan', p_perubahan,
            'stok_sebelum', v_before, 'stok_sesudah', v_after,
            'keterangan', p_keterangan
        )
    );

    RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_stock(
    p_area       TEXT,
    p_jumlah     INTEGER,
    p_keterangan TEXT
)
RETURNS public.stock
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_before INTEGER;
    v_row    public.stock;
BEGIN
    IF p_jumlah < 0 THEN
        RAISE EXCEPTION 'Stok tidak boleh negatif';
    END IF;

    SELECT jumlah INTO v_before FROM public.stock WHERE area = p_area FOR UPDATE;
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'Area % tidak ditemukan', p_area;
    END IF;

    UPDATE public.stock SET jumlah = p_jumlah WHERE area = p_area RETURNING * INTO v_row;

    INSERT INTO public.stock_log (area, perubahan, stok_sebelum, stok_sesudah, tipe, keterangan)
    VALUES (p_area, p_jumlah - v_before, v_before, p_jumlah, 'EDIT', p_keterangan);

    INSERT INTO public.activity_log (user_email, user_id, action_type, target, description, metadata)
    VALUES (
        COALESCE(auth.jwt() ->> 'email', 'unknown'),
        auth.uid(),
        'STOCK_EDIT',
        p_area,
        'EDIT stok ' || p_area || ': ' || v_before || ' → ' || p_jumlah,
        jsonb_build_object(
            'area', p_area, 'tipe', 'EDIT',
            'stok_sebelum', v_before, 'stok_sesudah', p_jumlah,
            'keterangan', p_keterangan
        )
    );

    RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_stock(TEXT,INTEGER,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_stock(TEXT,INTEGER,TEXT)        TO authenticated;

-- -----------------------------------------------------------------------------
-- 7b. FUNCTION: log_activity (dipanggil frontend untuk LOGIN/LOGOUT)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_activity(
    p_action_type TEXT,
    p_target      TEXT,
    p_description TEXT,
    p_metadata    JSONB DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_action_type NOT IN ('LOGIN','LOGOUT','LOGIN_FAILED','OTHER') THEN
        RAISE EXCEPTION 'action_type % tidak diizinkan dari client', p_action_type;
    END IF;

    INSERT INTO public.activity_log (user_email, user_id, action_type, target, description, metadata)
    VALUES (
        COALESCE(auth.jwt() ->> 'email', p_target, 'unknown'),
        auth.uid(),
        p_action_type,
        p_target,
        p_description,
        p_metadata
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_activity(TEXT,TEXT,TEXT,JSONB) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. VIEWS: statistik untuk landing page & dashboard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_dashboard_summary AS
SELECT
    (SELECT COALESCE(SUM(jumlah_meterai),0) FROM public.requests WHERE status = 'Selesai')          AS total_meterai_keluar,
    (SELECT COUNT(*) FROM public.requests)                                                          AS total_permintaan,
    (SELECT COUNT(*) FROM public.requests WHERE status = 'Belum Dikonfirmasi')                      AS total_pending,
    (SELECT COUNT(*) FROM public.requests
        WHERE date_trunc('month', created_at AT TIME ZONE 'Asia/Jakarta')
            = date_trunc('month', NOW()    AT TIME ZONE 'Asia/Jakarta'))                            AS permintaan_bulan_ini,
    (SELECT COALESCE(SUM(jumlah),0) FROM public.stock)                                              AS total_stock;

CREATE OR REPLACE VIEW public.v_monthly_stats AS
SELECT
    to_char(date_trunc('month', created_at AT TIME ZONE 'Asia/Jakarta'), 'YYYY-MM') AS bulan,
    departemen,
    COUNT(*)                            AS jumlah_permintaan,
    COALESCE(SUM(jumlah_meterai), 0)    AS total_meterai
FROM public.requests
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;

GRANT SELECT ON public.v_dashboard_summary TO anon, authenticated;
GRANT SELECT ON public.v_monthly_stats     TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- -----------------------------------------------------------------------------
ALTER TABLE public.requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;

-- requests: anon dapat INSERT (via RPC) & SELECT (untuk tracking & stats); authenticated bisa semua
CREATE POLICY "anon_select_requests"   ON public.requests FOR SELECT TO anon          USING (true);
CREATE POLICY "anon_insert_requests"   ON public.requests FOR INSERT TO anon          WITH CHECK (true);
CREATE POLICY "auth_select_requests"   ON public.requests FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_insert_requests"   ON public.requests FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "auth_update_requests"   ON public.requests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "auth_delete_requests"   ON public.requests FOR DELETE TO authenticated USING (true);

-- stock: anon SELECT only; authenticated full
CREATE POLICY "anon_select_stock"      ON public.stock    FOR SELECT TO anon          USING (true);
CREATE POLICY "auth_all_stock"         ON public.stock    FOR ALL    TO authenticated USING (true) WITH CHECK (true);

-- stock_log: anon SELECT (read-only audit), authenticated full
CREATE POLICY "anon_select_stock_log"  ON public.stock_log FOR SELECT TO anon          USING (true);
CREATE POLICY "auth_all_stock_log"     ON public.stock_log FOR ALL    TO authenticated USING (true) WITH CHECK (true);

-- activity_log: HANYA authenticated (privacy — anon tidak boleh lihat siapa yang login kapan)
CREATE POLICY "auth_select_activity"   ON public.activity_log FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_insert_activity"   ON public.activity_log FOR INSERT TO authenticated WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 10. SAMPLE DATA (opsional - hapus blok ini bila tidak diperlukan)
-- -----------------------------------------------------------------------------
INSERT INTO public.requests (kode_permintaan, nama_pemohon, departemen, divisi, lokasi_kerja, jumlah_meterai, tujuan_penggunaan, status, keterangan, created_at) VALUES
('MET-01042026001', 'Ahmad Saputra',  'Finance',          'Accounting',         'Wisma Nusantara',   10, 'Penandatanganan kontrak vendor IT',         'Selesai',           'Sudah diambil di GA pada 02/04', NOW() - INTERVAL '36 days'),
('MET-05042026001', 'Bunga Lestari',  'Legal',            'Corporate Legal',    'Wisma Nusantara',   25, 'Perjanjian kerjasama strategis',            'Selesai',           'Selesai diserahkan',              NOW() - INTERVAL '32 days'),
('MET-12042026001', 'Citra Dewi',     'Operations',       'Train Operations',   'Depo Lebak Bulus',  15, 'MoU pelatihan eksternal',                   'Selesai',           'Diambil tim Ops',                 NOW() - INTERVAL '25 days'),
('MET-20042026001', 'Dimas Pratama',  'Procurement',      'Vendor Management',  'Transport Hub',     30, 'Kontrak pengadaan suku cadang',             'Selesai',           'Telah selesai',                   NOW() - INTERVAL '17 days'),
('MET-25042026001', 'Eka Mahendra',   'HR',               'Talent Acquisition', 'Wisma Nusantara',    8, 'Surat perjanjian karyawan baru',            'Selesai',           'Diserahkan ke HR',                NOW() - INTERVAL '12 days'),
('MET-30042026001', 'Fajar Nugroho',  'Finance',          'Tax & Treasury',     'Wisma Nusantara',   12, 'Dokumen pajak triwulan',                    'Selesai',           'Diserahkan ke Finance',           NOW() - INTERVAL '7 days'),
('MET-02052026001', 'Gita Permata',   'Engineering',      'Civil & Structure',  'Depo Lebak Bulus',  20, 'Kontrak pekerjaan sipil',                   'Selesai',           'Diserahkan ke proyek',            NOW() - INTERVAL '5 days'),
('MET-04052026001', 'Hadi Wijaya',    'Operations',       'Station Operations', 'Transport Hub',     18, 'Surat perjanjian sewa kios',                'Sedang Disiapkan',  'Sedang diverifikasi GA',          NOW() - INTERVAL '3 days'),
('MET-06052026001', 'Indah Sari',     'Marketing',        'Brand & Comm',       'Wisma Nusantara',    6, 'Surat kerjasama media partner',             'Tersedia',          'Silakan ambil di GA Wisma Nusantara', NOW() - INTERVAL '1 day'),
('MET-07052026001', 'Joko Widodo',    'IT',               'Infrastructure',     'Wisma Nusantara',   15, 'Kontrak lisensi software',                  'Belum Dikonfirmasi', NULL,                              NOW() - INTERVAL '4 hours'),
('MET-07052026002', 'Kartika Putri',  'Legal',            'Litigation',         'Wisma Nusantara',   10, 'Berkas perkara pengadilan',                 'Belum Dikonfirmasi', NULL,                              NOW() - INTERVAL '2 hours'),
('MET-07052026003', 'Lukman Hakim',   'Procurement',      'Sourcing',           'Transport Hub',     22, 'Kontrak vendor catering',                   'Belum Dikonfirmasi', NULL,                              NOW() - INTERVAL '1 hour'),
('MET-07052026004', 'Maya Anggraini', 'Operations',       'Safety & Security',  'Depo Lebak Bulus',  14, 'Surat perjanjian jasa keamanan',            'Belum Dikonfirmasi', NULL,                              NOW() - INTERVAL '30 minutes'),
('MET-07052026005', 'Nadia Hapsari',  'Finance',          'Budget & Planning',  'Wisma Nusantara',    9, 'Dokumen perjanjian anggaran',               'Ditolak',            'Data tujuan tidak lengkap, mohon ajukan ulang', NOW() - INTERVAL '15 minutes');

INSERT INTO public.stock_log (area, perubahan, stok_sebelum, stok_sesudah, tipe, keterangan, created_at) VALUES
('Wisma Nusantara',   500, 0,    500, 'TAMBAH', 'Stok awal dari vendor',          NOW() - INTERVAL '40 days'),
('Transport Hub',     350, 0,    350, 'TAMBAH', 'Stok awal dari vendor',          NOW() - INTERVAL '40 days'),
('Depo Lebak Bulus',  250, 0,    250, 'TAMBAH', 'Stok awal dari vendor',          NOW() - INTERVAL '40 days');

-- =============================================================================
-- SELESAI. Jangan lupa:
--   1. Authentication -> Users -> Add user (admin@example.com + password)
--   2. Salin Project URL & anon key ke index.html
-- =============================================================================
