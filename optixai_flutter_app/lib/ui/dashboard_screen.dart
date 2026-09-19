import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../core/providers.dart';
import '../core/sync_service.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await context.read<ConnectivityService>().refreshPendingCount();
            
            // Only attempt to push data if we are actually online
            if (!context.mounted) return;
            if (context.read<ConnectivityService>().isOnline) {
              await SyncService.performSync();
              if (!context.mounted) return;
              await context.read<ConnectivityService>().refreshPendingCount();
            }

            if (!context.mounted) return;
            await context.read<PatientRegistry>().refreshAll();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context),
                const SizedBox(height: 20),
                _buildConnectivityCard(context),
                const SizedBox(height: 20),
                const Text(
                  "Today's Screening",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                _buildStatsGrid(context),
                const SizedBox(height: 22),
                _buildSyncCard(context),
                const SizedBox(height: 22),
                const Text(
                  "Quick Actions",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                _buildActionCard(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final conn = context.watch<ConnectivityService>();
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('OptiXAI', style: TextStyle(color: AppColors.primary, fontSize: 16, fontWeight: FontWeight.w900)),
              SizedBox(height: 5),
              Text('Health Worker Dashboard', style: TextStyle(color: AppColors.textPrimary, fontSize: 25, fontWeight: FontWeight.w800)),
              SizedBox(height: 5),
              Text('Offline-first diabetic retinopathy screening', style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: conn.isChecking ? AppColors.backgroundElement : (conn.isOnline ? AppColors.onlineBackground : AppColors.offlineBackground),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Text(
                '●',
                style: TextStyle(
                  fontSize: 11,
                  color: conn.isChecking ? AppColors.textSecondary : (conn.isOnline ? AppColors.onlineText : AppColors.offlineText),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                conn.isChecking ? 'Checking' : (conn.isOnline ? 'Online' : 'Offline'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: conn.isChecking ? AppColors.textSecondary : (conn.isOnline ? AppColors.onlineText : AppColors.offlineText),
                ),
              )
            ],
          ),
        )
      ],
    );
  }

  Widget _buildConnectivityCard(BuildContext context) {
    final isOnline = context.watch<ConnectivityService>().isOnline;
    
    if (context.watch<ConnectivityService>().isChecking) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isOnline ? AppColors.onlineBackground : AppColors.offlineBackground,
        border: Border.all(color: isOnline ? AppColors.onlineBorder : AppColors.offlineBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isOnline ? AppColors.onlineIconBg : AppColors.offlineIconBg,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              isOnline ? Icons.check : Icons.offline_bolt,
              color: isOnline ? AppColors.onlineText : AppColors.offlineTextLight,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOnline ? 'Internet Connected' : 'Working Offline',
                  style: TextStyle(
                    color: isOnline ? AppColors.onlineText : AppColors.offlineText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isOnline ? 'Pending records can be synchronized when the backend is available.' : 'Patient records and screening data will remain on this device until internet connectivity returns.',
                  style: TextStyle(
                    color: isOnline ? AppColors.onlineText : AppColors.offlineTextLight,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStatsGrid(BuildContext context) {
    final stats = context.watch<PatientRegistry>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            children: [
              _StatCard(value: stats.totalPatients.toString(), label: 'Patients', icon: Icons.person),
              const SizedBox(height: 12),
              _StatCard(value: stats.moderateRisk.toString(), label: 'Moderate Risk', icon: Icons.warning_amber_rounded),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              _StatCard(value: stats.completedScreenings.toString(), label: 'Completed', icon: Icons.check_circle_outline),
              const SizedBox(height: 12),
              _StatCard(value: stats.highRisk.toString(), label: 'High Risk', icon: Icons.dangerous_outlined),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSyncCard(BuildContext context) {
    final pending = context.watch<ConnectivityService>().pendingSyncCount;
    final isOnline = context.watch<ConnectivityService>().isOnline;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Synchronization', style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text('Store-and-forward data', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.syncBackground,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  pending.toString(),
                  style: const TextStyle(color: AppColors.syncText, fontSize: 21, fontWeight: FontWeight.w900),
                ),
              )
            ],
          ),
          const SizedBox(height: 14),
          Text(
            pending == 0 ? 'No records are currently waiting for synchronization.' : '$pending records waiting for backend synchronization.',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.border),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Network', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              Text(
                isOnline ? 'Connected' : 'Offline',
                style: TextStyle(color: isOnline ? AppColors.onlineText : AppColors.offlineText, fontSize: 13, fontWeight: FontWeight.w800),
              )
            ],
          )
        ],
      ),
    );
  }

  Widget _buildActionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _ActionButton(icon: Icons.person_add, title: 'New Patient', subtitle: 'Register a patient', onTap: () => Navigator.pushNamed(context, '/new_patient')),
          _ActionButton(icon: Icons.camera_alt, title: 'Start Screening', subtitle: 'Capture fundus image', onTap: () => Navigator.pushNamed(context, '/screening_flow')),
          _ActionButton(icon: Icons.people, title: 'Patient Records', subtitle: 'View registered patients', onTap: () => Navigator.pushNamed(context, '/patient_list')),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;

  const _StatCard({required this.value, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.primaryLight,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.primary, size: 20),
          ),
          const SizedBox(height: 10),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 27, fontWeight: FontWeight.w900)),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 74),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(15),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: AppColors.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF94A3B8), size: 27),
          ],
        ),
      ),
    );
  }
}
