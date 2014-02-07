// Copyright (c) 2013, Iván Zaera Avellón - izaera@gmail.com
// Use of this source code is governed by a LGPL v3 license.
// See the LICENSE file for more information.

library cipher.engines.null_stream_cipher;

import "dart:typed_data";

import "package:cipher/api.dart";

/**
 * An implementation of a null [StreamCipher], that is, a cipher that does not encrypt, neither decrypt. It can be used for 
 * testing or benchmarking chaining algorithms.
 */
class NullStreamCipher implements StreamCipher {

  String get algorithmName => "Null";

  void reset() {
  }

  void init(bool forEncryption, CipherParameters params) {
  }

  void processBytes(Uint8List inp, int inpOff, int len, Uint8List out, int outOff) {
    out.setRange( outOff, outOff+len, inp.sublist(inpOff) );
  }

  int returnByte(int inp) {
    return inp;
  }

}

