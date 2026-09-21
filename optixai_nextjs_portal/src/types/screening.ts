export interface ScreeningRecord {
  id: string;
  patient_id: string;
  asha_worker_id: string;
  left_eye_image_path: string;
  right_eye_image_path: string;
  ai_triage_grade_left: 0 | 1 | 2 | 3 | 4;
  ai_triage_grade_right: 0 | 1 | 2 | 3 | 4;
  ai_confidence_score: number;
  is_urgent_referral: boolean;
  clinical_status: 'pending_doctor_review' | 'referred' | 'cleared';
  screened_at: string;
  patients: {
    name: string;
    age: number;
    gender: string;
  };
}
