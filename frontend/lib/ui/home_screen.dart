import 'package:flutter/material.dart';

import '../auth/auth.dart';
import '../api/api.dart';
import 'token_inspector_screen.dart';
import 'venue_detail_screen.dart';
import 'widgets.dart';

/// Signed-in home: the venues the user can see, fetched with the bearer
/// token. Also hosts the global actions — token inspector and sign-out.
///
/// Depends only on injected collaborators ([AuthService], [VenuesApi]) —
/// no transport or singletons, so widget tests script fakes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.authService,
    required this.venuesApi,
    required this.user,
  });

  final AuthService authService;
  final VenuesApi venuesApi;
  final AuthUser user;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _LoadPhase { loading, ready, error }

class _HomeScreenState extends State<HomeScreen> {
  _LoadPhase _phase = _LoadPhase.loading;
  List<Venue> _venues = const [];
  ApiException? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _LoadPhase.loading);
    try {
      final venues = await widget.venuesApi.listVenues();
      if (!mounted) {
        return;
      }
      setState(() {
        _venues = venues;
        _phase = _LoadPhase.ready;
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e;
        _phase = _LoadPhase.error;
      });
    }
  }

  Future<void> _signOut() async {
    try {
      await widget.authService.signOut();
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      showSnackBar(context, e.message);
    }
  }

  Future<void> _openInspector() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TokenInspectorScreen(authService: widget.authService),
      ),
    );
  }

  Future<void> _openDetail(Venue venue) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VenueDetailScreen(venuesApi: widget.venuesApi, venue: venue),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clubins venues'),
        actions: [
          IconButton(
            key: const Key('token-inspector-button'),
            tooltip: 'Token inspector',
            onPressed: _openInspector,
            icon: const Icon(Icons.key),
          ),
          IconButton(
            key: const Key('sign-out-button'),
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: switch (_phase) {
        _LoadPhase.loading => const LoadingView(label: 'Loading venues…'),
        _LoadPhase.error => ErrorRetryView(
            message: _error!.message,
            onRetry: _load,
          ),
        // RefreshIndicator needs a scrollable even when empty.
        _LoadPhase.ready => RefreshIndicator(
            onRefresh: _load,
            child: _venues.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 160),
                      EmptyView(
                        icon: Icons.storefront,
                        title: 'No venues yet',
                        subtitle:
                            'Venues you can access will appear here. '
                            'Pull down to refresh.',
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _venues.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _VenueTile(venue: _venues[index], onTap: _openDetail),
                  ),
          ),
      },
    );
  }
}

class _VenueTile extends StatelessWidget {
  const _VenueTile({required this.venue, required this.onTap});

  final Venue venue;
  final void Function(Venue) onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('venue-tile-${venue.id}'),
      leading: const Icon(Icons.place_outlined),
      title: Text(venue.name),
      subtitle: Text(venue.address),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => onTap(venue),
    );
  }
}
