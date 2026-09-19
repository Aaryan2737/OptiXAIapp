import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import './globals.css'

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-inter',
})

export const metadata: Metadata = {
  title: 'OptiXAI Portal | Telemedicine Triage',
  description: 'Enterprise Ophthalmology Dashboard for AI-Assisted DR Triage.',
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" className="dark">
      <body className={`${inter.variable} font-sans bg-[#050505] text-white antialiased selection:bg-emerald-500/30 selection:text-emerald-200`}>
        {children}
      </body>
    </html>
  )
}
