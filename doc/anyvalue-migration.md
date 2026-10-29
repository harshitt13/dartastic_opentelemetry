# Migrating to API rc.5 AnyValue

The SDK now requires `dartastic_opentelemetry_api >=1.0.0-rc.5 <1.0.0-rc.6`.
This is the SDK companion to [API PR #123](https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry_api/pull/123)
and resolves [SDK issue #236](https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/236).

- Remove type arguments from `Attribute<T>` declarations. `Attribute.value`
  now holds an `AnyValue`. Use typed `Attributes` getters for primitive values,
  pattern matching for structured values, or `value.unwrap()` for plain Dart data.
- Attribute maps accept `Map<String, Object?>`. Maps, nested and mixed arrays,
  `Uint8List` bytes, and null values retain their types through export.
- `LogRecord.body` is `AnyValue?`. `logger.emit(body: ...)`, SDK record
  construction, and mutable body assignment still accept raw Dart objects.
  They convert through `APILogger.bodyToAnyValue`; already wrapped values pass
  through unchanged. A Dart null body means absent, while `AnyValueNull()` means
  an explicitly present empty value. Clones share immutable body values.
- SDK meter factories return the concrete SDK instruments, exposing their
  nullable `addWithMap` and `recordWithMap` methods. Code using API interface
  types can pass `OTel.attributesFromMap(map)` to `add` or `record`.
- OTLP/gRPC, HTTP/protobuf, and HTTP/JSON encode all AnyValue variants, including
  attributes on resources, span/log scopes, span events and links, and metric
  points and exemplars. Bytes use protobuf bytes or base64 in OTLP/JSON. Null is
  an empty OTLP AnyValue, distinct from empty arrays, maps, strings, or bytes.
- Prometheus labels use JSON for arrays and maps, base64 for bytes, and an empty
  string for null. Nested nulls remain JSON nulls and non-finite doubles become
  JSON strings inside collections.

```dart
final attributes = OTel.attributesFromMap(<String, Object?>{
  'request': {'attempts': [1, 2.5, null]},
  'optional': null,
});
final value = attributes.toMap()['request']!.value;
final plainMap = value.unwrap();

OTel.logger('example').emit(body: value, attributes: attributes);
```

`AnyValue.unwrap()` and `toJson()` return plain Dart data for in-process use.
They are not OTLP wire encoders. Use the exporters or the signal transformers
to build OTLP requests. Directly constructed AnyValue trees have the same
32-level export safeguard as API conversion; deeper values are reported through
`OTelErrorHandling` and exported as empty AnyValues.

## Validating with the adjacent API checkout

Until rc.5 is published, create an untracked `pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  dartastic_opentelemetry_api:
    path: ../dartastic_opentelemetry_api
```

Run `dart pub get`, `dart analyze`, and `./tool/test.sh`. The focused export
regressions are in `test/unit/export/any_value_export_test.dart` and use local
HTTP and gRPC receivers. Remove the override to validate the published API.
