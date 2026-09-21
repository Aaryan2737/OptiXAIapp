import { NextResponse } from 'next/server'
import { createClient } from '@/utils/supabase/server'
import { GoogleGenAI } from '@google/genai'

export async function POST(request: Request) {
  try {
    const { screeningId, patientName, grade } = await request.json()
    
    if (!screeningId || !patientName || grade === undefined) {
      return NextResponse.json({ error: 'Missing required fields' }, { status: 400 })
    }

    const supabase = await createClient()
    const { data: { user } } = await supabase.auth.getUser()
    
    if (!user) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
    }

    // Get the Ophthalmologist's internal ID
    const { data: doctor } = await supabase
      .from('ophthalmologists')
      .select('id, hospital_name, full_name')
      .eq('auth_uid', user.id)
      .single()

    if (!doctor) {
      return NextResponse.json({ error: 'Doctor profile not found' }, { status: 404 })
    }

    // Generate empathetic message via Gemini
    const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY })
    
    const prompt = `
      You are an expert ophthalmologist communicating a referral to a rural patient named ${patientName}.
      The patient has been flagged by an AI screening device with Grade ${grade} Diabetic Retinopathy (severe/urgent).
      Your name is ${doctor.full_name} from ${doctor.hospital_name}.
      
      Write a short, culturally empathetic, and bilingual (English and Hindi) WhatsApp message to the patient (to be delivered via their local ASHA worker).
      The tone must be urgent but NOT alarming or terrifying. 
      Instruct them to visit ${doctor.hospital_name} for a free dilated eye exam immediately to preserve their vision.
      
      Format: Return ONLY the raw message text. No markdown, no preambles.
    `

    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash',
      contents: prompt,
    })

    const messageText = response.text

    if (!messageText) {
      throw new Error("Gemini returned empty response")
    }

    // Save to Supabase
    const { error: dbError } = await supabase
      .from('referrals')
      .insert({
        screening_id: screeningId,
        ophthalmologist_id: doctor.id,
        message_text: messageText,
        dispatch_status: 'dispatched'
      })

    if (dbError) throw dbError

    // Note: In a real deployment, we would trigger a Twilio/WhatsApp API call here.
    
    return NextResponse.json({ success: true, message: messageText })
    
  } catch (error: unknown) {
    console.error('Dispatch error:', error)
    const msg = error instanceof Error ? error.message : 'Internal Server Error'
    return NextResponse.json({ error: msg }, { status: 500 })
  }
}
