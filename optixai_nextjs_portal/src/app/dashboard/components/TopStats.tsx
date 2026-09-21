import { Users, CheckCircle, AlertTriangle, XOctagon } from 'lucide-react';

interface TopStatsProps {
  stats: {
    totalPatients: number;
    completedScreenings: number;
    moderateRisk: number;
    highRisk: number;
  };
}

export default function TopStats({ stats }: TopStatsProps) {
  const cards = [
    {
      title: 'Patients',
      value: stats.totalPatients,
      icon: Users,
      iconColor: 'text-blue-600',
      bgColor: 'bg-blue-50',
    },
    {
      title: 'Completed',
      value: stats.completedScreenings,
      icon: CheckCircle,
      iconColor: 'text-emerald-600',
      bgColor: 'bg-emerald-50',
    },
    {
      title: 'Moderate Risk',
      value: stats.moderateRisk,
      icon: AlertTriangle,
      iconColor: 'text-orange-600',
      bgColor: 'bg-orange-50',
    },
    {
      title: 'High Risk',
      value: stats.highRisk,
      icon: XOctagon,
      iconColor: 'text-red-600',
      bgColor: 'bg-red-50',
    },
  ];

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
      {cards.map((card, idx) => {
        const Icon = card.icon;
        return (
          <div
            key={idx}
            className="bg-white rounded-3xl p-6 border border-slate-100 shadow-[0_4px_20px_-4px_rgba(0,0,0,0.05)] flex flex-col"
          >
            <div className={`w-12 h-12 rounded-full flex items-center justify-center mb-4 ${card.bgColor}`}>
              <Icon className={`w-6 h-6 ${card.iconColor}`} />
            </div>
            <p className="text-4xl font-bold text-slate-900 mb-1">{card.value}</p>
            <p className="text-sm font-medium text-slate-500">{card.title}</p>
          </div>
        );
      })}
    </div>
  );
}
