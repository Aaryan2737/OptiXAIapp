import { createClient } from '@/utils/supabase/server'
import { redirect } from 'next/navigation'
import Link from 'next/link'
import { ArrowLeft, Brain, Scan, Eye, User, FileText } from 'lucide-react'
import ReferralAction from './ReferralAction'

export default async function CaseReviewPage({ params }: { params: { id: string } }) {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Fetch Screening
  const { data: screening, error } = await supabase
    .from('screenings')
    .select(`
      *,
      patients (
        *,
        asha_workers (
          full_name,
          assigned_district
        )
      )
    `)
    .eq('id', params.id)
    .single()

  if (error || !screening) {
    return <div className="p-8 text-white">Case not found.</div>
  }

  // Fetch Heatmap
  const { data: heatmaps } = await supabase
    .from('heatmaps')
    .select('*')
    .eq('screening_id', params.id)

  const patient = screening.patients as { full_name?: string, age?: number, gender?: string, contact_number?: string, asha_workers?: { full_name?: string, assigned_district?: string } } | null
  const maxGrade = Math.max(screening.ai_triage_grade_left || 0, screening.ai_triage_grade_right || 0)

  // Helper to get signed URLs safely
  async function getSignedUrl(bucket: string, publicUrl: string | null) {
    if (!publicUrl) return null
    try {
      const parts = publicUrl.split(`${bucket}/`)
      if (parts.length < 2) return null
      const path = parts[1].split('?')[0].replace(/^\//, '')
      const { data } = await supabase.storage.from(bucket).createSignedUrl(path, 3600)
      return data?.signedUrl || null
    } catch {
      return null
    }
  }

  const leftEyeUrl = await getSignedUrl('fundus-images', screening.left_eye_image_path)
  const rightEyeUrl = await getSignedUrl('fundus-images', screening.right_eye_image_path)
  
  // Find heatmaps
  const leftHeatmapObj = heatmaps?.find(h => h.heatmap_url.includes('left'))
  const leftHeatmapUrl = await getSignedUrl('heatmaps', leftHeatmapObj?.heatmap_url || null)

  const rightHeatmapObj = heatmaps?.find(h => h.heatmap_url.includes('right'))
  const rightHeatmapUrl = await getSignedUrl('heatmaps', rightHeatmapObj?.heatmap_url || null)

  return (
    <div className="min-h-screen bg-[#050505] text-white">
      {/* Top Nav */}
      <nav className="border-b border-white/10 bg-black/50 backdrop-blur-xl sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 h-16 flex items-center gap-4">
          <Link href="/queue" className="p-2 hover:bg-white/10 rounded-full transition-colors">
            <ArrowLeft className="w-5 h-5 text-neutral-400" />
          </Link>
          <div className="h-6 w-[1px] bg-white/10 mx-2" />
          <span className="font-medium">Case Review</span>
          <span className="text-neutral-500 text-sm">#{screening.id.split('-')[0]}</span>
        </div>
      </nav>

      <main className="max-w-7xl mx-auto px-4 py-8 grid grid-cols-1 lg:grid-cols-3 gap-8">
        
        {/* Left Col: Imagery */}
        <div className="lg:col-span-2 space-y-6">
          {/* Left Eye Panel */}
          {screening.left_eye_image_path && (
            <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6">
              <h2 className="text-lg font-medium flex items-center gap-2 mb-6">
                <Eye className="w-5 h-5 text-blue-400" />
                Left Eye Analysis
              </h2>
              
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {/* Raw Image */}
                <div className="space-y-2">
                  <p className="text-xs text-neutral-400 uppercase tracking-wider font-semibold">Raw Capture</p>
                  <div className="aspect-square rounded-xl bg-black/50 border border-white/5 relative overflow-hidden flex items-center justify-center">
                    {leftEyeUrl ? (
                      <img src={leftEyeUrl} alt="Raw Left Eye" className="object-cover w-full h-full" />
                    ) : (
                      <Scan className="w-8 h-8 text-neutral-600" />
                    )}
                  </div>
                </div>

                {/* Heatmap Image */}
                <div className="space-y-2">
                  <p className="text-xs text-emerald-400 uppercase tracking-wider font-semibold flex items-center gap-2">
                    <Brain className="w-3 h-3" /> Grad-CAM Explanation
                  </p>
                  <div className="aspect-square rounded-xl bg-black/50 border border-emerald-500/20 relative overflow-hidden flex items-center justify-center shadow-[0_0_30px_rgba(16,185,129,0.05)]">
                    {leftHeatmapUrl ? (
                      <img src={leftHeatmapUrl} alt="Heatmap Left Eye" className="object-cover w-full h-full" />
                    ) : (
                      <div className="text-center text-sm text-neutral-500">
                        <Brain className="w-8 h-8 mx-auto mb-2 opacity-50" />
                        Heatmap Pending
                      </div>
                    )}
                  </div>
                </div>
              </div>
              
              <div className="mt-6 flex items-center gap-4">
                 <span className={`inline-flex items-center px-3 py-1 rounded-full text-sm font-medium border ${
                    screening.ai_triage_grade_left >= 4 ? 'bg-red-500/10 text-red-400 border-red-500/20' : 
                    screening.ai_triage_grade_left === 3 ? 'bg-orange-500/10 text-orange-400 border-orange-500/20' : 
                    'bg-yellow-500/10 text-yellow-400 border-yellow-500/20'
                  }`}>
                    Model Prediction: Grade {screening.ai_triage_grade_left}
                  </span>
                  <span className="text-sm text-neutral-400">
                    Confidence: {(screening.ai_confidence_score * 100).toFixed(1)}%
                  </span>
              </div>
            </div>
          )}

          {/* Right Eye Panel */}
          {screening.right_eye_image_path && (
            <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6">
              <h2 className="text-lg font-medium flex items-center gap-2 mb-6">
                <Eye className="w-5 h-5 text-blue-400" />
                Right Eye Analysis
              </h2>
              
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {/* Raw Image */}
                <div className="space-y-2">
                  <p className="text-xs text-neutral-400 uppercase tracking-wider font-semibold">Raw Capture</p>
                  <div className="aspect-square rounded-xl bg-black/50 border border-white/5 relative overflow-hidden flex items-center justify-center">
                    {rightEyeUrl ? (
                      <img src={rightEyeUrl} alt="Raw Right Eye" className="object-cover w-full h-full" />
                    ) : (
                      <Scan className="w-8 h-8 text-neutral-600" />
                    )}
                  </div>
                </div>

                {/* Heatmap Image */}
                <div className="space-y-2">
                  <p className="text-xs text-emerald-400 uppercase tracking-wider font-semibold flex items-center gap-2">
                    <Brain className="w-3 h-3" /> Grad-CAM Explanation
                  </p>
                  <div className="aspect-square rounded-xl bg-black/50 border border-emerald-500/20 relative overflow-hidden flex items-center justify-center shadow-[0_0_30px_rgba(16,185,129,0.05)]">
                    {rightHeatmapUrl ? (
                      <img src={rightHeatmapUrl} alt="Heatmap Right Eye" className="object-cover w-full h-full" />
                    ) : (
                      <div className="text-center text-sm text-neutral-500">
                        <Brain className="w-8 h-8 mx-auto mb-2 opacity-50" />
                        Heatmap Pending
                      </div>
                    )}
                  </div>
                </div>
              </div>
              
              <div className="mt-6 flex items-center gap-4">
                 <span className={`inline-flex items-center px-3 py-1 rounded-full text-sm font-medium border ${
                    screening.ai_triage_grade_right >= 4 ? 'bg-red-500/10 text-red-400 border-red-500/20' : 
                    screening.ai_triage_grade_right === 3 ? 'bg-orange-500/10 text-orange-400 border-orange-500/20' : 
                    'bg-yellow-500/10 text-yellow-400 border-yellow-500/20'
                  }`}>
                    Model Prediction: Grade {screening.ai_triage_grade_right}
                  </span>
                  <span className="text-sm text-neutral-400">
                    Confidence: {(screening.ai_confidence_score * 100).toFixed(1)}%
                  </span>
              </div>
            </div>
          )}
        </div>

        {/* Right Col: Patient Details & Actions */}
        <div className="space-y-6">
          
          <div className="bg-white/[0.02] border border-white/10 rounded-2xl p-6">
            <h2 className="text-lg font-medium flex items-center gap-2 mb-4">
              <User className="w-5 h-5 text-neutral-400" />
              Patient Demographics
            </h2>
            <dl className="space-y-4">
              <div>
                <dt className="text-xs text-neutral-500 uppercase tracking-wider">Name</dt>
                <dd className="text-white font-medium text-lg">{patient?.full_name || 'Unknown'}</dd>
              </div>
              <div>
                <dt className="text-xs text-neutral-500 uppercase tracking-wider">Age & Gender</dt>
                <dd className="text-white">{patient?.age || '--'} yrs, {patient?.gender || '--'}</dd>
              </div>
              <div>
                <dt className="text-xs text-neutral-500 uppercase tracking-wider">Contact</dt>
                <dd className="text-white">{patient?.contact_number || '--'}</dd>
              </div>
              <div className="pt-4 border-t border-white/10 mt-4">
                <dt className="text-xs text-emerald-500 uppercase tracking-wider mb-1">ASHA Worker Assigned</dt>
                <dd className="text-white font-medium">{patient?.asha_workers?.full_name || '--'}</dd>
                <dd className="text-neutral-400 text-sm">{patient?.asha_workers?.assigned_district || '--'} District</dd>
              </div>
            </dl>
          </div>

          <div className="bg-gradient-to-br from-emerald-500/10 to-blue-500/5 border border-emerald-500/20 rounded-2xl p-6">
             <h2 className="text-lg font-medium flex items-center gap-2 mb-2 text-emerald-400">
              <FileText className="w-5 h-5" />
              Ophthalmologist Action
            </h2>
            <p className="text-sm text-neutral-400 mb-6">
              Review the Grad-CAM evidence. If you concur with the AI&apos;s urgent flag, dispatch an empathetic referral message directly to the patient via the local ASHA worker.
            </p>
            
            <ReferralAction screeningId={screening.id} patientName={patient?.full_name || 'Unknown'} grade={maxGrade} />
          </div>

        </div>

      </main>
    </div>
  )
}
