'use client';

import { useState } from 'react';
import { useScreeningQueue } from '@/hooks/useScreeningQueue';
import TopStats from './TopStats';
import TriageSidebar from './TriageSidebar';
import Workspace from './Workspace';

interface DashboardClientProps {
  initialStats: {
    totalPatients: number;
    completedScreenings: number;
    moderateRisk: number;
    highRisk: number;
  };
}

export default function DashboardClient({ initialStats }: DashboardClientProps) {
  const { screenings, loading } = useScreeningQueue();
  const [selectedScreeningId, setSelectedScreeningId] = useState<string | null>(null);

  // Find the selected screening object
  const selectedScreening = screenings.find(s => s.id === selectedScreeningId) || null;

  return (
    <div className="flex flex-col h-[calc(100vh-4rem)] bg-slate-50">
      
      {/* Top Stats Section (Scrollable with the rest if needed, or fixed. Let's make it part of a fixed header area for the main content) */}
      <div className="p-6 lg:p-8 pb-0">
        <h1 className="text-3xl font-light tracking-tight mb-2 text-slate-900">
          Clinical <span className="font-bold">Dashboard</span>
        </h1>
        <p className="text-slate-500 mb-6">Real-time triage queue and MathWorks explainability workspace.</p>
        
        <TopStats stats={initialStats} />
      </div>

      <div className="flex flex-1 overflow-hidden">
        <TriageSidebar 
          screenings={screenings} 
          loading={loading} 
          selectedId={selectedScreeningId} 
          onSelect={setSelectedScreeningId} 
        />
        <Workspace screening={selectedScreening} />
      </div>
    </div>
  );
}
