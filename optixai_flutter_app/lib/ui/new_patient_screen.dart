import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_colors.dart';
import '../core/local_database.dart';
import '../core/providers.dart';

class NewPatientScreen extends StatefulWidget {
  const NewPatientScreen({super.key});

  @override
  State<NewPatientScreen> createState() => _NewPatientScreenState();
}

class _NewPatientScreenState extends State<NewPatientScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  String _gender = 'Other';
  bool _isSaving = false;

  Future<void> _savePatient() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isSaving = true);

    final localId = const Uuid().v4();
    final patient = {
      'local_id': localId,
      'asha_worker_id': 'ASHA_MOBILE_01', // Harcoded for demo
      'full_name': _nameCtrl.text.trim(),
      'age': int.tryParse(_ageCtrl.text.trim()),
      'gender': _gender,
      'contact_number': _contactCtrl.text.trim(),
      'sync_status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    };

    await LocalDatabase.instance.insertPatient(patient);
    
    await context.read<PatientRegistry>().refreshAll();
    if (!context.mounted) return;
    await context.read<ConnectivityService>().refreshPendingCount();
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('New Patient', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Patient Registration', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 5),
              const Text('Register a new patient for offline edge screening.', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 25),
              
              _buildTextField('Full Name', _nameCtrl, Icons.person, TextInputType.name),
              const SizedBox(height: 16),
              
              Row(
                children: [
                  Expanded(child: _buildTextField('Age', _ageCtrl, Icons.calendar_today, TextInputType.number)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _gender,
                      decoration: InputDecoration(
                        labelText: 'Gender',
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                      ),
                      items: ['Male', 'Female', 'Other'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setState(() => _gender = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildTextField('Contact Number', _contactCtrl, Icons.phone, TextInputType.phone),
              
              const SizedBox(height: 35),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _isSaving ? null : _savePatient,
                  child: _isSaving 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Save & Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, IconData icon, TextInputType type) {
    return TextFormField(
      controller: controller,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.primary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary)),
      ),
      validator: (v) => v!.isEmpty ? 'Required field' : null,
    );
  }
}
