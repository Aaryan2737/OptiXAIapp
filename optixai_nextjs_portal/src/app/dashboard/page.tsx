import { createClient } from '@/utils/supabase/server'
import { redirect } from 'next/navigation'
import Link from 'next/link'
import { Eye, LayoutDashboard } from 'lucide-react'
import DashboardClient from './components/DashboardClient'
import LogoutButton from './components/LogoutButton'

export default async function DashboardPage() {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Fetch all screenings to compute top stats
  const { data: screenings, error } = await supabase
    .from('screenings')
    .select('id, ai_triage_grade_left, ai_triage_grade_right, is_urgent_referral, clinical_status, patients(id)')
  
  if (error) {
    console.error('Error fetching screenings:', error)
  }

  const validScreenings = screenings || []

  // Calculate Metrics
  const uniquePatients = new Set(
    validScreenings
      .map(s => {
        const p = s.patients as { id?: string } | null;
        return p?.id;
      })
      .filter(id => id)
  ).size;

  const completedScreenings = validScreenings.length;
  const highRisk = validScreenings.filter(s => s.is_urgent_referral).length;
  const moderateRisk = validScreenings.filter(s => !s.is_urgent_referral && (s.ai_triage_grade_left === 2 || s.ai_triage_grade_right === 2)).length;

  const initialStats = {
    totalPatients: uniquePatients,
    completedScreenings,
    moderateRisk,
    highRisk,
  }

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900 font-sans flex flex-col">
      {/* Top Navigation */}
      <nav className="border-b border-slate-200 bg-white sticky top-0 z-50">
        <div className="max-w-[1600px] mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center h-16">
            <div className="flex items-center gap-8">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-teal-50 border border-teal-100 rounded-lg flex items-center justify-center">
                  <Eye className="w-4 h-4 text-teal-600" />
                </div>
                <span className="font-bold tracking-wide text-slate-900">OptiXAI</span>
              </div>
              
              <div className="hidden md:flex items-center gap-1">
                <Link href="/dashboard" className="px-3 py-2 rounded-md bg-teal-50 text-teal-700 text-sm font-semibold flex items-center gap-2">
                  <LayoutDashboard className="w-4 h-4" /> Clinical Dashboard
                </Link>
              </div>
            </div>
            <div className="flex items-center gap-4">
              <div className="text-sm text-slate-500 font-medium flex items-center gap-2 bg-slate-50 px-3 py-1.5 rounded-full border border-slate-200">
                <div className="w-2 h-2 rounded-full bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.5)] animate-pulse" />
                Connected as {user.email}
              </div>
              <LogoutButton />
            </div>
          </div>
        </div>
      </nav>

      {/* Main Content Area (Scroll handled within components) */}
      <main className="flex-1 max-w-[1600px] w-full mx-auto flex flex-col overflow-hidden">
        <DashboardClient initialStats={initialStats} />
      </main>
    </div>
  )
}
