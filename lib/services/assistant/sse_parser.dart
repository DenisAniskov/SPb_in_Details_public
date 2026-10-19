/// Minimal Server-Sent Events line parser.
///
/// It handles CRLF/LF normalization, multi-line `data:` fields, comments
/// (`:` keepalives) and named events. It intentionally has no knowledge of
/// the assistant payloads, so malformed JSON is rejected by the caller.
class SseFrame {
  const SseFrame({required this.event, required this.data});

  final String event;
  final String data;
}

class SseParser {
  String _buffer = '';
  String _event = 'message';
  final List<String> _data = [];

  List<SseFrame> add(String chunk) {
    _buffer += chunk;
    final frames = <SseFrame>[];
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline < 0) break;
      var line = _buffer.substring(0, newline);
      _buffer = _buffer.substring(newline + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      _consumeLine(line, frames);
    }
    return frames;
  }

  /// Flushes a final unterminated line/event, if the server omitted the last
  /// blank line. A truncated payload is still validated by the caller.
  List<SseFrame> close() {
    final frames = <SseFrame>[];
    if (_buffer.isNotEmpty) {
      var line = _buffer;
      _buffer = '';
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _consumeLine(line, frames);
    }
    _dispatch(frames);
    return frames;
  }

  void _consumeLine(String line, List<SseFrame> frames) {
    if (line.isEmpty) {
      _dispatch(frames);
      return;
    }
    if (line.startsWith(':')) return; // keepalive comment
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value.isEmpty ? 'message' : value;
      case 'data':
        _data.add(value);
      default:
        // `id` and `retry` are not used by this protocol.
        break;
    }
  }

  void _dispatch(List<SseFrame> frames) {
    if (_data.isEmpty) {
      _event = 'message';
      return;
    }
    frames.add(SseFrame(event: _event, data: _data.join('\n')));
    _event = 'message';
    _data.clear();
  }
}
