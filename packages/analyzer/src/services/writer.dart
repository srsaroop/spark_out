// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library source_writer;



class Line {

  final tokens = <LineToken>[];
  final bool useTabs;
  final int spacesPerIndent;
  final int indent;
  final LinePrinter printer;

  Line({this.indent: 0, this.useTabs: false, this.spacesPerIndent: 2,
      this.printer: const SimpleLinePrinter()}) {
    if (indent > 0) {
      _indent(indent);
    }
  }

  void addSpace() {
    addSpaces(1);
  }

  void addSpaces(int n, {breakWeight: DEFAULT_SPACE_WEIGHT}) {
    if (n > 0) {
      tokens.add(new SpaceToken(n, breakWeight: breakWeight));
    }
  }

  void addToken(LineToken token) {
    tokens.add(token);
  }

  bool isWhitespace() => tokens.every((tok) => tok is SpaceToken);

  void _indent(int n) {
    tokens.add(useTabs ? new TabToken(n) : new SpaceToken(n * spacesPerIndent));
  }

  String toString() => printer.printLine(this);

}


/// Base class for line printers
abstract class LinePrinter {

  const LinePrinter();

  /// Convert this [line] to a [String] representation.
  String printLine(Line line);
}


typedef String Indenter(int n);


/// A simple line breaking [LinePrinter]
class SimpleLineBreaker extends LinePrinter {

  static final NO_OP_INDENTER = (n) => '';

  final chunks = <Chunk>[];
  final int maxLength;
  Indenter indenter;

  SimpleLineBreaker(this.maxLength, [this.indenter]) {
    if (indenter == null) {
      indenter = NO_OP_INDENTER;
    }
  }

  String printLine(Line line) {
    var buf = new StringBuffer();
    var chunks = breakLine(line);
    for (var i = 0; i < chunks.length; ++i) {
      if (i > 0) {
        buf.write(indent(chunks[i], line.indent));
      } else {
        buf.write(chunks[i]);
      }
    }
    return buf.toString();
  }

  String indent(Chunk chunk, int level) =>
      '\n' + indenter(level + 2) + chunk.toString();

  List<Chunk> breakLine(Line line) {

    var tokens = preprocess(line.tokens);

    var chunks = <Chunk>[];

    // The current unbroken line
    var current = new Chunk(maxLength: maxLength);

    // A tentative working chunk that will either start a new line or get
    // absorbed into 'current'
    var work = new Chunk(maxLength: maxLength);

    tokens.forEach((tok) {

      if (goodStart(tok, work)) {
        if (current.fits(work)) {
          current.add(work);
        } else {
          if (current.length > 0) {
            chunks.add(current);
          }
          current = work;
        }
        work = new Chunk(start: tok, maxLength: maxLength - current.length);
      } else {
        if (work.fits(tok)) {
          work.add(tok);
        } else {
          if (!isAllWhitespace(work) || isLineStart(current)) {
            current.add(work);
          } else if (current.length > 0) {
            chunks.add(current);
            current = new Chunk(maxLength: maxLength);
          }
          work = new Chunk(maxLength: maxLength);
          work.add(tok);
        }
      }

    });

    current.add(work);
    if (current.length > 0) {
      chunks.add(current);
    }
    return chunks;
  }

  static List<LineToken> preprocess(List<LineToken> tok) {

    var tokens = <LineToken>[];
    var curr;

    tok.forEach((token){
      if (token is! SpaceToken) {
        if (curr == null) {
          curr = token;
        } else {
          curr = merge(curr, token);
        }
      } else {
        if (isNonbreaking(token)) {
          curr = merge(curr, token);
        } else {
          if (curr != null) {
            tokens.add(curr);
            curr = null;
          }
          tokens.add(token);
        }
      }
    });

    if (curr != null) {
      tokens.add(curr);
    }

    return tokens;
  }

  static bool isNonbreaking(SpaceToken token) =>
      token.breakWeight == UNBREAKABLE_SPACE_WEIGHT;

  static LineToken merge(LineToken first, LineToken second) =>
      new LineToken(first.value + second.value);

  bool isAllWhitespace(Chunk chunk) => isWhitespace(chunk.buffer.toString());

  bool isLineStart(chunk) => chunk.length == 0 && chunk.start == LINE_START;

  /// Test whether this token is a good start for a new working chunk
  bool goodStart(LineToken tok, Chunk workingChunk) =>
      tok is SpaceToken && tok.breakWeight >= workingChunk.start.breakWeight;

}

/// Test if this [string] contains only whitespace characters
bool isWhitespace(String string) => string.codeUnits.every(
      (c) => c == 0x09 || c == 0x20 || c == 0x0A || c == 0x0D);

/// Special token indicating a line start
final LINE_START = new SpaceToken(0);

const DEFAULT_SPACE_WEIGHT = 0;
const UNBREAKABLE_SPACE_WEIGHT = -1;

/// Simple non-breaking printer
class SimpleLinePrinter extends LinePrinter {

  const SimpleLinePrinter();

  String printLine(Line line) {
    var buffer = new StringBuffer();
    line.tokens.forEach((tok) => buffer.write(tok.toString()));
    return buffer.toString();
  }

}


/// Describes a piece of text in a [Line].
abstract class LineText {
  int get length;
  void addTo(Chunk chunk);
}


/// A working piece of text used in calculating line breaks
class Chunk implements LineText {

  final StringBuffer buffer = new StringBuffer();

  int maxLength;
  SpaceToken start;

  Chunk({this.start, this.maxLength}) {
    if (start == null) {
      start = LINE_START;
    }
  }

  bool fits(LineText text) => length + text.length < maxLength;

  int get length => start.value.length + buffer.length;

  void add(LineText text) {
    text.addTo(this);
  }

  String toString() => buffer.toString();

  void addTo(Chunk chunk) {
    chunk.buffer.write(start.value);
    chunk.buffer.write(buffer.toString());
  }
}


class LineToken implements LineText {

  final String value;

  LineToken(this.value);

  String toString() => value;

  int get length => value.length;

  void addTo(Chunk chunk) {
    chunk.buffer.write(value);
  }
}


class SpaceToken extends LineToken {

  final int breakWeight;

  SpaceToken(int n, {this.breakWeight: DEFAULT_SPACE_WEIGHT}) :
      super(getSpaces(n));
}


class TabToken extends LineToken {

  TabToken(int n) : super(getTabs(n));
}


class NewlineToken extends LineToken {

  NewlineToken(String value) : super(value);
}


class SourceWriter {

  final StringBuffer buffer = new StringBuffer();
  Line currentLine;

  final String lineSeparator;
  int indentCount = 0;

  LinePrinter linePrinter;
  LineToken _lastToken;

  SourceWriter({this.indentCount: 0, this.lineSeparator: NEW_LINE,
      bool useTabs: false, int spacesPerIndent: 2, int maxLineLength: 80}) {
    if (maxLineLength > 0) {
      linePrinter = new SimpleLineBreaker(maxLineLength, (n) =>
          getIndentString(n, useTabs: useTabs, spacesPerIndent: spacesPerIndent));
    } else {
      linePrinter = new SimpleLinePrinter();
    }
    currentLine = new Line(indent: indentCount, printer: linePrinter);
  }

  LineToken get lastToken => _lastToken;

  _addToken(LineToken token) {
    _lastToken = token;
    currentLine.addToken(token);
  }

  void indent() {
    ++indentCount;
  }

  void newline() {
    if (currentLine.isWhitespace()) {
      currentLine.tokens.clear();
    }
    _addToken(new NewlineToken(this.lineSeparator));
    buffer.write(currentLine.toString());
    currentLine = new Line(indent: indentCount, printer: linePrinter);
  }

  void newlines(int num) {
    while (num-- > 0) {
      newline();
    }
  }

  void print(x) {
    _addToken(new LineToken(x));
  }

  void println(String s) {
    print(s);
    newline();
  }

  void space() {
    spaces(1);
  }

  void spaces(n, {breakWeight: DEFAULT_SPACE_WEIGHT}) {
    currentLine.addSpaces(n, breakWeight: breakWeight);
  }

  void unindent() {
    --indentCount;
  }

  String toString() {
    var source = new StringBuffer(buffer.toString());
    if (!currentLine.isWhitespace()) {
      source.write(currentLine);
    }
    return source.toString();
  }

}

const NEW_LINE = '\n';
const SPACE = ' ';
const SPACES = const [
          '',
          ' ',
          '  ',
          '   ',
          '    ',
          '     ',
          '      ',
          '       ',
          '        ',
          '         ',
          '          ',
          '           ',
          '            ',
          '             ',
          '              ',
          '               ',
          '                ',
];
const TABS = const [
          '',
          '\t',
          '\t\t',
          '\t\t\t',
          '\t\t\t\t',
          '\t\t\t\t\t',
          '\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t\t\t\t\t',
          '\t\t\t\t\t\t\t\t\t\t\t\t\t\t',
];


String getIndentString(int indentWidth, {bool useTabs: false,
  int spacesPerIndent: 2}) => useTabs ? getTabs(indentWidth) :
    getSpaces(indentWidth * spacesPerIndent);

String getSpaces(int n) => n < SPACES.length ? SPACES[n] : repeat(' ', n);

String getTabs(int n) => n < TABS.length ? TABS[n] : repeat('\t', n);

String repeat(String ch, int times) {
  var sb = new StringBuffer();
  for (var i = 0; i < times; ++i) {
    sb.write(ch);
  }
  return sb.toString();
}
