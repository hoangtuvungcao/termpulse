import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const qaOnboardingCaptureKey = Key('qaOnboardingCapture');
const _captureEnabled = bool.fromEnvironment('QA_CAPTURE_ONBOARDING');
const _captureFontPath = String.fromEnvironment('QA_CAPTURE_FONT_PATH');

/// Optional host-only visual QA with fake data; normal test runs do no I/O.
Future<void> loadQaOnboardingFonts() async {
  if (!_captureEnabled) return;
  if (_captureFontPath.isEmpty) {
    throw StateError('Set QA_CAPTURE_FONT_PATH to a Roboto Regular font file.');
  }
  final fontBytes = await File(_captureFontPath).readAsBytes();
  final textFont = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(fontBytes)));
  final iconFont = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([textFont.load(), iconFont.load()]);
}

/// Restores Android's implicit font for styles using the host test fallback.
ThemeData qaOnboardingTheme(ThemeData theme) {
  if (!_captureEnabled) return theme;
  ButtonStyle useAndroidFont(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => (style?.textStyle?.resolve(states) ?? const TextStyle())
              .copyWith(fontFamily: 'Roboto'),
        ),
      );
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: useAndroidFont(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: useAndroidFont(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: useAndroidFont(theme.textButtonTheme.style),
    ),
  );
}

Future<void> captureOnboarding(WidgetTester tester, String name) async {
  if (!_captureEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(qaOnboardingCaptureKey),
  );
  await tester.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding failed.');
      final output = Directory('build/qa_onboarding');
      await output.create(recursive: true);
      await File('${output.path}/$name.png').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      picture.dispose();
    }
  });
}
