// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  late http.Client client;

  setUp(() {
    client = http.Client();
    EnvironmentService.testOverrides = {
      'OTEL_TRACES_EXPORTER': 'none',
      'OTEL_LOGS_EXPORTER': 'none',
      'OTEL_METRICS_EXPORTER': 'prometheus',
      'OTEL_EXPORTER_PROMETHEUS_HOST': '127.0.0.1',
      'OTEL_EXPORTER_PROMETHEUS_PORT': '0',
    };
  });

  tearDown(() async {
    client.close();
    await OTel.reset();
    EnvironmentService.testOverrides = null;
  });

  Future<PrometheusMetricReader> initialize() async {
    await OTel.initialize(
        serviceName: 'scrape-test', detectPlatformResources: false);
    final reader = OTel.meterProvider()
        .metricReaders
        .whereType<PrometheusMetricReader>()
        .single;
    expect(await reader.ready, isTrue);
    return reader;
  }

  Uri endpoint(PrometheusMetricReader reader, [String path = '/metrics']) =>
      Uri.parse('http://127.0.0.1:${reader.boundPort}$path');

  test('env pipeline scrapes fresh cumulative counter and histogram data',
      () async {
    final reader = await initialize();
    final meter = OTel.meter();
    final counter = meter.createCounter<int>(name: 'requests');
    final upDown = meter.createUpDownCounter<int>(name: 'active');
    final histogram = meter.createHistogram<double>(
        name: 'latency',
        advisory: const InstrumentAdvisory(explicitBucketBoundaries: [5, 10]));
    counter.add(2);
    upDown.add(3);
    upDown.add(-1);
    for (final value in [1.0, 6.0, 20.0]) {
      histogram.record(value);
    }
    final first = await client.get(endpoint(reader));
    expect(first.statusCode, 200);
    expect(
        first.headers['content-type'], contains('text/plain; version=0.0.4'));
    expect(first.body, contains('# TYPE requests_total counter'));
    expect(first.body, contains('requests_total{} 2'));
    expect(first.body, contains('# TYPE active gauge'));
    expect(first.body, contains('active{} 2'));
    expect(first.body, contains('latency_bucket{le="5"} 1'));
    expect(first.body, contains('latency_bucket{le="10"} 2'));
    expect(first.body, contains('latency_bucket{le="+Inf"} 3'));
    expect(first.body, contains('latency_count{} 3'));
    expect(first.body, contains('latency_sum{} 27.0'));
    expect(RegExp(r'^target_info\{', multiLine: true).allMatches(first.body),
        hasLength(1));
    expect(first.body, contains('service_name="scrape-test"'));
    counter.add(4);
    final second = await client.get(endpoint(reader));
    expect(second.body, contains('requests_total{} 6'));
    expect(second.body, contains('latency_count{} 3'));
  });

  test('routes, methods and Accept negotiation', () async {
    final reader = await initialize();
    expect((await client.get(endpoint(reader, '/missing'))).statusCode, 404);
    final post = await client.post(endpoint(reader));
    expect(post.statusCode, 405);
    expect(post.headers['allow'], 'GET');
    for (final header in [
      'text/plain; version=0.0.4',
      '*/*',
      'text/*',
      'application/openmetrics-text;q=1, text/plain;version=0.0.4;q=0.5',
      'text/plain;version="0.0.4";charset=utf-8;escaping=underscores',
    ]) {
      expect(
          (await client.get(endpoint(reader), headers: {'Accept': header}))
              .statusCode,
          200,
          reason: header);
    }
    for (final header in [
      'application/json',
      'text/plain;version=1.0.0',
      'text/plain;q=0, */*;q=1',
      'text/plain;q=0, text/*;version=0.0.4;q=1',
      'text/plain;charset=utf-8;q=0, text/plain;q=1',
      '*/*;q=0',
      'text/plain;q=bogus',
      'text/plain;q=2',
      'text/plain;q=NaN',
      'text/plain;escaping=values',
    ]) {
      expect(
          (await client.get(endpoint(reader), headers: {'Accept': header}))
              .statusCode,
          406,
          reason: header);
    }
  });

  test('shutdown releases port and is idempotent', () async {
    final reader = await initialize();
    final port = reader.boundPort!;
    expect(await reader.forceFlush(), isTrue);
    expect(await OTel.meterProvider().shutdown(), isTrue);
    expect(await reader.shutdown(), isTrue);
    expect(reader.boundPort, isNull);
    expect(await reader.forceFlush(), isFalse);
    final rebound = await HttpServer.bind('127.0.0.1', port);
    await rebound.close(force: true);
  });

  test('mixed exporters use independent pull and periodic readers', () async {
    EnvironmentService.testOverrides!['OTEL_METRICS_EXPORTER'] =
        'prometheus,console';
    final reader = await initialize();
    final readers = OTel.meterProvider().metricReaders;
    expect(readers, hasLength(2));
    expect(readers.whereType<PeriodicExportingMetricReader>().single.exporter,
        isA<ConsoleMetricExporter>());
    expect((await client.get(endpoint(reader))).statusCode, 200);
  });

  test('programmatic listener settings override environment', () async {
    EnvironmentService.testOverrides!['OTEL_EXPORTER_PROMETHEUS_HOST'] =
        'invalid.invalid';
    EnvironmentService.testOverrides!['OTEL_EXPORTER_PROMETHEUS_PORT'] = '9464';
    await OTel.initialize(
        prometheusHost: '127.0.0.1',
        prometheusPort: 0,
        detectPlatformResources: false);
    final reader =
        OTel.meterProvider().metricReaders.single as PrometheusMetricReader;
    expect(reader.host, '127.0.0.1');
    expect(reader.port, 0);
    expect(reader.boundPort, greaterThan(0));
  });

  test('none and disabled SDK never install a listener', () async {
    for (final values in [
      {'OTEL_METRICS_EXPORTER': 'none,prometheus'},
      {'OTEL_METRICS_EXPORTER': 'prometheus', 'OTEL_SDK_DISABLED': 'true'},
    ]) {
      EnvironmentService.testOverrides!.addAll(values);
      await OTel.initialize(detectPlatformResources: false);
      expect(OTel.meterProvider().metricReaders, isEmpty);
      await OTel.reset();
    }
  });

  test('explicit exporter wins over prometheus selection', () async {
    await OTel.initialize(
        metricExporter: ConsoleMetricExporter(),
        detectPlatformResources: false);
    final reader = OTel.meterProvider().metricReaders.single;
    expect(reader, isA<PeriodicExportingMetricReader>());
  });

  test('manual factory reader starts on registration, even during shutdown',
      () async {
    await OTel.initialize(enableMetrics: false, detectPlatformResources: false);
    final reader = OTel.prometheusMetricReader(host: '127.0.0.1', port: 0);
    expect(await reader.ready, isFalse);
    OTel.meterProvider().addMetricReader(reader);
    expect(await reader.shutdown(), isTrue);
    expect(reader.boundPort, isNull);
    expect((await reader.collect()).metrics, isEmpty);
  });

  test('bind failure is reported without throwing out of initialization',
      () async {
    final occupied = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => occupied.close(force: true));
    EnvironmentService.testOverrides!['OTEL_EXPORTER_PROMETHEUS_PORT'] =
        '${occupied.port}';
    await OTel.initialize(detectPlatformResources: false);
    final reader =
        OTel.meterProvider().metricReaders.single as PrometheusMetricReader;
    expect(await reader.ready, isFalse);
    expect(reader.boundPort, isNull);
  });

  test('concurrent scrapes return consistent cumulative snapshots', () async {
    final reader = await initialize();
    OTel.meter().createCounter<int>(name: 'parallel').add(17);
    final responses = await Future.wait(
        List.generate(8, (_) => client.get(endpoint(reader))));
    for (final response in responses) {
      expect(response.statusCode, 200);
      expect(response.body, contains('parallel_total{} 17'));
    }
  });

  test('observable callbacks execute on each scrape, not forceFlush', () async {
    final reader = await initialize();
    var observations = 0;
    OTel.meter().createObservableGauge<int>(name: 'observations', callbacks: [
      (result) => result.observe(++observations),
    ]);
    expect(observations, 0);
    await reader.forceFlush();
    expect(observations, 0);
    expect((await client.get(endpoint(reader))).body,
        contains('observations{} 1'));
    expect((await client.get(endpoint(reader))).body,
        contains('observations{} 2'));
  });

  test('manual reader defaults and argument validation', () async {
    await OTel.initialize(enableMetrics: false, detectPlatformResources: false);
    final reader = OTel.prometheusMetricReader();
    expect(reader.host, 'localhost');
    expect(reader.port, 9464);
    expect((await reader.collect()).metrics, isEmpty);
    expect(() => OTel.prometheusMetricReader(port: -1), throwsRangeError);
    expect(() => OTel.prometheusMetricReader(port: 65536), throwsRangeError);
    expect(() => OTel.prometheusMetricReader(host: ''), throwsArgumentError);
    await reader.shutdown();
    expect(() => reader.registerMeterProvider(OTel.meterProvider()),
        throwsStateError);
  });
}
