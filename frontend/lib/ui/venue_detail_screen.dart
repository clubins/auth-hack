import 'package:flutter/material.dart';

import '../api/api.dart';
import 'format.dart';
import 'share_access_screen.dart';
import 'widgets.dart';

/// One venue's detail: identity card plus its sensor readings
/// (`GET /venues/{id}/readings`). The share action opens the owner's
/// grant screen; the server still authorizes every grant call, so a
/// non-owner simply gets the error surface.
class VenueDetailScreen extends StatefulWidget {
  const VenueDetailScreen({super.key, required this.venuesApi, required this.venue});

  final VenuesApi venuesApi;
  final Venue venue;

  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

enum _LoadPhase { loading, ready, error }

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  _LoadPhase _phase = _LoadPhase.loading;
  List<Reading> _readings = const [];
  ApiException? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _LoadPhase.loading);
    try {
      final readings = await widget.venuesApi.listReadings(widget.venue.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _readings = readings;
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

  Future<void> _openShareAccess() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShareAccessScreen(venuesApi: widget.venuesApi, venue: widget.venue),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final venue = widget.venue;
    return Scaffold(
      appBar: AppBar(
        title: Text(venue.name),
        actions: [
          IconButton(
            key: const Key('share-access-button'),
            tooltip: 'Share access',
            onPressed: _openShareAccess,
            icon: const Icon(Icons.person_add_alt_1),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(venue.name, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(venue.address),
                    const SizedBox(height: 8),
                    Text(
                      'ID ${venue.id}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Readings', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              // The phase views center themselves inside a bounded box; the
              // card above stays visible so context is never lost.
              height: 320,
              child: switch (_phase) {
                _LoadPhase.loading =>
                  const LoadingView(label: 'Loading readings…'),
                _LoadPhase.error => ErrorRetryView(
                    message: _error!.message,
                    onRetry: _load,
                  ),
                _LoadPhase.ready when _readings.isEmpty => const EmptyView(
                    icon: Icons.sensors_off,
                    title: 'No readings yet',
                    subtitle: 'Measurements appear here once sensors report.',
                  ),
                _LoadPhase.ready => ListView.separated(
                    itemCount: _readings.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final reading = _readings[index];
                      return ListTile(
                        key: Key('reading-tile-${reading.id}'),
                        leading: const Icon(Icons.device_thermostat),
                        title: Text(formatTemperature(reading.temperatureC)),
                        subtitle:
                            Text(formatTimestamp(reading.measuredAt)),
                      );
                    },
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
