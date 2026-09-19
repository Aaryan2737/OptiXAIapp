'use client'

import { useState } from 'react'
import { CheckCircle2, Send, Loader2 } from 'lucide-react'

export default function ReferralAction({ screeningId, patientName, grade }: { screeningId: string, patientName: string, grade: number }) {
  const [loading, setLoading] = useState(false)
  const [success, setSuccess] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleDispatch = async () => {
    setLoading(true)
    setError(null)
    
    try {
      const res = await fetch('/api/dispatch-referral', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ screeningId, patientName, grade })
      })
      
      if (!res.ok) throw new Error('Failed to dispatch referral')
      
      setSuccess(true)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  if (success) {
    return (
      <div className="bg-emerald-500/10 border border-emerald-500/20 rounded-xl p-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <CheckCircle2 className="w-5 h-5 text-emerald-400" />
          <span className="text-emerald-400 font-medium">Referral Dispatched via WhatsApp</span>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      {error && <p className="text-red-400 text-sm">{error}</p>}
      <button
        onClick={handleDispatch}
        disabled={loading}
        className="w-full flex items-center justify-center gap-2 bg-emerald-500 hover:bg-emerald-400 text-black font-semibold py-3 px-4 rounded-xl transition-all disabled:opacity-50"
      >
        {loading ? (
          <Loader2 className="w-5 h-5 animate-spin" />
        ) : (
          <>
            <Send className="w-4 h-4" />
            Sign Off & Dispatch Referral
          </>
        )}
      </button>
    </div>
  )
}
