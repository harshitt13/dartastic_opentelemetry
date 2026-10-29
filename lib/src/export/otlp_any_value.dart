// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:fixnum/fixnum.dart';

import '../../proto/common/v1/common.pb.dart' as proto;

/// Encodes an API value without losing its OTLP type or collection structure.
proto.AnyValue otlpAnyValue(AnyValue value) => _encode(value, 0);

proto.AnyValue _encode(AnyValue value, int depth) {
  // Match the API conversion safeguard, including values assembled directly
  // from AnyValue collections, which bypass fromObject's depth check.
  if (depth >= 32 && value is! AnyValueNull) {
    OTelErrorHandling.report(ArgumentError(
        'AnyValue export nesting exceeds the maximum depth of 32'));
    return proto.AnyValue();
  }
  return switch (value) {
    AnyValueNull() => proto.AnyValue(),
    AnyValueString(value: final v) => proto.AnyValue(stringValue: v),
    AnyValueBool(value: final v) => proto.AnyValue(boolValue: v),
    AnyValueInt(value: final v) => proto.AnyValue(intValue: Int64(v)),
    AnyValueDouble(value: final v) => proto.AnyValue(doubleValue: v),
    AnyValueBytes(value: final v) => proto.AnyValue(bytesValue: v),
    AnyValueArray(value: final v) => proto.AnyValue(
        arrayValue: proto.ArrayValue(
            values: v.map((item) => _encode(item, depth + 1)))),
    AnyValueMap(value: final v) => proto.AnyValue(
        kvlistValue: proto.KeyValueList(
            values: v.entries.map((entry) => proto.KeyValue(
                key: entry.key, value: _encode(entry.value, depth + 1))))),
  };
}

/// Encodes every attribute, including entries containing an empty AnyValue.
List<proto.KeyValue> otlpAttributes(Attributes attributes) => attributes
    .toList()
    .map((attr) =>
        proto.KeyValue(key: attr.key, value: otlpAnyValue(attr.value)))
    .toList();
