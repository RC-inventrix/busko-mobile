// This is a basic Flutter widget test for the Driver Interface screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:busko_mobile/main.dart';

void main() {
  testWidgets('Driver Interface shows Go Online button initially',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DriverApp());

    expect(find.text('Driver Interface'), findsOneWidget);
    expect(find.text('Go Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Go Offline'), findsNothing);
  });
}
