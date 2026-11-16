import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('MausBotApp loads and renders base title', (WidgetTester tester) async {
    await tester.pumpWidget(const MausBotApp());
    expect(find.text('OpenMausBot'), findsOneWidget);
  });
}
