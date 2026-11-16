import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/theme/grok_theme.dart';
import 'pairing_model.dart';

class PairingView extends StatefulWidget {
  final ValueChanged<PairingPayload> onPairSuccess;
  final ValueChanged<String> onManualCodeSubmit;
  final Widget? scannerWidget;

  const PairingView({
    super.key,
    required this.onPairSuccess,
    required this.onManualCodeSubmit,
    this.scannerWidget,
  });

  @override
  PairingViewState createState() => PairingViewState();
}

class PairingViewState extends State<PairingView> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void handleScannedPayload(String rawJson) {
    try {
      final payload = PairingPayload.fromJsonString(rawJson);
      widget.onPairSuccess(payload);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      appBar: AppBar(
        title: const Text('Pair with Desktop', style: TextStyle(color: Colors.white)),
        backgroundColor: GrokTheme.oledBlack,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 220,
                  width: 220,
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
                  'Scan QR code from OpenMausBot Desktop Settings → Mobile',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GrokTheme.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
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
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    if (_codeController.text.length == 6) {
                      widget.onManualCodeSubmit(_codeController.text);
                    }
                  },
                  child: const Text('Connect with Code', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
