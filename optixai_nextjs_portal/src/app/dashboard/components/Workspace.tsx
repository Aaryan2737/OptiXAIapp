import { ScreeningRecord } from '@/types/screening';
import ActionPanel from './ActionPanel';

interface WorkspaceProps {
  screening: ScreeningRecord | null;
}

export default function Workspace({ screening }: WorkspaceProps) {
  if (!screening) {
    return (
      <div className="flex-1 flex flex-col items-center justify-center p-8 bg-slate-50">
        <div className="w-24 h-24 bg-white rounded-full flex items-center justify-center shadow-sm mb-4">
          <span className="text-slate-300 text-4xl">?</span>
        </div>
        <h2 className="text-xl font-semibold text-slate-700">No Patient Selected</h2>
        <p className="text-slate-500 mt-2 text-center max-w-md">
          Select a patient from the triage queue on the left to view their detailed screening records, fundus images, and AI confidence scores.
        </p>
      </div>
    );
  }

  const patient = screening.patients;
  const confidencePercent = (screening.ai_confidence_score * 100).toFixed(1);

  // We construct the public URL from the storage bucket.
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || '';
  const getImageUrl = (path: string) => {
    if (!path) return '';
    return `${supabaseUrl}/storage/v1/object/public/${path}`;
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 lg:p-8 bg-slate-50 custom-scrollbar">
      {/* Header */}
      <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-[0_4px_20px_-4px_rgba(0,0,0,0.05)] mb-6 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900">{patient?.name || 'Unknown Patient'}</h1>
          <p className="text-slate-500 mt-1">
            {patient?.gender || 'N/A'} • {patient?.age ? `${patient.age} yrs` : 'N/A'} • Screened on {new Date(screening.screened_at).toLocaleDateString()}
          </p>
        </div>
        <div className="bg-teal-50 px-4 py-3 rounded-2xl border border-teal-100 flex flex-col items-end">
          <span className="text-xs text-teal-600 font-semibold uppercase tracking-wider mb-1">AI Confidence</span>
          <span className="text-2xl font-bold text-teal-700">{confidencePercent}%</span>
        </div>
      </div>

      {/* Image Matrix */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        
        {/* Left Eye */}
        <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-[0_4px_20px_-4px_rgba(0,0,0,0.05)]">
          <div className="flex justify-between items-center mb-4">
            <h3 className="text-lg font-semibold text-slate-900">Left Eye</h3>
            <span className="bg-slate-100 text-slate-600 px-3 py-1 rounded-full text-xs font-bold">
              Grade {screening.ai_triage_grade_left}
            </span>
          </div>
          <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <div>
              <p className="text-xs text-slate-500 font-semibold mb-2 uppercase tracking-wider">Original Capture</p>
              <div className="aspect-square rounded-2xl bg-slate-100 overflow-hidden relative border border-slate-200">
                {screening.left_eye_image_path ? (
                  <img src={getImageUrl(screening.left_eye_image_path)} alt="Left Eye" className="w-full h-full object-cover" />
                ) : (
                  <div className="w-full h-full flex items-center justify-center text-slate-400">No Image</div>
                )}
              </div>
            </div>
            <div>
              <p className="text-xs text-slate-500 font-semibold mb-2 uppercase tracking-wider">Grad-CAM++ Analysis</p>
              <div className="aspect-square rounded-2xl bg-slate-100 overflow-hidden relative border border-slate-200 flex items-center justify-center">
                {/* Skeleton loader for Grad-CAM++ styled for light mode */}
                <div className="animate-pulse flex flex-col items-center">
                  <div className="w-10 h-10 border-4 border-slate-200 border-t-teal-500 rounded-full animate-spin mb-3"></div>
                  <span className="text-slate-400 text-sm font-medium">Processing...</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Right Eye */}
        <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-[0_4px_20px_-4px_rgba(0,0,0,0.05)]">
          <div className="flex justify-between items-center mb-4">
            <h3 className="text-lg font-semibold text-slate-900">Right Eye</h3>
            <span className="bg-slate-100 text-slate-600 px-3 py-1 rounded-full text-xs font-bold">
              Grade {screening.ai_triage_grade_right}
            </span>
          </div>
          <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <div>
              <p className="text-xs text-slate-500 font-semibold mb-2 uppercase tracking-wider">Original Capture</p>
              <div className="aspect-square rounded-2xl bg-slate-100 overflow-hidden relative border border-slate-200">
                {screening.right_eye_image_path ? (
                  <img src={getImageUrl(screening.right_eye_image_path)} alt="Right Eye" className="w-full h-full object-cover" />
                ) : (
                  <div className="w-full h-full flex items-center justify-center text-slate-400">No Image</div>
                )}
              </div>
            </div>
            <div>
              <p className="text-xs text-slate-500 font-semibold mb-2 uppercase tracking-wider">Grad-CAM++ Analysis</p>
              <div className="aspect-square rounded-2xl bg-slate-100 overflow-hidden relative border border-slate-200 flex items-center justify-center">
                <div className="animate-pulse flex flex-col items-center">
                  <div className="w-10 h-10 border-4 border-slate-200 border-t-teal-500 rounded-full animate-spin mb-3"></div>
                  <span className="text-slate-400 text-sm font-medium">Processing...</span>
                </div>
              </div>
            </div>
          </div>
        </div>

      </div>

      <ActionPanel screening={screening} />
    </div>
  );
}
