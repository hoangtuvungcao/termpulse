/// Public publisher details supplied by the release owner at build time.
/// Never invent an identity or silently ship a placeholder privacy contact.
abstract final class AppLegalConfig {
  static const publisherName = String.fromEnvironment('PRIVACY_PUBLISHER_NAME');
  static const contactEmail = String.fromEnvironment('PRIVACY_CONTACT_EMAIL');
  static const privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL');
  static const policyVersion = '2026-11-27';

  static bool get isConfigured {
    final uri = Uri.tryParse(privacyPolicyUrl.trim());
    return publisherName.trim().isNotEmpty &&
        RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(contactEmail.trim()) &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }
}
