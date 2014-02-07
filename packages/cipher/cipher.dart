// Copyright (c) 2013, Iván Zaera Avellón - izaera@gmail.com  
// Use of this source code is governed by a LGPL v3 license. 
// See the LICENSE file for more information.

/**
 * This is the main entry point to the cipher library. 
 * 
 * This file includes the [cipher.api] and [cipher.impl] libraries, which 
 * comprise the whole API specification plus all the out-of-the-box 
 * implementations of algorithms.
 */
library cipher;

export "package:cipher/api.dart";
export "package:cipher/impl.dart";

export 'package:cipher/params/key_parameter.dart';
export 'package:cipher/params/parameters_with_iv.dart';
