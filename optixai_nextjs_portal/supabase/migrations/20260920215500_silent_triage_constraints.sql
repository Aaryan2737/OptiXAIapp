-- OptiXAI Architecture Shift: Complete Schema Migration

-- 1. Rename existing columns to match the new Silent Triage contract
ALTER TABLE screenings RENAME COLUMN local_id TO screening_id;
ALTER TABLE screenings RENAME COLUMN left_eye_image_url TO left_eye_image_path;
ALTER TABLE screenings RENAME COLUMN right_eye_image_url TO right_eye_image_path;
ALTER TABLE screenings RENAME COLUMN left_eye_grade TO ai_triage_grade_left;
ALTER TABLE screenings RENAME COLUMN right_eye_grade TO ai_triage_grade_right;
ALTER TABLE screenings RENAME COLUMN is_urgent_refer TO is_urgent_referral;

-- 2. Add the new columns required by the contract
ALTER TABLE screenings ADD COLUMN IF NOT EXISTS asha_worker_id UUID REFERENCES public.asha_workers(id);
ALTER TABLE screenings ADD COLUMN IF NOT EXISTS ai_confidence_score REAL DEFAULT 0.0;
ALTER TABLE screenings ADD COLUMN IF NOT EXISTS clinical_status VARCHAR(50) DEFAULT 'pending_doctor_review';

-- 3. Enforce clinical_status constraint
ALTER TABLE screenings
  ADD CONSTRAINT chk_clinical_status
  CHECK (clinical_status IN ('pending_doctor_review', 'referred', 'cleared'));
