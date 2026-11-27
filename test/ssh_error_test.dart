import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_ssh.dart';

void main() {
  test('all SSH error phases have five-language guidance and diagnostics', () {
    for (final language in AppLanguage.values) {
      for (final entry in sshErrorSources.entries) {
        final source = 'AnyhowException(${entry.key}: SSH diagnostic)';
        final message = translateAppMessage(language, source);
        expect(message, startsWith(translateAppMessage(language, entry.value)));
        expect(message, endsWith('[${entry.key}] SSH diagnostic'));
        expect(message, isNot(contains('AnyhowException')));
        if (language != AppLanguage.vi) {
          expect(message, isNot(startsWith(entry.value)));
        }
      }
    }
    for (final translations in sshTranslations.values) {
      expect(translations, hasLength(4));
      expect(translations.every((value) => value.trim().isNotEmpty), isTrue);
    }
  });

  test(
    'SSH rejection and unanswered authentication explain different causes',
    () {
      final rejected = translateAppMessage(
        AppLanguage.en,
        'SSH_AUTHENTICATION_REJECTED: server failure response',
      );
      final timeout = translateAppMessage(
        AppLanguage.en,
        'SSH_AUTHENTICATION_TIMEOUT: SSH, 15s',
      );
      expect(rejected, contains('server rejected SSH authentication'));
      expect(rejected, contains('username, password or SSH key'));
      expect(rejected.toLowerCase(), isNot(contains('timeout')));
      expect(timeout, contains('did not answer SSH authentication'));
      expect(timeout, contains('does not confirm a wrong password'));
      expect(timeout, isNot(contains('server rejected')));
    },
  );
}
