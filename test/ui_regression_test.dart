import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _captureEnabled = bool.fromEnvironment('CAPTURE_UI');

File _captureTextFont() {
  const configuredPath = String.fromEnvironment('CAPTURE_UI_FONT_PATH');
  if (configuredPath.isNotEmpty) return File(configuredPath);

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final font = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    );
    if (font.existsSync()) return font;
  }

  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final font = File(
      '${directory.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    );
    if (font.existsSync()) return font;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'Set CAPTURE_UI_FONT_PATH to a Roboto Regular font file for visual QA.',
  );
}

Future<void> _loadCaptureFonts() async {
  if (!_captureEnabled) return;
  final fontBytes = await _captureTextFont().readAsBytes();
  final fontData = ByteData.sublistView(fontBytes);
  final textFont = FontLoader('Roboto')..addFont(Future.value(fontData));
  final iconFont = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  final terminalFont = FontLoader('monospace');
  for (final fileName in [
    'DejaVuSansMono.ttf',
    'DejaVuSansMono-Bold.ttf',
    'DejaVuSansMono-Oblique.ttf',
    'DejaVuSansMono-BoldOblique.ttf',
  ]) {
    terminalFont.addFont(rootBundle.load('assets/fonts/$fileName'));
  }
  await Future.wait([textFont.load(), iconFont.load(), terminalFont.load()]);
}

class _MemorySettings extends SettingsController {
  final AppThemePreset preset;
  _MemorySettings(this.preset);

  @override
  AppSettingsState build() => AppSettingsState(themePreset: preset);

  @override
  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
  }

  @override
  void setTerminalFontSize(double size) {
    state = state.copyWith(terminalFontSize: size);
  }
}

Future<ProviderContainer> _openWorkspace(
  WidgetTester tester,
  FakeCoreBackend backend,
  Size size, {
  AppThemePreset preset = AppThemePreset.dark,
  GlobalKey? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(() => _MemorySettings(preset)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(vaultProvider.notifier).unlock('test-only-password');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: captureKey, child: const TermPulseApp()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_captureEnabled) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // The test engine uses Ahem for unnamed font families, including standalone
  // RichText and button styles. Supply Android's fallback only while capturing;
  // existing font sizes, weights, monospace and icon families remain intact.
  void applyDefaultFont(RenderObject object) {
    if (object is RenderParagraph) {
      object.text = TextSpan(
        style: const TextStyle(fontFamily: 'Roboto'),
        children: [object.text],
      );
    }
    object.visitChildren(applyDefaultFont);
  }

  applyDefaultFont(boundary);
  await tester.pump();
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('../screenshots/review');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void _typeTerminal(WidgetTester tester, String text) {
  final existing = tester.testTextInput.editingState?['text'] as String? ?? '';
  final value = '$existing$text';
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadCaptureFonts);

  for (final preset in AppThemePreset.values) {
    test('Readable text and controls in ${preset.name} theme', () {
      final palette = paletteFor(preset);
      double contrast(Color a, Color b) {
        final first = a.computeLuminance();
        final second = b.computeLuminance();
        return (first > second ? first + 0.05 : second + 0.05) /
            (first > second ? second + 0.05 : first + 0.05);
      }

      for (final background in [
        palette.bg,
        palette.surface,
        palette.surface2,
      ]) {
        expect(contrast(palette.ink, background), greaterThanOrEqualTo(4.5));
        expect(contrast(palette.muted, background), greaterThanOrEqualTo(4.5));
      }
      expect(
        contrast(palette.accent, palette.accentInk),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(
          palette.terminalTheme.foreground,
          palette.terminalTheme.background,
        ),
        greaterThanOrEqualTo(4.5),
      );
      if (preset == AppThemePreset.light) {
        final terminal = palette.terminalTheme;
        for (final color in [
          terminal.black,
          terminal.red,
          terminal.green,
          terminal.yellow,
          terminal.blue,
          terminal.magenta,
          terminal.cyan,
          terminal.white,
          terminal.brightBlack,
          terminal.brightRed,
          terminal.brightGreen,
          terminal.brightYellow,
          terminal.brightBlue,
          terminal.brightMagenta,
          terminal.brightCyan,
          terminal.brightWhite,
        ]) {
          expect(
            contrast(color, terminal.background),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    });

    for (final size in [
      const Size(360, 740),
      const Size(412, 915),
      const Size(768, 1024),
      const Size(900, 680),
      const Size(1280, 820),
    ]) {
      testWidgets(
        '${preset.name} workspace fits ${size.width.toInt()}px and accepts terminal input',
        (tester) async {
          final fake = FakeCoreBackend();
          final key = GlobalKey();
          final container = await _openWorkspace(
            tester,
            fake,
            size,
            preset: preset,
            captureKey: key,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('prod-api-01').first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(TerminalView).first);
          await tester.pump();
          expect(tester.testTextInput.hasAnyClients, isTrue);
          _typeTerminal(tester, 'pwd');
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(fake.sentInputs.join(), contains('pwd\r'));
          expect(
            container.read(sessionManagerProvider).activeTab!.closed,
            isFalse,
          );
          if (size.width == 412 || size.width == 1280) {
            await _capture(
              tester,
              key,
              '${preset.name}_${size.width.toInt()}_terminal',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    }
  }

  testWidgets(
    'Mobile sticky Ctrl applies to soft keyboard and resets after one input',
    (tester) async {
      final fake = FakeCoreBackend();
      final container = await _openWorkspace(
        tester,
        fake,
        const Size(412, 740),
      );
      await tester.tap(find.text('prod-api-01'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stickyCtrlBtn')));
      await tester.pump();
      _typeTerminal(tester, 'c');
      await tester.pumpAndSettle();
      expect(fake.sentInputs, contains('\x03'));
      expect(
        container.read(sessionManagerProvider).activeTab!.inputCtrl,
        isFalse,
      );
      _typeTerminal(tester, 'x');
      await tester.pumpAndSettle();
      expect(fake.sentInputs, contains('x'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    },
  );

  testWidgets(
    'Mobile terminal sheet handles keyboard and landscape without overflow',
    (tester) async {
      await _openWorkspace(tester, FakeCoreBackend(), const Size(412, 740));
      await tester.tap(find.text('prod-api-01'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobileBottomSheetBtn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobileBottomSheet')), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    },
  );

  testWidgets('Mobile host home fits narrow screen after opening a session', (
    tester,
  ) async {
    await _openWorkspace(tester, FakeCoreBackend(), const Size(360, 740));
    await tester.tap(find.text('prod-api-01').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobileMoreMenu')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('Short desktop keeps welcome and connected workspace usable', (
    tester,
  ) async {
    final container = await _openWorkspace(
      tester,
      FakeCoreBackend(),
      const Size(1280, 360),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('dev-box').first);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.takeException(), isNull);
    container.read(sessionManagerProvider.notifier).toggleBroadcast();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('broadcastSafetyBanner')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'Compose can be hidden without snippets and direct input remains available',
    (tester) async {
      final fake = FakeCoreBackend()..snippets.clear();
      await _openWorkspace(tester, fake, const Size(1280, 820));
      await tester.tap(find.text('dev-box'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toggleComposeButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composePaneField')), findsNothing);
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      _typeTerminal(tester, 'ls');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fake.sentInputs.join(), contains('ls\r'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    },
  );
}
