import { createClient } from '@/utils/supabase/server'
import { redirect } from 'next/navigation'
import Link from 'next/link'
import { Eye, LayoutDashboard, ListChecks, ArrowRight, Clock, MapPin, User } from 'lucide-react'

export default async function QueuePage() {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Fetch all urgent screenings and join patient data
  const { data: screenings, error } = await supabase
    .from('screenings')
    .select(`
      id, 
      left_eye_grade, 
      right_eye_grade, 
      screened_at,
      patients (
        full_name,
        contact_number,
        asha_workers (
          full_name,
          assigned_district
        )
      )
    `)
    .eq('is_urgent_refer', true)
    .order('screened_at', { ascending: false })
  
  if (error) {
    console.error('Error fetching queue:', error)
  }

  const queue = screenings || []

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
                <Link href="/dashboard" className="px-3 py-2 rounded-md text-neutral-400 hover:text-white hover:bg-white/5 text-sm font-medium transition-colors flex items-center gap-2">
                  <LayoutDashboard className="w-4 h-4" /> Dashboard
                </Link>
                <Link href="/queue" className="px-3 py-2 rounded-md bg-white/5 text-emerald-400 text-sm font-medium flex items-center gap-2">
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
        <div className="mb-8 flex justify-between items-end">
          <div>
            <h1 className="text-3xl font-light tracking-tight mb-2">Triage <span className="font-semibold text-red-400">Queue</span></h1>
            <p className="text-neutral-400">Urgent cases requiring immediate ophthalmologist review.</p>
          </div>
          <div className="text-sm px-4 py-1.5 rounded-full bg-white/5 border border-white/10 flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-red-500 animate-pulse" />
            {queue.length} Cases Pending
          </div>
        </div>

        {/* Data Table */}
        <div className="bg-white/[0.02] border border-white/10 rounded-2xl overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse">
              <thead>
                <tr className="border-b border-white/10 bg-white/[0.02]">
                  <th className="px-6 py-4 text-xs font-semibold text-neutral-400 uppercase tracking-wider">Patient</th>
                  <th className="px-6 py-4 text-xs font-semibold text-neutral-400 uppercase tracking-wider">Severity</th>
                  <th className="px-6 py-4 text-xs font-semibold text-neutral-400 uppercase tracking-wider">Location</th>
                  <th className="px-6 py-4 text-xs font-semibold text-neutral-400 uppercase tracking-wider">Captured At</th>
                  <th className="px-6 py-4 text-xs font-semibold text-neutral-400 uppercase tracking-wider text-right">Action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {queue.length === 0 ? (
                  <tr>
                    <td colSpan={5} className="px-6 py-12 text-center text-neutral-500">
                      No urgent cases pending review.
                    </td>
                  </tr>
                ) : (
                  queue.map((row) => {
                    const patient = row.patients as any
                    const asha = patient?.asha_workers
                    const maxGrade = Math.max(row.left_eye_grade || 0, row.right_eye_grade || 0)
                    
                    return (
                      <tr key={row.id} className="hover:bg-white/[0.02] transition-colors group">
                        <td className="px-6 py-4 whitespace-nowrap">
                          <div className="flex items-center gap-3">
                            <div className="w-8 h-8 rounded-full bg-white/10 flex items-center justify-center">
                              <User className="w-4 h-4 text-neutral-300" />
                            </div>
                            <div>
                              <div className="font-medium text-white">{patient?.full_name || 'Unknown Patient'}</div>
                              <div className="text-xs text-neutral-500">{patient?.contact_number || 'No Contact'}</div>
                            </div>
                          </div>
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap">
                          <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium border ${
                            maxGrade >= 4 ? 'bg-red-500/10 text-red-400 border-red-500/20' : 
                            maxGrade === 3 ? 'bg-orange-500/10 text-orange-400 border-orange-500/20' : 
                            'bg-yellow-500/10 text-yellow-400 border-yellow-500/20'
                          }`}>
                            Grade {maxGrade}
                          </span>
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap">
                          <div className="flex flex-col">
                            <span className="text-sm text-neutral-300 flex items-center gap-1">
                              <MapPin className="w-3 h-3 text-neutral-500" />
                              {asha?.assigned_district || 'Unknown District'}
                            </span>
                            <span className="text-xs text-neutral-500">ASHA: {asha?.full_name || 'Unknown'}</span>
                          </div>
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap">
                          <span className="text-sm text-neutral-300 flex items-center gap-1.5">
                            <Clock className="w-3.5 h-3.5 text-neutral-500" />
                            {new Date(row.screened_at).toLocaleString(undefined, {
                              month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
                            })}
                          </span>
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-right">
                          <Link
                            href={`/queue/${row.id}`}
                            className="inline-flex items-center gap-2 px-4 py-2 bg-white/5 hover:bg-emerald-500/20 text-emerald-400 border border-emerald-500/20 rounded-lg text-sm font-medium transition-all"
                          >
                            Review Case <ArrowRight className="w-4 h-4" />
                          </Link>
                        </td>
                      </tr>
                    )
                  })
                )}
              </tbody>
            </table>
          </div>
        </div>
      </main>
    </div>
  )
}
