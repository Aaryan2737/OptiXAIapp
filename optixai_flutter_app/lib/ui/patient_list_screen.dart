import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../core/providers.dart';

class PatientListScreen extends StatelessWidget {
  const PatientListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final patients = context.watch<PatientRegistry>().patients;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Patient Records', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: AppColors.primary),
            onPressed: () => Navigator.pushNamed(context, '/new_patient'),
          )
        ],
      ),
      body: patients.isEmpty 
        ? _buildEmptyState() 
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: patients.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final p = patients[index];
              return _PatientCard(patient: p);
            },
          ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.folder_open, size: 64, color: AppColors.border),
          SizedBox(height: 16),
          Text('No Patients Found', style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w800)),
          SizedBox(height: 8),
          Text('Register a patient to begin screening.', style: TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  final Map<String, dynamic> patient;

  const _PatientCard({required this.patient});

  @override
  Widget build(BuildContext context) {
    final isSynced = patient['sync_status'] == 'synced';

    return InkWell(
      onTap: () {
        // Navigate to capture screen, passing the patient local ID
        Navigator.pushNamed(context, '/capture', arguments: patient['local_id'] as String);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: AppColors.primaryLight,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                (patient['full_name'] as String)[0].toUpperCase(),
                style: const TextStyle(color: AppColors.primary, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(patient['full_name'] as String, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('${patient['gender']} • ${patient['age']} yrs', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('Status', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(isSynced ? Icons.cloud_done : Icons.cloud_upload, size: 14, color: isSynced ? AppColors.onlineText : AppColors.syncText),
                    const SizedBox(width: 4),
                    Text(
                      isSynced ? 'Synced' : 'Pending',
                      style: TextStyle(color: isSynced ? AppColors.onlineText : AppColors.syncText, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                )
              ],
            )
          ],
        ),
      ),
    );
  }
}
