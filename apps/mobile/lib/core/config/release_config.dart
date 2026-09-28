/// Publisher-owned values that differ between development and store builds.
abstract final class ReleaseConfig {
  static const privacyPolicyUrl = String.fromEnvironment(
    'HERMES_PRIVACY_POLICY_URL',
    defaultValue:
        'https://github.com/TheTom/hermes-go/blob/mobile-gateway/PRIVACY.md',
  );

  /// Only expose a public HTTPS policy. A missing/invalid value remains visible
  /// in Settings as a release-preparation warning rather than opening an unsafe
  /// or placeholder URL.
  static Uri? get privacyPolicyUri => parsePrivacyPolicyUrl(privacyPolicyUrl);

  static Uri? parsePrivacyPolicyUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }
}
