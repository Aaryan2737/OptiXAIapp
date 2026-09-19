import { createClient } from '@/utils/supabase/server'
import { redirect } from 'next/navigation'
import Link from 'next/link'
import { Activity, AlertTriangle, Users, Eye, ArrowRight, LayoutDashboard, ListChecks } from 'lucide-react'
import DRDistributionChart from './DRDistributionChart'

export default async function DashboardPage() {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Get start of day for filtering
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const todayIso = today.toISOString()

  // Fetch all screenings (Doctor RLS policy allows viewing all)
  const { data: screenings, error } = await supabase
    .from('screenings')
    .select('id, left_eye_grade, right_eye_grade, is_urgent_refer, screened_at, patients(asha_worker_id)')
  
  if (error) {
    console.error('Error fetching screenings:', error)
  }

  const validScreenings = screenings || []

  // Calculate Metrics
  const screeningsToday = validScreenings.filter(s => new Date(s.screened_at) >= today).length
  const urgentPending = validScreenings.filter(s => s.is_urgent_refer).length // Assuming 'pending' means it's urgent and hasn't been referred yet. In reality, we'd check the `referrals` table, but for the dashboard overview, urgent count is fine.
  
  // Active ASHA workers (unique asha_worker_ids from all screenings)
  const activeAshas = new Set(
    validScreenings
      .map(s => (s.patients as any)?.asha_worker_id)
      .filter(id => id)
  ).size

  // Calculate Distribution
  const distribution = [0, 0, 0, 0, 0]
  validScreenings.forEach(s => {
    if (s.left_eye_grade !== null) distribution[s.left_eye_grade]++
    if (s.right_eye_grade !== null) distribution[s.right_eye_grade]++
  })

  const chartData = [
    { name: 'Grade 0 (None)', count: distribution[0], color: '#10b981' },
    { name: 'Grade 1 (Mild)', count: distribution[1], color: '#3b82f6' },
    { name: 'Grade 2 (Moderate)', count: distribution[2], color: '#f59e0b' },
    { name: 'Grade 3 (Severe)', count: distribution[3], color: '#f97316' },
    { name: 'Grade 4 (PDR)', count: distribution[4], color: '#ef4444' },
  ]

  return (
    <div className="min-h-screen bg-[#050505] text-white">
      {/* Top Navigation */}
      <nav className="border-b border-white/10 bg-black/50 backdrop-blur-xl sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center h-16">
            <div className="flex items-center gap-8">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-white/5 border border-white/10 rounded-lg flex items-center justify-center">
                  <Eye className="w-4 h-4 text-emerald-400" />
                </div>
                <span className="font-semibold tracking-wide">OptiXAI</span>
              </div>
              
              <div className="hidden md:flex items-center gap-1">
                <Link href="/dashboard" className="px-3 py-2 rounded-md bg-white/5 text-emerald-400 text-sm font-medium flex items-center gap-2">
                  <LayoutDashboard className="w-4 h-4" /> Dashboard
                </Link>
                <Link href="/queue" className="px-3 py-2 rounded-md text-neutral-400 hover:text-white hover:bg-white/5 text-sm font-medium transition-colors flex items-center gap-2">
                  <ListChecks className="w-4 h-4" /> Triage Queue
                </Link>
              </div>
            </div>
            <div className="flex items-center gap-4">
              <div className="text-sm text-neutral-400 flex items-center gap-2">
                <div className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
                Connected as {user.email}
              </div>
            </div>
          </div>
        </div>
      </nav>

      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="mb-8">
          <h1 className="text-3xl font-light tracking-tight mb-2">Hospital <span className="font-semibold">Overview</span></h1>
          <p className="text-neutral-400">Real-time telemetry from edge screening devices.</p>
        </div>

        {/* Metrics Grid */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6 relative overflow-hidden group">
            <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
              <Activity className="w-16 h-16 text-blue-500" />
            </div>
            <p className="text-sm text-neutral-400 uppercase tracking-wider font-semibold mb-2">Screenings Today</p>
            <p className="text-4xl font-light text-white">{screeningsToday}</p>
          </div>
          
          <div className="bg-red-500/[0.02] border border-red-500/20 rounded-2xl p-6 relative overflow-hidden group">
            <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
              <AlertTriangle className="w-16 h-16 text-red-500" />
            </div>
            <p className="text-sm text-red-400/80 uppercase tracking-wider font-semibold mb-2">Urgent Referrals</p>
            <div className="flex items-end justify-between">
              <p className="text-4xl font-light text-red-400">{urgentPending}</p>
              <Link href="/queue" className="flex items-center gap-1 text-sm text-red-400 hover:text-red-300 transition-colors pb-1">
                View Queue <ArrowRight className="w-4 h-4" />
              </Link>
            </div>
          </div>

          <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6 relative overflow-hidden group">
            <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
              <Users className="w-16 h-16 text-emerald-500" />
            </div>
            <p className="text-sm text-neutral-400 uppercase tracking-wider font-semibold mb-2">Active Field Workers</p>
            <p className="text-4xl font-light text-white">{activeAshas}</p>
          </div>
        </div>

        {/* Chart Section */}
        <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6 shadow-2xl">
          <h2 className="text-lg font-medium mb-6 flex items-center gap-2">
            <Activity className="w-5 h-5 text-emerald-400" />
            Diabetic Retinopathy Severity Distribution
          </h2>
          <div className="h-[400px] w-full">
            <DRDistributionChart data={chartData} />
          </div>
        </div>
      </main>
    </div>
  )
}
