// Smoke test that the app boots to its loading state without throwing.
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/main.dart';

void main() {
  testWidgets('WeDrop shows its splash while starting', (tester) async {
    await tester.pumpWidget(const WeDropApp());
    // The service starts asynchronously, so the first frame is the splash.
    expect(find.text('Starting WeDrop…'), findsOneWidget);
  });
}
