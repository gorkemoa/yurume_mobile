import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/auth_controller.dart';
import '../models/models.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const _demoEmail = 'demo@yurume.app';
  static const _demoPassword = 'Demo1234!';

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _deviceNameController = TextEditingController();

  bool _registerMode = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authController = context.read<AuthController>();
    if (_baseUrlController.text.isEmpty) {
      _baseUrlController.text = authController.baseUrl;
    }
    if (_deviceNameController.text.isEmpty) {
      _deviceNameController.text = authController.deviceName;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    _baseUrlController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthController authController) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      await authController.verifyBaseUrl(_baseUrlController.text);
      await authController.setBaseUrl(_baseUrlController.text);
      await authController.setDeviceName(_deviceNameController.text);

      if (_registerMode) {
        await authController.register(
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          passwordConfirmation: _passwordConfirmController.text,
          deviceName: _deviceNameController.text.trim(),
        );
      } else {
        await authController.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          deviceName: _deviceNameController.text.trim(),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      final message = error is ApiError
          ? error.message
          : error.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _testConnection(AuthController authController) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      await authController.verifyBaseUrl(_baseUrlController.text);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bağlantı başarılı.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _autoDiscover(AuthController authController) async {
    try {
      final discovered = await authController.discoverLocalBackendBaseUrl();
      if (!mounted) {
        return;
      }
      setState(() {
        _baseUrlController.text = discovered;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backend bulundu: $discovered')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _demoLogin(AuthController authController) async {
    setState(() {
      _registerMode = false;
      _emailController.text = _demoEmail;
      _passwordController.text = _demoPassword;
    });
    await _submit(authController);
  }

  @override
  Widget build(BuildContext context) {
    final authController = context.watch<AuthController>();
    final busy = authController.busy;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Yurume',
                          style: Theme.of(context).textTheme.headlineMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Gerçek konum verisi ile alan sahiplen',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                              value: false,
                              label: Text('Giriş'),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              label: Text('Kayıt'),
                            ),
                          ],
                          selected: <bool>{_registerMode},
                          onSelectionChanged: busy
                              ? null
                              : (selection) {
                                  setState(() {
                                    _registerMode = selection.first;
                                  });
                                },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _baseUrlController,
                          enabled: !busy,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Backend API URL',
                            hintText: 'http://10.0.2.2:8000/api',
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            if (text.isEmpty) {
                              return 'API URL gerekli.';
                            }
                            if (!text.contains('.')) {
                              return 'Geçerli bir host girin.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _deviceNameController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Cihaz adı',
                          ),
                          validator: (value) {
                            if ((value ?? '').trim().isEmpty) {
                              return 'Cihaz adı gerekli.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => _testConnection(authController),
                              icon: const Icon(Icons.wifi_tethering),
                              label: const Text('Bağlantıyı Test Et'),
                            ),
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => _autoDiscover(authController),
                              icon: const Icon(Icons.search),
                              label: const Text('Ağda Bul'),
                            ),
                          ],
                        ),
                        if (_registerMode) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _nameController,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              labelText: 'Ad Soyad',
                            ),
                            validator: (value) {
                              if ((value ?? '').trim().length < 2) {
                                return 'En az 2 karakter girin.';
                              }
                              return null;
                            },
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _emailController,
                          enabled: !busy,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email'),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.isEmpty) {
                              return 'Email gerekli.';
                            }
                            if (!text.contains('@')) {
                              return 'Geçerli bir email girin.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _passwordController,
                          enabled: !busy,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Parola',
                          ),
                          validator: (value) {
                            if ((value ?? '').length < 8) {
                              return 'Parola en az 8 karakter olmalı.';
                            }
                            return null;
                          },
                        ),
                        if (_registerMode) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordConfirmController,
                            enabled: !busy,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Parola tekrar',
                            ),
                            validator: (value) {
                              if (value != _passwordController.text) {
                                return 'Parolalar aynı olmalı.';
                              }
                              return null;
                            },
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: busy
                              ? null
                              : () => _submit(authController),
                          icon: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _registerMode
                                      ? Icons.person_add
                                      : Icons.login,
                                ),
                          label: Text(_registerMode ? 'Kayıt Ol' : 'Giriş Yap'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => _demoLogin(authController),
                          icon: const Icon(Icons.bolt),
                          label: const Text('Demo Hesap ile Giriş'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
