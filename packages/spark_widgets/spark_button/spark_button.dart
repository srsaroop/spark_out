// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark_widgets.button;

import 'package:polymer/polymer.dart';

import '../common/spark_widget.dart';

@CustomTag('spark-button')
class SparkButton extends SparkWidget {
  @published bool primary = false;

  // TODO: changing this field does not cause the btnClasses to be re-calculated
  bool _active = true;
  @published bool get active => _active;
  set active(bool value) {
    _active = value;
    getShadowDomElement('button').className = btnClasses;
  }

  @published bool large = false;
  @published bool small = false;
  @published bool noPadding = false;

  String get actionId => attributes['action-id'];

  @observable String get btnClasses {
    List classes = [
        CSS_BUTTON,
        primary ? CSS_PRIMARY : CSS_DEFAULT,
        active ? SparkWidget.CSS_ENABLED : SparkWidget.CSS_DISABLED
    ];

    if (large) classes.add(CSS_LARGE);
    if (small) classes.add(CSS_SMALL);

    return joinClasses(classes);
  }

  static const CSS_BUTTON = "btn";
  static const CSS_DEFAULT = "btn-default";
  static const CSS_PRIMARY = "btn-primary";
  static const CSS_LARGE = "btn-lg";
  static const CSS_SMALL = "btn-sm";

  SparkButton.created() : super.created();
}
