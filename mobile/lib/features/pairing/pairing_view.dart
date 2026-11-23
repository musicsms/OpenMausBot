import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/theme/grok_theme.dart';
import 'pairing_model.dart';

class ManualPairRequest {
  final String code;
  final String host;
  final int port;

  const ManualPairRequest({
    required this.code,
    required this.host,
    this.port = 8810,
  });

  String get baseUrl {
    final trimmed = host.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return Uri.parse(trimmed).origin;
    }
    return 'http://$trimmed:$port';
  }
}

class PairingView extends StatefulWidget {
  final Future<void> Function(PairingPayload payload) onPairSuccess;
  final Future<void> Function(ManualPairRequest request) onManualCodeSubmit;
  final Widget? scannerWidget;
  final String? errorMessage;
  final String? bannerMessage;
  final VoidCallback? onCancel;
  final bool isBusy;

  const PairingView({
    super.key,
    required this.onPairSuccess,
    required this.onManualCodeSubmit,
    this.scannerWidget,
    this.errorMessage,
    this.bannerMessage,
    this.onCancel,
    this.isBusy = false,
  });

  @override
  PairingViewState createState() => PairingViewState();
}

class PairingViewState extends State<PairingView> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  Future<void> handleScannedPayload(String rawJson) async {
    try {
      final payload = PairingPayload.fromJsonString(rawJson);
      await widget.onPairSuccess(payload);
    } catch (_) {}
  }

  Future<void> _submitManual() async {
    final code = _codeController.text.trim();
    final host = _hostController.text.trim();
    if (code.length != 6 || host.isEmpty) return;
    await widget.onManualCodeSubmit(ManualPairRequest(code: code, host: host));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      appBar: AppBar(
        title: const Text('Pair with Desktop', style: TextStyle(color: Colors.white)),
        backgroundColor: GrokTheme.oledBlack,
        elevation: 0,
        leading: widget.onCancel != null
            ? IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: widget.onCancel,
              )
            : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.bannerMessage != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: GrokTheme.darkCharcoal,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: GrokTheme.glowCyan),
                    ),
                    child: Text(
                      widget.bannerMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
                Container(
                  height: 180,
                  width: 180,
                  decoration: BoxDecoration(
                    border: Border.all(color: GrokTheme.glowCyan, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: widget.scannerWidget ??
                      MobileScanner(
                        onDetect: (capture) {
                          final List<Barcode> barcodes = capture.barcodes;
                          for (final barcode in barcodes) {
                            if (barcode.rawValue != null) {
                              handleScannedPayload(barcode.rawValue!);
                              break;
                            }
                          }
                        },
                        errorBuilder: (context, error, child) => const Center(
                          child: Icon(Icons.qr_code_scanner, size: 80, color: GrokTheme.glowCyan),
                        ),
                      ),
                ),
                const SizedBox(height: 32),
                const Text(
                  "Scan the QR code from your desktop app's Settings → Phone & devices",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GrokTheme.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _hostController,
                  keyboardType: TextInputType.url,
                  enabled: !widget.isBusy,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'desktop-host or 192.168.x.x',
                    hintStyle: const TextStyle(color: GrokTheme.textMuted),
                    helperText: 'Required for code pairing — not this phone',
                    helperStyle: const TextStyle(color: GrokTheme.textMuted, fontSize: 12),
                    filled: true,
                    fillColor: GrokTheme.darkCharcoal,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: GrokTheme.slateBorder),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  enabled: !widget.isBusy,
                  style: const TextStyle(color: Colors.white, letterSpacing: 8, fontSize: 20),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '000000',
                    hintStyle: const TextStyle(color: GrokTheme.textMuted, letterSpacing: 8),
                    filled: true,
                    fillColor: GrokTheme.darkCharcoal,
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: GrokTheme.slateBorder),
                    ),
                  ),
                ),
                if (widget.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    widget.errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: GrokTheme.rejectRed, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: widget.isBusy ? null : _submitManual,
                  child: Text(
                    widget.isBusy ? 'Pairing…' : 'Connect with Code',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
