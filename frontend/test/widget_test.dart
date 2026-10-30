import 'package:clubins_frontend/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the placeholder home screen', (tester) async {
    await tester.pumpWidget(const ClubinsApp());
    expect(find.text('Clubins auth reference'), findsOneWidget);
  });
}
