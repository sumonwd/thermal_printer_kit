import 'dart:convert';

/// The SNMP v1 messages `PrinterDevices.networkName` needs: a GetRequest for
/// one object, and reading the GetResponse.
class Snmp {
  Snmp._();

  /// GetRequest for [oid] (dotted, such as `1.3.6.1.2.1.1.5.0`), with
  /// community [community].
  static List<int> getRequest(String oid, int requestId, {String community = 'public'}) =>
      _tlv(0x30, [
        ..._tlv(0x02, [0x00]), // version: SNMP v1
        ..._tlv(0x04, utf8.encode(community)),
        ..._tlv(0xA0, [
          ..._tlv(0x02, _int(requestId)),
          ..._tlv(0x02, [0x00]), // error status
          ..._tlv(0x02, [0x00]), // error index
          ..._tlv(0x30, _tlv(0x30, [..._tlv(0x06, _oid(oid)), 0x05, 0x00])), // oid = NULL
        ]),
      ]);

  /// The request id and text value of a GetResponse. The value is null when
  /// the agent reports an error (no such object) or the value isn't text.
  /// Returns null when [bytes] isn't a GetResponse.
  static (int, String?)? parseResponse(List<int> bytes) {
    try {
      final message = _Reader(bytes).read(0x30);
      message.read(0x02); // version
      message.read(0x04); // community
      final pdu = message.read(0xA2);
      final requestId = pdu.read(0x02).integer;
      final error = pdu.read(0x02).integer;
      pdu.read(0x02); // error index
      final binding = pdu.read(0x30).read(0x30);
      binding.read(0x06);
      final value = binding.next();
      if (error != 0 || value.tag != 0x04) return (requestId, null);
      return (requestId, utf8.decode(value.bytes, allowMalformed: true));
    } on FormatException {
      return null;
    }
  }

  static List<int> _tlv(int tag, List<int> value) => [tag, ..._length(value.length), ...value];

  static List<int> _length(int n) => n < 0x80
      ? [n]
      : n < 0x100
      ? [0x81, n]
      : [0x82, n >> 8, n & 0xFF];

  static List<int> _int(int v) {
    final out = <int>[v & 0xFF];
    for (v >>= 8; v > 0; v >>= 8) {
      out.insert(0, v & 0xFF);
    }
    if (out.first >= 0x80) out.insert(0, 0x00); // keep it positive
    return out;
  }

  static List<int> _oid(String oid) {
    final arcs = oid.split('.').map(int.parse).toList();
    final out = <int>[arcs[0] * 40 + arcs[1]];
    for (final arc in arcs.skip(2)) {
      final base128 = <int>[arc & 0x7F];
      for (var v = arc >> 7; v > 0; v >>= 7) {
        base128.insert(0, (v & 0x7F) | 0x80);
      }
      out.addAll(base128);
    }
    return out;
  }
}

/// Reads BER tag-length-value items one after another.
class _Reader {
  _Reader(this.bytes, [this._pos = 0, int? end]) : _end = end ?? bytes.length;

  final List<int> bytes;
  int _pos;
  final int _end;

  /// The next item, which must have [tag]; its contents are read with the
  /// returned reader.
  _Reader read(int tag) {
    final item = next();
    if (item.tag != tag) throw const FormatException('unexpected SNMP tag');
    return item.reader;
  }

  /// The next item, of any tag.
  ({int tag, List<int> bytes, _Reader reader}) next() {
    if (_pos + 2 > _end) throw const FormatException('truncated SNMP message');
    final tag = bytes[_pos++];
    var length = bytes[_pos++];
    if (length >= 0x80) {
      final count = length & 0x7F;
      if (count == 0 || count > 2 || _pos + count > _end) {
        throw const FormatException('bad SNMP length');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[_pos++];
      }
    }
    final start = _pos;
    _pos += length;
    if (_pos > _end) throw const FormatException('truncated SNMP message');
    return (tag: tag, bytes: bytes.sublist(start, _pos), reader: _Reader(bytes, start, _pos));
  }

  /// The contents as an unsigned integer.
  int get integer {
    var v = 0;
    for (var i = _pos; i < _end; i++) {
      v = (v << 8) | bytes[i];
    }
    return v;
  }
}
