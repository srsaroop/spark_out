part of archive;

/**
 *  File Header (512 bytes)
 *  Offst Size Field
 *      Pre-POSIX Header
 *  0     100  File name
 *  100   8    File mode
 *  108   8    Owner's numeric user ID
 *  116   8    Group's numeric user ID
 *  124   12   File size in bytes (octal basis)
 *  136   12   Last modification time in numeric Unix time format (octal)
 *  148   8    Checksum for header record
 *  156   1    Type flag
 *  157   100  Name of linked file
 *      UStar Format
 *  257   6    UStar indicator "ustar"
 *  263   2    UStar version "00"
 *  265   32   Owner user name
 *  297   32   Owner group name
 *  329   8    Device major number
 *  337   8    Device minor number
 *  345   155  Filename prefix
 */

class TarFile {
  static const String TYPE_NORMAL_FILE = '0';
  static const String TYPE_HARD_LINK = '1';
  static const String TYPE_SYMBOLIC_LINK = '2';
  static const String TYPE_DIRECTORY = '5';

  // Pre-POSIX Format
  String filename; // 100 bytes
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int fileSize = 0; // 12 bytes
  int lastModTime = 0; // 12 bytes
  int checksum = 0; // 8 bytes
  String typeFlag = '0'; // 1 byte
  String nameOfLinkedFile; // 100 bytes
  // UStar Format
  String ustarIndicator = ''; // 6 bytes (ustar)
  String ustarVersion = ''; // 2 bytes (00)
  String ownerUserName = ''; // 32 bytes
  String ownerGroupName = ''; // 32 bytes
  int deviceMajorNumber = 0; // 8 bytes
  int deviceMinorNumber = 0; // 8 bytes
  String filenamePrefix = ''; // 155 bytes
  List<int> content;

  TarFile([InputBuffer input]) {
    if (input != null) {
      InputBuffer header = new InputBuffer(input.readBytes(512));

      // The name, linkname, magic, uname, and gname are null-terminated
      // character strings. All other fields are zero-filled octal numbers in
      // ASCII. Each numeric field of width w contains w minus 1 digits, and a
      // null.
      filename = _parseString(header, 100);
      mode = _parseInt(header, 8);
      ownerId = _parseInt(header, 8);
      groupId = _parseInt(header, 8);
      fileSize = _parseInt(header, 12);
      lastModTime = _parseInt(header, 12);
      checksum = _parseInt(header, 8);
      typeFlag = _parseString(header, 1);
      nameOfLinkedFile = _parseString(header, 100);

      ustarIndicator = _parseString(header, 6);
      if (ustarIndicator == 'ustar') {
        ustarVersion = _parseString(header, 2);
        ownerUserName = _parseString(header, 32);
        ownerGroupName = _parseString(header, 32);
        deviceMajorNumber = _parseInt(header, 8);
        deviceMinorNumber = _parseInt(header, 8);
      }

      content = input.readBytes(fileSize);

      if (isFile && fileSize > 0) {
        int remainder = fileSize % 512;
        int skiplen = 0;
        if (remainder != 0) {
          skiplen = 512 - remainder;
          input.skip(skiplen);
        }
      }
    }
  }

  bool get isFile => typeFlag != TYPE_DIRECTORY;

  String toString() => '[${filename}, ${mode}, ${fileSize}]';

  void write(OutputBuffer output) {
    fileSize = content.length;

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a null.
    OutputBuffer header = new OutputBuffer();
    _writeString(header, filename, 100);
    _writeInt(header, mode, 8);
    _writeInt(header, ownerId, 8);
    _writeInt(header, groupId, 8);
    _writeInt(header, fileSize, 12);
    _writeInt(header, lastModTime, 12);
    _writeString(header, '        ', 8); // checksum placeholder
    _writeString(header, typeFlag, 1);

    int remainder = 512 - header.length;
    var nulls = new Data.Uint8List(remainder); // typed arrays default to 0.
    header.writeBytes(nulls);

    List<int> headerBytes = header.getBytes();

    // The checksum is calculated by taking the sum of the unsigned byte values
    // of the header record with the eight checksum bytes taken to be ascii
    // spaces (decimal value 32). It is stored as a six digit octal number
    // with leading zeroes followed by a NUL and then a space.
    int sum = 0;
    for (int b in headerBytes) {
      sum += b;
    }

    String sum_str = sum.toRadixString(8); // octal basis
    while (sum_str.length < 6) {
      sum_str = '0' + sum_str;
    }

    int checksum_index = 148; // checksum is at 148th byte
    for (int i = 0; i < 6; ++i) {
      headerBytes[checksum_index++] = sum_str.codeUnits[i];
    }
    headerBytes[154] = 0;
    headerBytes[155] = 32;


    output.writeBytes(header.getBytes());

    output.writeBytes(content);

    if (isFile && fileSize > 0) {
      // Padd to 512-byte boundary
      int remainder = fileSize % 512;
      if (remainder != 0) {
        int skiplen = 512 - remainder;
        nulls = new Data.Uint8List(skiplen); // typed arrays default to 0.
        output.writeBytes(nulls);
      }
    }
  }

  int _parseInt(InputBuffer input, int numBytes) {
    String s = _parseString(input, numBytes);
    if (s.isEmpty) {
      return 0;
    }
    int x = int.parse(s, radix: 8);
    return x;
  }

  String _parseString(InputBuffer input, int numBytes) {
    List<int> codes = input.readBytes(numBytes);
    int r = codes.indexOf(0);
    List<int> s = codes.sublist(0, r < 0 ? null : r);
    return new String.fromCharCodes(s).trim();
  }

  void _writeString(OutputBuffer output, String value, int numBytes) {
    List<int> codes = new List<int>.filled(numBytes, 0);
    int end = numBytes < value.length ? numBytes : value.length;
    codes.setRange(0, end, value.codeUnits);
    output.writeBytes(codes);
  }

  void _writeInt(OutputBuffer output, int value, int numBytes) {
    String s = value.toRadixString(8);
    while (s.length < numBytes - 1) {
      s = '0' + s;
    }
    _writeString(output, s, numBytes);
  }
}
