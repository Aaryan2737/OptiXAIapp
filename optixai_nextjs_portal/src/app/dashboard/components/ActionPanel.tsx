import { useState } from 'react';
import { ScreeningRecord } from '@/types/screening';
import { CheckCircle, AlertTriangle, Loader2 } from 'lucide-react';
import { createClient } from '@/utils/supabase/client';

interface ActionPanelProps {
  screening: ScreeningRecord;
}

export default function ActionPanel({ screening }: ActionPanelProps) {
  const [isConfirming, setIsConfirming] = useState(false);
  const [isDowngrading, setIsDowngrading] = useState(false);
  const supabase = createClient();

  const handleConfirmUrgent = async () => {
    setIsConfirming(true);
    try {
      const res = await fetch('/api/dispatch-referral', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          screeningId: screening.id,
          patientName: screening.patients?.name || 'Patient',
          grade: Math.max(screening.ai_triage_grade_left, screening.ai_triage_grade_right)
        })
      });
      if (!res.ok) throw new Error('Failed to dispatch referral');
    } catch (e) {
      console.error(e);
      alert('Failed to dispatch referral. See console for details.');
    } finally {
      setIsConfirming(false);
    }
  };

  const handleDowngrade = async () => {
    setIsDowngrading(true);
    try {
      const { error } = await supabase
        .from('screenings')
        .update({ clinical_status: 'cleared' })
        .eq('id', screening.id);
      
      if (error) throw error;
    } catch (e) {
      console.error(e);
      alert('Failed to downgrade screening. See console for details.');
    } finally {
      setIsDowngrading(false);
    }
  };

  return (
    <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-[0_4px_20px_-4px_rgba(0,0,0,0.05)] mt-6">
      <h3 className="text-lg font-semibold text-slate-900 mb-4">Clinical Sign-off</h3>
      
      <div className="flex flex-col sm:flex-row gap-4">
        <button
          onClick={handleConfirmUrgent}
          disabled={isConfirming || isDowngrading}
          className="flex-1 bg-red-50 hover:bg-red-100 text-red-700 border border-red-200 font-semibold py-4 px-6 rounded-2xl flex items-center justify-center gap-2 transition-colors disabled:opacity-50"
        >
          {isConfirming ? <Loader2 className="w-5 h-5 animate-spin" /> : <AlertTriangle className="w-5 h-5" />}
          Confirm Urgent Referral
        </button>

        <button
          onClick={handleDowngrade}
          disabled={isConfirming || isDowngrading}
          className="flex-1 bg-teal-50 hover:bg-teal-100 text-teal-700 border border-teal-200 font-semibold py-4 px-6 rounded-2xl flex items-center justify-center gap-2 transition-colors disabled:opacity-50"
        >
          {isDowngrading ? <Loader2 className="w-5 h-5 animate-spin" /> : <CheckCircle className="w-5 h-5" />}
          Downgrade to Routine
        </button>
      </div>
    </div>
  );
}
