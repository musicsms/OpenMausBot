import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/approvals/approval_card.dart';
import 'package:mobile/features/approvals/approval_model.dart';

void main() {
  testWidgets('ApprovalCard displays tool arguments and handles approve tap', (WidgetTester tester) async {
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final List<MethodCall> hapticCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(methodCall);
        }
        return null;
      },
    );

    bool approved = false;
    final request = ApprovalRequest(
      id: 'appr-1',
      botId: 'chief',
      toolName: 'google__work__gmail_send_mail',
      arguments: {'to': 'partner@acme.com', 'subject': 'Hợp đồng'},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: Scaffold(
          body: ApprovalCard(
            request: request,
            onApprove: () => approved = true,
            onReject: () {},
          ),
        ),
      ),
    );

    expect(find.text('google__work__gmail_send_mail'), findsOneWidget);
    expect(find.text('partner@acme.com'), findsOneWidget);
    expect(find.text('Hợp đồng'), findsOneWidget);

    await tester.tap(find.text('Duyệt'));
    await tester.pump();

    expect(approved, true);
    expect(hapticCalls.length, 1);
    expect(hapticCalls.first.arguments, 'HapticFeedbackType.mediumImpact');
  });

  testWidgets('ApprovalCard handles reject tap and haptic feedback', (WidgetTester tester) async {
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final List<MethodCall> hapticCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(methodCall);
        }
        return null;
      },
    );

    bool rejected = false;
    final request = ApprovalRequest(
      id: 'appr-2',
      botId: 'chief',
      toolName: 'bash_run_command',
      arguments: {'command': 'rm -rf /tmp/test'},
      dangerLevel: 'high',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: Scaffold(
          body: ApprovalCard(
            request: request,
            onApprove: () {},
            onReject: () => rejected = true,
          ),
        ),
      ),
    );

    expect(find.text('bash_run_command'), findsOneWidget);
    expect(find.text('rm -rf /tmp/test'), findsOneWidget);
    expect(find.text('HIGH'), findsOneWidget);

    await tester.tap(find.text('Từ chối'));
    await tester.pump();

    expect(rejected, true);
    expect(hapticCalls.length, 1);
    expect(hapticCalls.first.arguments, 'HapticFeedbackType.mediumImpact');
  });

  testWidgets('ApprovalCard displays fallback text when arguments are empty', (WidgetTester tester) async {
    final request = ApprovalRequest(
      id: 'appr-3',
      botId: 'chief',
      toolName: 'system_reboot',
      arguments: {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: Scaffold(
          body: ApprovalCard(
            request: request,
            onApprove: () {},
            onReject: () {},
          ),
        ),
      ),
    );

    expect(find.text('system_reboot'), findsOneWidget);
    expect(find.text('Không có tham số'), findsOneWidget);
  });

  test('ApprovalRequest serializes and deserializes properly', () {
    final json = {
      'id': 'req-99',
      'botId': 'chief',
      'toolName': 'fs_delete',
      'arguments': {'path': '/workspace/file.txt'},
      'dangerLevel': 'critical',
    };

    final request = ApprovalRequest.fromJson(json);
    expect(request.id, 'req-99');
    expect(request.botId, 'chief');
    expect(request.toolName, 'fs_delete');
    expect(request.arguments, {'path': '/workspace/file.txt'});
    expect(request.dangerLevel, 'critical');

    final serialized = request.toJson();
    expect(serialized['id'], 'req-99');
    expect(serialized['botId'], 'chief');
    expect(serialized['toolName'], 'fs_delete');
    expect(serialized['arguments'], {'path': '/workspace/file.txt'});
    expect(serialized['dangerLevel'], 'critical');

    final minimalRequest = ApprovalRequest(
      id: 'req-100',
      botId: 'chief',
      toolName: 'ping',
      arguments: {},
    );
    final minimalJson = minimalRequest.toJson();
    expect(minimalJson.containsKey('dangerLevel'), false);
  });

  test('ApprovalRequest coerces non-generic and invalid map arguments defensively', () {
    final dynamicMap = <dynamic, dynamic>{'num': 42};
    final req1 = ApprovalRequest.fromJson({
      'id': 'req-map',
      'botId': 'chief',
      'toolName': 'calc',
      'arguments': dynamicMap,
    });
    expect(req1.arguments, {'num': 42});

    final req2 = ApprovalRequest.fromJson({
      'id': 'req-bad',
      'botId': 'chief',
      'toolName': 'calc',
      'arguments': 'not-a-map',
    });
    expect(req2.arguments, isEmpty);
  });
}
