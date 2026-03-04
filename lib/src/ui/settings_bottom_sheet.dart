import 'package:flutter/material.dart';

class SettingsBottomSheet extends StatefulWidget {
  const SettingsBottomSheet({
    super.key,
    required this.initialBaseUrl,
    required this.initialDeviceName,
    required this.onSave,
  });

  final String initialBaseUrl;
  final String initialDeviceName;
  final Future<void> Function(String baseUrl, String deviceName) onSave;

  @override
  State<SettingsBottomSheet> createState() => _SettingsBottomSheetState();
}

class _SettingsBottomSheetState extends State<SettingsBottomSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baseUrlController;
  late final TextEditingController _deviceNameController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: widget.initialBaseUrl);
    _deviceNameController = TextEditingController(
      text: widget.initialDeviceName,
    );
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await widget.onSave(
        _baseUrlController.text.trim(),
        _deviceNameController.text.trim(),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Uygulama Ayarları',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _baseUrlController,
                enabled: !_saving,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Backend API URL',
                  hintText: 'http://10.0.2.2:8000/api',
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) {
                    return 'API URL gerekli.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _deviceNameController,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Cihaz adı'),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) {
                    return 'Cihaz adı gerekli.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Kaydet'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
