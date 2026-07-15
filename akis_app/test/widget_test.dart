import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:akis_app/data/flow_database.dart';
import 'package:akis_app/main.dart';

void main() {
  setUpAll(() async {
    await FlowDatabase.instance.open(inMemory: true);
  });

  setUp(() async {
    await FlowDatabase.instance.clear();
  });

  testWidgets('Akış ana deneyimi görünür', (WidgetTester tester) async {
    await tester.pumpWidget(const AkisApp());
    await tester.pumpAndSettle();

    expect(find.text('Aklından düşenleri ben tutarım.'), findsOneWidget);
    expect(find.text('Açık döngülerin'), findsOneWidget);
    expect(find.text('0 bekleyen şey'), findsOneWidget);
  });

  testWidgets('metinden onaylı aksiyon kartı oluşturur', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const AkisApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Yarın Ece’yi ara');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Akış bunu hatırlasın mı?'), findsOneWidget);
    final applyButton = find.widgetWithText(FilledButton, 'Hafızaya al');
    await tester.ensureVisible(applyButton);
    await tester.tap(applyButton);
    await tester.pump();

    expect(find.text('Ece’yi ara'), findsOneWidget);
  });
}
