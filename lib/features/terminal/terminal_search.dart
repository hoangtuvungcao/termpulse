import 'package:xterm/xterm.dart';

/// Cell coordinates are retained so wide characters and wrapped lines remain
/// selectable in the terminal rather than indexing UTF-16 as screen columns.
class TerminalSearchMatch {
  final CellOffset begin;
  final CellOffset end;

  const TerminalSearchMatch(this.begin, this.end);
}

List<TerminalSearchMatch> searchTerminalBuffer(
  Buffer buffer,
  String query, {
  bool caseSensitive = false,
  int limit = 1000,
}) {
  if (query.isEmpty || limit <= 0) return const [];
  final pattern = RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
  final results = <TerminalSearchMatch>[];
  var text = StringBuffer();
  final starts = <CellOffset>[];
  final ends = <CellOffset>[];

  void collect() {
    for (final match in pattern.allMatches(text.toString())) {
      if (results.length >= limit) break;
      results.add(
        TerminalSearchMatch(starts[match.start], ends[match.end - 1]),
      );
    }
    text = StringBuffer();
    starts.clear();
    ends.clear();
  }

  for (var y = 0; y < buffer.height; y++) {
    final line = buffer.lines[y];
    if (!line.isWrapped && starts.isNotEmpty) collect();
    if (results.length >= limit) break;
    for (var x = 0; x < line.length; x++) {
      final codePoint = line.getCodePoint(x);
      // The second cell of a wide glyph has width zero and no code point.
      if (x > 0 && line.getWidth(x - 1) == 2 && codePoint == 0) continue;
      final character = String.fromCharCode(codePoint == 0 ? 32 : codePoint);
      text.write(character);
      for (var unit = 0; unit < character.length; unit++) {
        starts.add(CellOffset(x, y));
        ends.add(CellOffset(x + (line.getWidth(x) == 2 ? 2 : 1), y));
      }
    }
  }
  if (results.length < limit && starts.isNotEmpty) collect();
  return results;
}
