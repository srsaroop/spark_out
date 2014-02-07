part of archive;

class OutputBuffer {
  int length;
  final int byteOrder;

  /**
   * Create a byte buffer for writing.
   */
  OutputBuffer({int size: _BLOCK_SIZE, this.byteOrder: LITTLE_ENDIAN}) :
    _buffer = new Data.Uint8List(size == null ? _BLOCK_SIZE : size),
    length = 0;

  /**
   * Get the resulting bytes from the buffer.
   */
  List<int> getBytes() {
    return new Data.Uint8List.view(_buffer.buffer, 0, length);
  }

  /**
   * Clear the buffer.
   */
  void clear() {
    _buffer = new Data.Uint8List(_BLOCK_SIZE);
    length = 0;
  }

  /**
   * Write a byte to the end of the buffer.
   */
  void writeByte(int value) {
    _buffer[length++] = value & 0xff;
    if (length == _buffer.length) {
      _expandBuffer();
    }
  }

  /**
   * Write a set of bytes to the end of the buffer.
   */
  void writeBytes(List<int> bytes, [int len]) {
    if (len == null) {
      len = bytes.length;
    }
    while (length + len > _buffer.length) {
      _expandBuffer();
    }
    _buffer.setRange(length, length + len, bytes);
    length += len;
  }

  /**
   * Write a 16-bit word to the end of the buffer.
   */
  void writeUint16(int value) {
    if (byteOrder == BIG_ENDIAN) {
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  /**
   * Write a 32-bit word to the end of the buffer.
   */
  void writeUint32(int value) {
    if (byteOrder == BIG_ENDIAN) {
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  /**
   * Return the subset of the buffer in the range [start:end].
   * If [start] or [end] are < 0 then it is relative to the end of the buffer.
   * If [end] is not specified (or null), then it is the end of the buffer.
   * This is equivalent to the python list range operator.
   */
  List<int> subset(int start, [int end]) {
    if (start < 0) {
      start = (length) + start;
    }

    if (end == null) {
      end = length;
    } else if (end < 0) {
      end = length + end;
    }

    return new Data.Uint8List.view(_buffer.buffer, start, end - start);
  }

  /**
   * Grow the buffer to accomidate additional data.
   */
  void _expandBuffer() {
    Data.Uint8List newBuffer = new Data.Uint8List(_buffer.length + _BLOCK_SIZE);
    newBuffer.setRange(0, _buffer.length, _buffer);
    _buffer = newBuffer;
  }

  static const int _BLOCK_SIZE = 0x8000; // 32k block-size
  Data.Uint8List _buffer;
}
