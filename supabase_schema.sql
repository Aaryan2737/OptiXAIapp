-- OptiXAI Phase 1: Complete Supabase Schema & RLS

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Identity Tables (Linked to Supabase Auth)
CREATE TABLE public.asha_workers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    auth_uid UUID REFERENCES auth.users(id) NOT NULL UNIQUE,
    full_name VARCHAR(255) NOT NULL,
    phone VARCHAR(20) NOT NULL UNIQUE,
    assigned_district VARCHAR(100)
);

CREATE TABLE public.ophthalmologists (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    auth_uid UUID REFERENCES auth.users(id) NOT NULL UNIQUE,
    full_name VARCHAR(255) NOT NULL,
    hospital_name VARCHAR(255)
);

-- 2. Core Telemedicine Tables (With Offline Sync Keys)
CREATE TABLE public.patients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_id UUID UNIQUE NOT NULL, -- Crucial for Flutter offline upsert
    asha_worker_id UUID REFERENCES public.asha_workers(id) NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    age INTEGER,
    gender VARCHAR(20),
    contact_number VARCHAR(20),
    sync_status VARCHAR(20) DEFAULT 'synced',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE public.screenings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_id UUID UNIQUE NOT NULL, -- Crucial for Flutter offline upsert
    patient_id UUID REFERENCES public.patients(id) ON DELETE CASCADE,
    left_eye_image_url TEXT,
    right_eye_image_url TEXT,
    left_eye_grade INTEGER CHECK (left_eye_grade >= 0 AND left_eye_grade <= 4),
    right_eye_grade INTEGER CHECK (right_eye_grade >= 0 AND right_eye_grade <= 4),
    is_urgent_refer BOOLEAN NOT NULL,
    thresholds_version VARCHAR(50) NOT NULL, -- Pins the calibration math used
    sync_status VARCHAR(20) DEFAULT 'synced',
    screened_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE public.heatmaps (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    screening_id UUID REFERENCES public.screenings(id) ON DELETE CASCADE,
    heatmap_url TEXT NOT NULL,
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE public.referrals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    screening_id UUID REFERENCES public.screenings(id) ON DELETE CASCADE,
    ophthalmologist_id UUID REFERENCES public.ophthalmologists(id) NOT NULL,
    message_text TEXT NOT NULL,
    dispatch_status VARCHAR(50) DEFAULT 'pending',
    dispatched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Row Level Security (RLS)
ALTER TABLE public.asha_workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ophthalmologists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.screenings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.heatmaps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;

-- ASHA Workers can only see and insert their own patients
CREATE POLICY "ASHA workers manage their own patients" ON public.patients
    FOR ALL USING (asha_worker_id IN (SELECT id FROM asha_workers WHERE auth_uid = auth.uid()));

CREATE POLICY "ASHA workers manage their own screenings" ON public.screenings
    FOR ALL USING (patient_id IN (SELECT id FROM patients WHERE asha_worker_id IN (SELECT id FROM asha_workers WHERE auth_uid = auth.uid())));

-- Ophthalmologists can read all screenings/patients to validate triage
CREATE POLICY "Doctors view all patients" ON public.patients
    FOR SELECT USING (EXISTS (SELECT 1 FROM ophthalmologists WHERE auth_uid = auth.uid()));

CREATE POLICY "Doctors view all screenings" ON public.screenings
    FOR SELECT USING (EXISTS (SELECT 1 FROM ophthalmologists WHERE auth_uid = auth.uid()));

-- Profile Access (Users must be able to read their own profile to get their ID)
CREATE POLICY "ASHA workers can view their own profile" ON public.asha_workers
    FOR SELECT USING (auth_uid = auth.uid());

CREATE POLICY "Ophthalmologists can view their own profile" ON public.ophthalmologists
    FOR SELECT USING (auth_uid = auth.uid());

-- Heatmaps Access
CREATE POLICY "Doctors view all heatmaps" ON public.heatmaps
    FOR SELECT USING (EXISTS (SELECT 1 FROM ophthalmologists WHERE auth_uid = auth.uid()));

CREATE POLICY "ASHA workers view heatmaps for their patients" ON public.heatmaps
    FOR SELECT USING (screening_id IN (
        SELECT id FROM screenings WHERE patient_id IN (
            SELECT id FROM patients WHERE asha_worker_id IN (SELECT id FROM asha_workers WHERE auth_uid = auth.uid())
        )
    ));

-- Referrals Access
CREATE POLICY "Doctors manage referrals" ON public.referrals
    FOR ALL USING (ophthalmologist_id IN (SELECT id FROM ophthalmologists WHERE auth_uid = auth.uid()));

CREATE POLICY "ASHA workers view referrals for their patients" ON public.referrals
    FOR SELECT USING (screening_id IN (
        SELECT id FROM screenings WHERE patient_id IN (
            SELECT id FROM patients WHERE asha_worker_id IN (SELECT id FROM asha_workers WHERE auth_uid = auth.uid())
        )
    ));

-- Service Role (FastAPI Backend) automatically bypasses RLS for heatmap/webhook insertions.

-- 4. Storage Buckets (Run these commands or create manually in UI)
INSERT INTO storage.buckets (id, name, public) VALUES ('fundus-images', 'fundus-images', false) ON CONFLICT DO NOTHING;
INSERT INTO storage.buckets (id, name, public) VALUES ('heatmaps', 'heatmaps', false) ON CONFLICT DO NOTHING;

-- Storage RLS: Allow authenticated users to upload to fundus-images
CREATE POLICY "ASHA workers can upload fundus images" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'fundus-images' AND auth.role() = 'authenticated');

-- Storage RLS: Allow Ophthalmologists to view both buckets
CREATE POLICY "Doctors can view all images" ON storage.objects
    FOR SELECT USING (auth.role() = 'authenticated' AND (bucket_id = 'fundus-images' OR bucket_id = 'heatmaps'));