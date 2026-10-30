import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import 'format.dart';
import 'widgets.dart';

/// Owner-facing share-access screen for one venue: open a bounded
/// read-only window (server bounds: 8–24h, default 8h) and hand the
/// returned grant token to the renter out of band — the token is the
/// share mechanism, delivered exactly once by the create response. The
/// grants list below revokes early.
///
/// All transport goes through the injected [VenuesApi].
class ShareAccessScreen extends StatefulWidget {
  const ShareAccessScreen({super.key, required this.venuesApi, required this.venue});

  final VenuesApi venuesApi;
  final Venue venue;

  @override
  State<ShareAccessScreen> createState() => _ShareAccessScreenState();
}

enum _GrantsPhase { loading, ready, error }

class _ShareAccessScreenState extends State<ShareAccessScreen> {
  int _hours = defaultGrantHours;
  bool _sending = false;
  VenueGrant? _createdGrant;

  _GrantsPhase _grantsPhase = _GrantsPhase.loading;
  List<VenueGrant> _grants = const [];
  ApiException? _grantsError;
  final Set<String> _revoking = {};

  @override
  void initState() {
    super.initState();
    _loadGrants();
  }

  Future<void> _loadGrants() async {
    setState(() => _grantsPhase = _GrantsPhase.loading);
    try {
      final grants = await widget.venuesApi.listGrants(widget.venue.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _grants = grants;
        _grantsPhase = _GrantsPhase.ready;
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _grantsError = e;
        _grantsPhase = _GrantsPhase.error;
      });
    }
  }

  Future<void> _createGrant() async {
    setState(() => _sending = true);
    try {
      final grant = await widget.venuesApi.createGrant(
        widget.venue.id,
        hours: _hours,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _createdGrant = grant;
        _hours = defaultGrantHours;
      });
      await _loadGrants();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      showSnackBar(context, e.message);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _revoke(VenueGrant grant) async {
    setState(() => _revoking.add(grant.id));
    try {
      await widget.venuesApi.revokeGrant(grant.id);
      await _loadGrants();
    } on ApiException catch (e) {
      if (mounted) {
        showSnackBar(context, e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _revoking.remove(grant.id));
      }
    }
  }

  Future<void> _copyCreatedToken() async {
    final token = _createdGrant?.token;
    if (token == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) {
      showSnackBar(context, 'Grant token copied to clipboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Share "${widget.venue.name}"')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Grant read access', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _WindowPicker(
            hours: _hours,
            sending: _sending,
            onHoursChanged: (hours) => setState(() => _hours = hours),
            onSubmit: _createGrant,
          ),
          if (_createdGrant != null) ...[
            const SizedBox(height: 16),
            _CreatedGrantCard(
              grant: _createdGrant!,
              onCopy: _copyCreatedToken,
            ),
          ],
          const SizedBox(height: 24),
          Text('Existing grants', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 280,
            child: switch (_grantsPhase) {
              _GrantsPhase.loading =>
                const LoadingView(label: 'Loading grants…'),
              _GrantsPhase.error => ErrorRetryView(
                  message: _grantsError!.message,
                  onRetry: _loadGrants,
                ),
              _GrantsPhase.ready when _grants.isEmpty => const EmptyView(
                  icon: Icons.group_off,
                  title: 'No grants yet',
                  subtitle:
                      'Create an access window above and hand the token '
                      'to your renter — it grants read-only access '
                      'until it expires.',
                ),
              _GrantsPhase.ready => ListView.separated(
                  itemCount: _grants.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _buildGrantTile(context, _grants[index]),
                ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGrantTile(BuildContext context, VenueGrant grant) {
    return ListTile(
      key: Key('grant-tile-${grant.id}'),
      leading: const Icon(Icons.badge_outlined),
      title: Text(grant.subject),
      subtitle: Text(
        'Expires ${formatTimestamp(grant.expiresAt)}',
      ),
      trailing: grant.isRevoked
          ? const Tooltip(
              message: 'Revoked',
              child: Icon(Icons.block, size: 20),
            )
          : _revoking.contains(grant.id)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  key: Key('revoke-grant-${grant.id}'),
                  tooltip: 'Revoke',
                  onPressed: () => _revoke(grant),
                  icon: const Icon(Icons.delete_outline),
                ),
    );
  }
}

/// The one-step window picker: an 8–24h slider plus the create action.
/// The picker is bounded — it cannot produce a request the server would
/// reject with 422.
class _WindowPicker extends StatelessWidget {
  const _WindowPicker({
    required this.hours,
    required this.sending,
    required this.onHoursChanged,
    required this.onSubmit,
  });

  final int hours;
  final bool sending;
  final ValueChanged<int> onHoursChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Access window: $hours h'),
        Slider(
          key: const Key('grant-window-slider'),
          value: hours.toDouble(),
          min: minGrantHours.toDouble(),
          max: maxGrantHours.toDouble(),
          divisions: maxGrantHours - minGrantHours,
          label: '$hours h',
          onChanged: sending ? null : (value) => onHoursChanged(value.round()),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('create-grant-button'),
            onPressed: sending ? null : onSubmit,
            icon: const Icon(Icons.key),
            label: Text(sending ? 'Creating…' : 'Create access window'),
          ),
        ),
      ],
    );
  }
}

/// The just-created grant: the token is shown once, with a copy
/// affordance, so the owner can hand it to the renter out of band.
class _CreatedGrantCard extends StatelessWidget {
  const _CreatedGrantCard({required this.grant, required this.onCopy});

  final VenueGrant grant;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final token = grant.token;
    if (token == null) {
      // Unreachable against the real API (the create-201 body always
      // carries the token); absent is rendered as absent, never as a
      // blank row.
      return const SizedBox.shrink();
    }
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Grant created — share this token',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SelectableText(
              token,
              key: const Key('created-grant-token'),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('copy-grant-token-button'),
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy token'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
