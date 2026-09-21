import { ScreeningRecord } from '@/types/screening';
import { Cloud, CloudOff, AlertCircle } from 'lucide-react';

interface TriageSidebarProps {
  screenings: ScreeningRecord[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  loading: boolean;
}

export default function TriageSidebar({ screenings, selectedId, onSelect, loading }: TriageSidebarProps) {
  if (loading) {
    return (
      <div className="w-full md:w-80 flex-shrink-0 border-r border-slate-100 bg-white p-4 overflow-y-auto">
        <h2 className="text-xl font-semibold text-slate-900 mb-4">Patient Queue</h2>
        <div className="space-y-3">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="animate-pulse bg-slate-100 h-24 rounded-2xl w-full" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="w-full md:w-80 flex-shrink-0 border-r border-slate-100 bg-white p-4 flex flex-col h-[calc(100vh-4rem)]">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xl font-semibold text-slate-900">Patient Queue</h2>
        <span className="bg-teal-50 text-teal-700 text-xs font-bold px-2.5 py-1 rounded-full">
          {screenings.length}
        </span>
      </div>

      <div className="flex-1 overflow-y-auto space-y-3 pr-2 custom-scrollbar">
        {screenings.length === 0 ? (
          <div className="text-center py-10 text-slate-500">
            <Cloud className="w-12 h-12 mx-auto mb-3 text-slate-300" />
            <p>No patients in queue.</p>
          </div>
        ) : (
          screenings.map((screening) => {
            const isSelected = screening.id === selectedId;
            const patient = screening.patients;
            const initial = patient?.name?.charAt(0).toUpperCase() || '?';
            
            return (
              <button
                key={screening.id}
                onClick={() => onSelect(screening.id)}
                className={`w-full text-left p-4 rounded-2xl border transition-all duration-200 ${
                  isSelected 
                    ? 'border-teal-500 bg-teal-50/30 shadow-[0_4px_20px_-4px_rgba(20,184,166,0.15)]' 
                    : 'border-slate-100 bg-white hover:border-slate-200 hover:shadow-sm'
                }`}
              >
                <div className="flex items-center gap-3">
                  <div className="w-12 h-12 rounded-full bg-teal-50 flex items-center justify-center flex-shrink-0">
                    <span className="text-teal-700 font-bold text-lg">{initial}</span>
                  </div>
                  
                  <div className="flex-1 min-w-0">
                    <h3 className="text-slate-900 font-semibold truncate text-base">
                      {patient?.name || 'Unknown Patient'}
                    </h3>
                    <p className="text-slate-500 text-xs mt-0.5">
                      {patient?.gender || 'N/A'} • {patient?.age ? `${patient.age} yrs` : 'N/A'}
                    </p>
                  </div>

                  <div className="flex flex-col items-end gap-1 flex-shrink-0">
                    {screening.is_urgent_referral ? (
                      <div className="flex items-center gap-1 text-red-600 bg-red-50 px-2 py-0.5 rounded-full">
                        <AlertCircle className="w-3 h-3" />
                        <span className="text-[10px] font-bold uppercase tracking-wider">Urgent</span>
                      </div>
                    ) : (
                      <div className="flex items-center gap-1 text-orange-600 bg-orange-50 px-2 py-0.5 rounded-full">
                        <Cloud className="w-3 h-3" />
                        <span className="text-[10px] font-bold uppercase tracking-wider">Pending</span>
                      </div>
                    )}
                  </div>
                </div>
              </button>
            );
          })
        )}
      </div>
    </div>
  );
}
