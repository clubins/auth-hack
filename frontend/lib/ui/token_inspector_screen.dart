import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import 'jwt.dart';
import 'widgets.dart';

/// Read-only spike evidence: the live access token, the Authorization
/// header it produces, and its decoded JOSE header and payload claims.
///
/// Decoding is display-only — signature and claim verification happen on
/// the API, never here.
class TokenInspectorScreen extends StatefulWidget {
  const TokenInspectorScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<TokenInspectorScreen> createState() => _TokenInspectorScreenState();
}

enum _TokenPhase { loading, ready, error }

class _TokenInspectorScreenState extends State<TokenInspectorScreen> {
  _TokenPhase _phase = _TokenPhase.loading;
  String _token = '';
  DecodedJwt? _decoded;
  String? _decodeProblem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _TokenPhase.loading);
    try {
      final token = await widget.authService.freshAccessToken();
      if (!mounted) {
        return;
      }
      if (token == null) {
        setState(() {
          _decodeProblem =
              'No access token available — sign in and try again.';
          _phase = _TokenPhase.error;
        });
        return;
      }
      try {
        final decoded = decodeJwt(token);
        setState(() {
          _token = token;
          _decoded = decoded;
          _phase = _TokenPhase.ready;
        });
      } on FormatException catch (e) {
        setState(() {
          _decodeProblem = e.message;
          _phase = _TokenPhase.error;
        });
      }
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _decodeProblem = e.message;
        _phase = _TokenPhase.error;
      });
    }
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      showSnackBar(context, '$label copied to clipboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Token inspector')),
      body: switch (_phase) {
        _TokenPhase.loading => const LoadingView(label: 'Reading token…'),
        _TokenPhase.error => ErrorRetryView(
            title: 'Token unavailable',
            message: _decodeProblem!,
            onRetry: _load,
          ),
        _TokenPhase.ready => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Section(
                title: 'Access token',
                copyKey: const Key('copy-access-token'),
                onCopy: () => _copy(_token, 'Access token'),
                child: SelectableText(
                  _token,
                  key: const Key('inspector-raw-token'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              _Section(
                title: 'Authorization header',
                copyKey: const Key('copy-authorization-header'),
                onCopy: () => _copy('Bearer $_token', 'Authorization header'),
                child: SelectableText(
                  'Authorization: Bearer $_token',
                  key: const Key('inspector-authorization-header'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              _Section(
                title: 'Header claims (JOSE)',
                onCopy: () =>
                    _copy(prettyJson(_decoded!.header), 'Header claims'),
                child: SelectableText(
                  prettyJson(_decoded!.header),
                  key: const Key('inspector-header-claims'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              _Section(
                title: 'Payload claims',
                onCopy: () =>
                    _copy(prettyJson(_decoded!.payload), 'Payload claims'),
                child: SelectableText(
                  prettyJson(_decoded!.payload),
                  key: const Key('inspector-payload-claims'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Decoded for inspection only — every request is verified '
                'server-side (signature, issuer, expiry, audience).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
      },
    );
  }
}

/// A titled, carded inspector section with a copy affordance.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    required this.onCopy,
    this.copyKey,
  });

  final String title;
  final Widget child;
  final VoidCallback onCopy;

  /// Test hook distinguishing this section's copy button — four
  /// otherwise-identical buttons live on this screen.
  final Key? copyKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  key: copyKey,
                  tooltip: 'Copy',
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
