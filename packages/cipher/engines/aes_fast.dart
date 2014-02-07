// Copyright (c) 2013, Iván Zaera Avellón - izaera@gmail.com  
// Use of this source code is governed by a LGPL v3 license. 
// See the LICENSE file for more information.

library cipher.engines.aes_fast;

import "dart:typed_data";

import "package:cipher/api.dart";
import "package:cipher/params/key_parameter.dart";
import "package:cipher/src/ufixnum.dart";

part "../src/engines/aes_fast/tables.dart";
part "../src/engines/aes_fast/functions.dart";

/**
 * An implementation of the AES (Rijndael), from FIPS-197.
 *
 * For further details see: [http://csrc.nist.gov/encryption/aes/]
 *
 * This implementation is based on optimizations from Dr. Brian Gladman's paper
 * and C code at [http://fp.gladman.plus.com/cryptography_technology/rijndael/]
 *
 * There are three levels of tradeoff of speed vs memory and they are written
 * as three separate classes from which to choose.
 *
 * The fastest uses 8Kbytes of static tables to precompute round calculations,
 * 4 256 word tables for encryption and 4 for decryption.
 *
 * The middle performance version uses only one 256 word table for each, for a
 * total of 2Kbytes, adding 12 rotate operations per round to compute the values
 * contained in the other tables from the contents of the first.
 *
 * The slowest version uses no static tables at all and computes the values in
 * each round.

 * This file contains the fast version with 8Kbytes of static tables for round
 * precomputation.
 */
class AESFastEngine implements BlockCipher {

  static const _BLOCK_SIZE = 16;

  bool _forEncryption;
  List<List<Uint32>> _workingKey;
  int _ROUNDS;
  int _C0, _C1, _C2, _C3;

  String get algorithmName => "AES";

  int get blockSize => _BLOCK_SIZE;

  void reset() {
    _ROUNDS = 0;
    _C0 = _C1 = _C2 = _C3 = 0;
    _forEncryption = false;
    _workingKey = null;
  }

  void init( bool forEncryption, KeyParameter params ) {
    var key = params.key;

    int KC = (key.lengthInBytes / 4).floor();  // key length in words
    if (((KC != 4) && (KC != 6) && (KC != 8)) || ((KC * 4) != key.lengthInBytes)) {
      throw new ArgumentError("Key length must be 128/192/256 bits");
    }

    this._forEncryption = forEncryption;
    _ROUNDS = KC + 6;  // This is not always true for the generalized Rijndael that allows larger block sizes
    _workingKey = new List.generate( _ROUNDS+1, (int i) => new List<Uint32>(4) ); // 4 words in a block 

    // Copy the key into the round key array.
    var keyView = new ByteData.view( params.key.buffer );
    for( var i=0, t=0 ; i<key.lengthInBytes ; i+=4, t++ ) {
      var value = keyView.getUint32( i, Endianness.LITTLE_ENDIAN );
      _workingKey[t>>2][t&3] = new Uint32(value); 
    }

    // While not enough round key material calculated calculate new values.
    int k = (_ROUNDS + 1) << 2;
    for( int i=KC ; i<k ; i++ ) {
      int temp = _workingKey[(i-1)>>2][(i-1)&3].toInt(); 
      if( (i%KC) == 0 ) {
        temp = _subWord( _shift(temp,8) ) ^ _rcon[((i / KC) - 1).floor()];
      } else if( (KC > 6) && ((i % KC) == 4) ) {
        temp = _subWord(temp);
      }

      var value = _workingKey[(i-KC)>>2][(i-KC)&3] ^ temp;
      _workingKey[i>>2][i&3] = value;
    }

    if( !forEncryption ) {
      for( var j=1 ; j<_ROUNDS; j++ ) {
        for( var i=0 ; i<4; i++ ) {
          var value = _inv_mcol( _workingKey[j][i].toInt() );
          _workingKey[j][i] = new Uint32(value);
        }
      }
    }
  }

  int processBlock( Uint8List inp, int inpOff, Uint8List out, int outOff ) {
    if( _workingKey == null ) {
        throw new StateError("AES engine not initialised");
    }

    if( (inpOff + (32 / 2)) > inp.lengthInBytes ) {
        throw new ArgumentError("Input buffer too short");
    }

    if( (outOff + (32 / 2)) > out.lengthInBytes ) {
        throw new ArgumentError("Output buffer too short");
    }

    if (_forEncryption) {
        _unpackBlock(inp,inpOff);
        _encryptBlock(_workingKey);
        _packBlock(out,outOff);
    } else {
        _unpackBlock(inp,inpOff);
        _decryptBlock(_workingKey);
        _packBlock(out,outOff);
    }

    return _BLOCK_SIZE;
  }

  void _encryptBlock( List<List<Uint32>> KW ) {
      int r, r0, r1, r2, r3;

      _C0 ^= KW[0][0].toInt();
      _C1 ^= KW[0][1].toInt();
      _C2 ^= KW[0][2].toInt();
      _C3 ^= KW[0][3].toInt();

      r = 1;
      while( r < _ROUNDS-1 ) {
          r0  = _T0[_C0&255] ^ _T1[(_C1>>8)&255] ^ _T2[(_C2>>16)&255] ^ _T3[(_C3>>24)&255] ^ KW[r][0].toInt();
          r1  = _T0[_C1&255] ^ _T1[(_C2>>8)&255] ^ _T2[(_C3>>16)&255] ^ _T3[(_C0>>24)&255] ^ KW[r][1].toInt();
          r2  = _T0[_C2&255] ^ _T1[(_C3>>8)&255] ^ _T2[(_C0>>16)&255] ^ _T3[(_C1>>24)&255] ^ KW[r][2].toInt();
          r3  = _T0[_C3&255] ^ _T1[(_C0>>8)&255] ^ _T2[(_C1>>16)&255] ^ _T3[(_C2>>24)&255] ^ KW[r][3].toInt();
          r++;
          _C0 = _T0[r0&255] ^ _T1[(r1>>8)&255] ^ _T2[(r2>>16)&255] ^ _T3[(r3>>24)&255] ^ KW[r][0].toInt();
          _C1 = _T0[r1&255] ^ _T1[(r2>>8)&255] ^ _T2[(r3>>16)&255] ^ _T3[(r0>>24)&255] ^ KW[r][1].toInt();
          _C2 = _T0[r2&255] ^ _T1[(r3>>8)&255] ^ _T2[(r0>>16)&255] ^ _T3[(r1>>24)&255] ^ KW[r][2].toInt();
          _C3 = _T0[r3&255] ^ _T1[(r0>>8)&255] ^ _T2[(r1>>16)&255] ^ _T3[(r2>>24)&255] ^ KW[r][3].toInt();
          r++;
      }

      r0 = _T0[_C0&255] ^ _T1[(_C1>>8)&255] ^ _T2[(_C2>>16)&255] ^ _T3[(_C3>>24)&255] ^ KW[r][0].toInt();
      r1 = _T0[_C1&255] ^ _T1[(_C2>>8)&255] ^ _T2[(_C3>>16)&255] ^ _T3[(_C0>>24)&255] ^ KW[r][1].toInt();
      r2 = _T0[_C2&255] ^ _T1[(_C3>>8)&255] ^ _T2[(_C0>>16)&255] ^ _T3[(_C1>>24)&255] ^ KW[r][2].toInt();
      r3 = _T0[_C3&255] ^ _T1[(_C0>>8)&255] ^ _T2[(_C1>>16)&255] ^ _T3[(_C2>>24)&255] ^ KW[r][3].toInt();
      r++;

      // the final round's table is a simple function of S so we don't use a whole other four tables for it
      _C0 = (_S[r0&255]&255) ^ ((_S[(r1>>8)&255]&255)<<8) ^ ((_S[(r2>>16)&255]&255)<<16) ^ (_S[(r3>>24)&255]<<24) ^ KW[r][0].toInt();
      _C1 = (_S[r1&255]&255) ^ ((_S[(r2>>8)&255]&255)<<8) ^ ((_S[(r3>>16)&255]&255)<<16) ^ (_S[(r0>>24)&255]<<24) ^ KW[r][1].toInt();
      _C2 = (_S[r2&255]&255) ^ ((_S[(r3>>8)&255]&255)<<8) ^ ((_S[(r0>>16)&255]&255)<<16) ^ (_S[(r1>>24)&255]<<24) ^ KW[r][2].toInt();
      _C3 = (_S[r3&255]&255) ^ ((_S[(r0>>8)&255]&255)<<8) ^ ((_S[(r1>>16)&255]&255)<<16) ^ (_S[(r2>>24)&255]<<24) ^ KW[r][3].toInt();
  }

  void _decryptBlock( List<List<Uint32>> KW ) {
      int r, r0, r1, r2, r3;

      _C0 ^= KW[_ROUNDS][0].toInt();
      _C1 ^= KW[_ROUNDS][1].toInt();
      _C2 ^= KW[_ROUNDS][2].toInt();
      _C3 ^= KW[_ROUNDS][3].toInt();

      r = _ROUNDS-1;
      while( r > 1 ) {
          r0 = _Tinv0[_C0&255] ^ _Tinv1[(_C3>>8)&255] ^ _Tinv2[(_C2>>16)&255] ^ _Tinv3[(_C1>>24)&255] ^ KW[r][0].toInt();
          r1 = _Tinv0[_C1&255] ^ _Tinv1[(_C0>>8)&255] ^ _Tinv2[(_C3>>16)&255] ^ _Tinv3[(_C2>>24)&255] ^ KW[r][1].toInt();
          r2 = _Tinv0[_C2&255] ^ _Tinv1[(_C1>>8)&255] ^ _Tinv2[(_C0>>16)&255] ^ _Tinv3[(_C3>>24)&255] ^ KW[r][2].toInt();
          r3 = _Tinv0[_C3&255] ^ _Tinv1[(_C2>>8)&255] ^ _Tinv2[(_C1>>16)&255] ^ _Tinv3[(_C0>>24)&255] ^ KW[r][3].toInt();
          r--;
          _C0 = _Tinv0[r0&255] ^ _Tinv1[(r3>>8)&255] ^ _Tinv2[(r2>>16)&255] ^ _Tinv3[(r1>>24)&255] ^ KW[r][0].toInt();
          _C1 = _Tinv0[r1&255] ^ _Tinv1[(r0>>8)&255] ^ _Tinv2[(r3>>16)&255] ^ _Tinv3[(r2>>24)&255] ^ KW[r][1].toInt();
          _C2 = _Tinv0[r2&255] ^ _Tinv1[(r1>>8)&255] ^ _Tinv2[(r0>>16)&255] ^ _Tinv3[(r3>>24)&255] ^ KW[r][2].toInt();
          _C3 = _Tinv0[r3&255] ^ _Tinv1[(r2>>8)&255] ^ _Tinv2[(r1>>16)&255] ^ _Tinv3[(r0>>24)&255] ^ KW[r][3].toInt();
          r--;
      }

      r0 = _Tinv0[_C0&255] ^ _Tinv1[(_C3>>8)&255] ^ _Tinv2[(_C2>>16)&255] ^ _Tinv3[(_C1>>24)&255] ^ KW[r][0].toInt();
      r1 = _Tinv0[_C1&255] ^ _Tinv1[(_C0>>8)&255] ^ _Tinv2[(_C3>>16)&255] ^ _Tinv3[(_C2>>24)&255] ^ KW[r][1].toInt();
      r2 = _Tinv0[_C2&255] ^ _Tinv1[(_C1>>8)&255] ^ _Tinv2[(_C0>>16)&255] ^ _Tinv3[(_C3>>24)&255] ^ KW[r][2].toInt();
      r3 = _Tinv0[_C3&255] ^ _Tinv1[(_C2>>8)&255] ^ _Tinv2[(_C1>>16)&255] ^ _Tinv3[(_C0>>24)&255] ^ KW[r][3].toInt();

      // the final round's table is a simple function of Si so we don't use a whole other four tables for it
      _C0 = (_Si[r0&255]&255) ^ ((_Si[(r3>>8)&255]&255)<<8) ^ ((_Si[(r2>>16)&255]&255)<<16) ^ (_Si[(r1>>24)&255]<<24) ^ KW[0][0].toInt();
      _C1 = (_Si[r1&255]&255) ^ ((_Si[(r0>>8)&255]&255)<<8) ^ ((_Si[(r3>>16)&255]&255)<<16) ^ (_Si[(r2>>24)&255]<<24) ^ KW[0][1].toInt();
      _C2 = (_Si[r2&255]&255) ^ ((_Si[(r1>>8)&255]&255)<<8) ^ ((_Si[(r0>>16)&255]&255)<<16) ^ (_Si[(r3>>24)&255]<<24) ^ KW[0][2].toInt();
      _C3 = (_Si[r3&255]&255) ^ ((_Si[(r2>>8)&255]&255)<<8) ^ ((_Si[(r1>>16)&255]&255)<<16) ^ (_Si[(r0>>24)&255]<<24) ^ KW[0][3].toInt();
  }

  void _unpackBlock( Uint8List bytes, int off ) {
    var bytesView = new ByteData.view( bytes.buffer );
    _C0 = bytesView.getUint32( off, Endianness.LITTLE_ENDIAN );
    _C1 = bytesView.getUint32( off+4, Endianness.LITTLE_ENDIAN );
    _C2 = bytesView.getUint32( off+8, Endianness.LITTLE_ENDIAN );
    _C3 = bytesView.getUint32( off+12, Endianness.LITTLE_ENDIAN );
  }

  void _packBlock( Uint8List bytes, int off ) {
    var bytesView = new ByteData.view( bytes.buffer );

    bytesView.setUint32( off, _C0, Endianness.LITTLE_ENDIAN );
    bytesView.setUint32( off+4, _C1, Endianness.LITTLE_ENDIAN );
    bytesView.setUint32( off+8, _C2, Endianness.LITTLE_ENDIAN );
    bytesView.setUint32( off+12, _C3, Endianness.LITTLE_ENDIAN );
  }

}

