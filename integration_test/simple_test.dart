import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api.dart';
import 'package:termpulse/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Rust core initializes and renders TermPulse vault', (WidgetTester tester) async {
    expect(healthCheck(), 'termpulse-rust-core-ok');
    await tester.pumpWidget(const ProviderScope(child: TermPulseApp()));
    expect(find.text('TermPulse'), findsOneWidget);
  });
}
