import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/grok_theme.dart';
import 'approval_model.dart';

class ApprovalCard extends StatelessWidget {
  final ApprovalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const ApprovalCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GrokTheme.darkCharcoal,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.shade700, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, color: Colors.amber.shade400, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'YÊU CẦU PHÊ DUYỆT CÔNG CỤ',
                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              if (request.dangerLevel != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade900.withAlpha(80),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amber.shade600, width: 0.8),
                  ),
                  child: Text(
                    request.dangerLevel!.toUpperCase(),
                    style: TextStyle(color: Colors.amber.shade200, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            request.toolName,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: GrokTheme.oledBlack,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: GrokTheme.slateBorder),
            ),
            child: request.arguments.isEmpty
                ? const Text(
                    'Không có tham số',
                    style: TextStyle(color: GrokTheme.textMuted, fontSize: 13),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: request.arguments.entries.map((entry) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${entry.key}: ', style: const TextStyle(color: GrokTheme.textMuted, fontSize: 13)),
                            Expanded(
                              child: Text('${entry.value}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: GrokTheme.rejectRed,
                    side: const BorderSide(color: GrokTheme.rejectRed),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onReject();
                  },
                  child: const Text('Từ chối'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GrokTheme.approvalGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onApprove();
                  },
                  child: const Text('Duyệt'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
