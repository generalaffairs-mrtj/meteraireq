-- =============================================================================
-- MIGRATION: Sinkronisasi otomatis stok saat status = 'Selesai'
-- =============================================================================
-- Jalankan ini di Supabase SQL Editor JIKA database lama Anda sudah berisi data
-- dan tidak ingin di-reset.
--
-- Yang dilakukan:
--   1. Tambah kolom `stock_deducted` ke tabel requests
--   2. Tandai semua data 'Selesai' yang sudah ada sebagai "sudah dikurangi"
--      agar tidak terjadi pengurangan ganda saat fitur ini diaktifkan
--   3. Replace function update_request_status dengan versi baru yang
--      otomatis mengurangi stok saat Selesai & rollback saat dibatalkan
-- =============================================================================

-- 1. Tambah kolom flag (idempotent)
ALTER TABLE public.requests
    ADD COLUMN IF NOT EXISTS stock_deducted BOOLEAN NOT NULL DEFAULT FALSE;

-- 2. Backfill: anggap data 'Selesai' yang sudah ada SUDAH dikurangi dari stok
--    (ini mencegah double-deduction kalau admin nanti mengubah status mereka)
UPDATE public.requests
SET stock_deducted = TRUE
WHERE status = 'Selesai' AND stock_deducted = FALSE;

-- 3. Replace function
DROP FUNCTION IF EXISTS public.update_request_status(text,text,text) CASCADE;

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

    SELECT * INTO v_row
    FROM public.requests
    WHERE kode_permintaan = p_kode
    FOR UPDATE;

    IF v_row.id IS NULL THEN
        RAISE EXCEPTION 'Kode permintaan % tidak ditemukan', p_kode;
    END IF;

    v_old_status   := v_row.status;
    v_old_deducted := v_row.stock_deducted;

    -- CASE A: berubah MENJADI 'Selesai' & belum pernah dikurangi → kurangi stok
    IF p_status = 'Selesai' AND NOT v_old_deducted THEN
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

    -- CASE B: berubah DARI 'Selesai' ke status lain → rollback stok
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

    UPDATE public.requests
    SET status         = p_status,
        keterangan     = trim(p_keterangan),
        stock_deducted = v_row.stock_deducted
    WHERE kode_permintaan = p_kode
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_request_status(TEXT,TEXT,TEXT) TO authenticated;

-- Selesai. Verifikasi: ubah salah satu permintaan ke 'Selesai' lalu cek tabel stock.
