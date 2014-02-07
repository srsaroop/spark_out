// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark.analyzer_test;

import 'package:unittest/unittest.dart';

import '../lib/analyzer.dart';
import '../lib/utils.dart';

defineTests() {
  group('analyzer.', () {
    test('ChromeDartSdk exists', () {
      return createSdk().then((ChromeDartSdk sdk) {
        expect(sdk, isNotNull);
        expect(sdk.sdkVersion.length, greaterThan(0));

        // expect some libraries
        expect(sdk.sdkLibraries.length, greaterThan(10));

        // expect some uris
        expect(sdk.uris.length, greaterThan(10));

        expect(sdk.getSdkLibrary('dart:core'), isNotNull);
        expect(sdk.getSdkLibrary('dart:html'), isNotNull);

        // TODO: test fromEncoding

        // TODO: test mapDartUri

      });
    });

    test('analyze string, no resolution', () {
      return createSdk().then((ChromeDartSdk sdk) {
        return analyzeString(sdk, "void main() {\n print('hello world');\n}",
            performResolution: false).then((AnalyzerResult result) {
          expect(result, isNotNull);
          expect(result.ast, isNotNull);
          expect(result.ast.declarations.length, 1);
          CompilationUnitMember decl = result.ast.declarations.first;
          expect(decl, new isInstanceOf<FunctionDeclaration>('FunctionDeclaration'));
          expect((decl as FunctionDeclaration).name.name, 'main');
          expect(result.errors, isEmpty);
        });
      });
    });

    test('analyze string, no resolution, syntax errors', () {
      return createSdk().then((ChromeDartSdk sdk) {
        return analyzeString(sdk, "void main() {\n print('hello world') \n}",
            performResolution: false).then((AnalyzerResult result) {
          expect(result.ast.declarations.length, 1);
          CompilationUnitMember decl = result.ast.declarations.first;
          expect(decl, new isInstanceOf<FunctionDeclaration>('FunctionDeclaration'));
          expect((decl as FunctionDeclaration).name.name, 'main');
          expect(result.errors.length, greaterThan(0));
        });
      });
    });

    test('analyze string', () {
      // TODO: this fails under dart2js
      if (isDart2js()) return null;

      return createSdk().then((ChromeDartSdk sdk) {
        return analyzeString(sdk, "void main() {\n print('hello world');\n}",
            performResolution: true).then((AnalyzerResult result) {
          expect(result, isNotNull);
          expect(result.ast, isNotNull);
          expect(result.ast.declarations.length, 1);
          CompilationUnitMember decl = result.ast.declarations.first;
          expect(decl, new isInstanceOf<FunctionDeclaration>('FunctionDeclaration'));
          expect((decl as FunctionDeclaration).name.name, 'main');
          expect(result.errors, isEmpty);
          expect((decl as FunctionDeclaration).element, isNotNull);
        });
      });
    });

    test('analyze string with errors', () {
      // TODO: this fails under dart2js
      if (isDart2js()) return null;

      return createSdk().then((ChromeDartSdk sdk) {
        return analyzeString(sdk, "void main() {\n printfoo('hello world');\n}",
            performResolution: true).then((AnalyzerResult result) {
          expect(result.ast, isNotNull);
          expect(result.ast.declarations.length, 1);
          CompilationUnitMember decl = result.ast.declarations.first;
          expect(decl, new isInstanceOf<FunctionDeclaration>('FunctionDeclaration'));
          expect((decl as FunctionDeclaration).name.name, 'main');
          expect(result.errors.length, 1);
        });
      });
    });

    test('analyze string with dart: imports', () {
      // TODO:

    });
  });
}
