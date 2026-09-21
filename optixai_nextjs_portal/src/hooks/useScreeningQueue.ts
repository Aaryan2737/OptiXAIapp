import { useEffect, useState } from 'react';
import { createClient } from '@/utils/supabase/client';
import { ScreeningRecord } from '../types/screening';

export function useScreeningQueue() {
  const [screenings, setScreenings] = useState<ScreeningRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const supabase = createClient();

  useEffect(() => {
    const fetchScreenings = async () => {
      const { data, error } = await supabase
        .from('screenings')
        .select('*, patients(name:full_name, age, gender)')
        .eq('clinical_status', 'pending_doctor_review')
        .order('is_urgent_referral', { ascending: false })
        .order('screened_at', { ascending: false });

      if (error) {
        console.error('Error fetching screenings:', error);
      } else {
        setScreenings(data as any as ScreeningRecord[]);
      }
      setLoading(false);
    };

    fetchScreenings();

    const channel = supabase
      .channel('public:screenings')
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'screenings',
          filter: 'clinical_status=eq.pending_doctor_review'
        },
        (payload) => {
          // Fetch again to ensure we get the joined patients(full_name) and sorting
          fetchScreenings();
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, []);

  return { screenings, loading };
}
