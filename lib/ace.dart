// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * An entrypoint to the [ace.dart](https://github.com/rmsmith/ace.dart) package.
 */
library spark.ace;

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math' as math;

import 'package:ace/ace.dart' as ace;
import 'package:ace/proxy.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as path;

import 'editors.dart';
import 'preferences.dart';
import 'utils.dart' as utils;
import 'workspace.dart' as workspace;

export 'package:ace/ace.dart' show EditSession;

import '../packages/spark_widgets/spark_button/spark_button.dart';

class TextEditor extends Editor {
  final AceManager aceManager;
  final workspace.File file;

  StreamSubscription _aceSubscription;
  StreamController _dirtyController = new StreamController.broadcast();

  ace.EditSession _session;

  String _lastSavedHash;

  void setSession(ace.EditSession value) {
    _session = value;
    _aceSubscription = _session.onChange.listen((_) => dirty = true);
  }

  bool _dirty = false;

  TextEditor(this.aceManager, this.file);

  bool get dirty => _dirty;

  Stream get onDirtyChange => _dirtyController.stream;

  set dirty(bool value) {
    if (value != _dirty) {
      _dirty = value;
      _dirtyController.add(value);
    }
  }

  html.Element get element => aceManager.parentElement;

  void activate() {
    // TODO:

  }

  void resize() => aceManager.resize();

  void focus() => aceManager.focus();

  void fileContentsChanged() {
    if (_session != null) {
      // Check that we didn't cause this change event.
      file.getContents().then((String text) {
        String fileContentsHash = _calcMD5(text);

        if (fileContentsHash != _lastSavedHash) {
          _lastSavedHash = fileContentsHash;
          _replaceContents(text);
        }
      });
    }
  }

  Future save() {
    // We store a hash of the contents when saving. When we get a change
    // notification (in fileContentsChanged()), we compare the last write to the
    // contents on disk.
    if (_dirty) {
      String text = _session.value;
      _lastSavedHash = _calcMD5(text);
      return file.setContents(text).then((_) => dirty = false);
    } else {
      return new Future.value();
    }
  }

  /**
   * Replace the editor's contents with the given text. Make sure that we don't
   * fire a change event.
   */
  void _replaceContents(String newContents) {
    _aceSubscription.cancel();

    try {
      // Restore the cursor position and scroll location.
      int scrollTop = _session.scrollTop;
      html.Point cursorPos = null;
      if (aceManager.currentFile == file) {
        cursorPos = aceManager.cursorPosition;
      }
      _session.value = newContents;
      _session.scrollTop = scrollTop;
      if (cursorPos != null) {
        aceManager.cursorPosition = cursorPos;
      }
    } finally {
      _aceSubscription = _session.onChange.listen((_) => dirty = true);
    }
  }
}

/**
 * A wrapper around an Ace editor instance.
 */
class AceManager {
  static final KEY_BINDINGS = ace.KeyboardHandler.BINDINGS;
  // 2 light themes, 4 dark ones.
  static final THEMES = [
      'textmate', 'tomorrow',
      'tomorrow_night', 'monokai', 'idle_fingers', 'pastel_on_dark'
  ];

  /**
   * The container for the Ace editor.
   */
  final html.Element parentElement;
  final AceManagerDelegate delegate;

  ace.Editor _aceEditor;

  workspace.Marker _currentMarker;

  StreamSubscription<ace.FoldChangeEvent> _foldListenerSubscription;

  static bool get available => js.context['ace'] != null;

  StreamSubscription _markerSubscription;
  workspace.File currentFile;

  AceManager(this.parentElement, this.delegate) {
    ace.implementation = ACE_PROXY_IMPLEMENTATION;
    _aceEditor = ace.edit(parentElement);
    _aceEditor.renderer.fixedWidthGutter = true;
    _aceEditor.highlightActiveLine = false;
    _aceEditor.printMarginColumn = 80;
    //_aceEditor.setOption('scrollPastEnd', true);
    _aceEditor.readOnly = true;

    // Enable code completion.
    ace.require('ace/ext/language_tools');
    _aceEditor.setOption('enableBasicAutocompletion', true);
    _aceEditor.setOption('enableSnippets', true);

    // Fallback
    theme = THEMES[0];
  }

  bool isFileExtensionEditable(String extension) {
    if (extension.startsWith('.')) {
      extension = extension.substring(1);
    }
    return ace.Mode.extensionMap[extension] != null;
  }

  html.Element get _editorElement => parentElement.parent;

  html.Element get _minimapElement {
    List<html.Node> minimapElements =
        _editorElement.getElementsByClassName("minimap");
    if (minimapElements.length == 1) {
      return minimapElements.first;
    }

    return null;
  }

  String _formatAnnotationItemText(String text, [String type]) {
    String labelHtml = "";
    if (type != null) {
      String typeText = type.substring(0, 1).toUpperCase() + type.substring(1);
      labelHtml = "<span class=ace_gutter-tooltip-label-$type>$typeText: </span>";
    }
    return "$labelHtml$text";
  }

  void setMarkers(List<workspace.Marker> markers) {
    List<ace.Annotation> annotations = [];
    int numberLines = currentSession.screenLength;

    _recreateMiniMap();
    Map<int, ace.Annotation> annotationByRow = new Map<int, ace.Annotation>();

    for (workspace.Marker marker in markers) {
      String annotationType = _convertMarkerSeverity(marker.severity);

      // Style the marker with the annotation type.
      String markerHtml = _formatAnnotationItemText(marker.message,
          annotationType);

      // Ace uses 0-based lines.
      ace.Point charPoint = currentSession.document.indexToPosition(marker.charStart);
      int aceRow = charPoint.row;
      int aceColumn = charPoint.column;

      // If there is an existing annotation, delete it and combine into one.
      var existingAnnotation = annotationByRow[aceRow];
      if (existingAnnotation != null) {
        markerHtml = existingAnnotation.html
            + "<div class=\"ace_gutter-tooltip-divider\"></div>$markerHtml";
        annotations.remove(existingAnnotation);
      }

      ace.Annotation annotation = new ace.Annotation(
          html: markerHtml,
          row: aceRow,
          type: annotationType);
      annotations.add(annotation);
      annotationByRow[aceRow] = annotation;

      // TODO(ericarnold): This should also be based upon annotations so ace's
      //     immediate handling of deleting / adding lines gets used.
      double markerPos =
          currentSession.documentToScreenRow(marker.lineNum, aceColumn)
          / numberLines * 100.0;

      html.Element minimapMarker = new html.Element.div();
      minimapMarker.classes.add("minimap-marker ${marker.severityDescription}");
      minimapMarker.style.top = '${markerPos.toStringAsFixed(2)}%';
      minimapMarker.onClick.listen((_) => _miniMapMarkerClicked(marker));

      _minimapElement.append(minimapMarker);
    }

    currentSession.setAnnotations(annotations);
  }

  void selectNextMarker() {
    _selectMarkerFromCurrent(1);
  }

  void selectPrevMarker() {
    _selectMarkerFromCurrent(-1);
  }

  void _selectMarkerFromCurrent(int offset) {
    // TODO(ericarnold): This should be based upon the current cursor position.
    List<workspace.Marker> markers = currentFile.getMarkers();
    if (markers != null && markers.length > 0) {
      if (_currentMarker == null) {
        _selectMarker(markers[0]);
      } else {
        int markerIndex = markers.indexOf(_currentMarker);
        markerIndex += offset;
        if (markerIndex < 0) {
          markerIndex = markers.length -1;
        } else if (markerIndex >= markers.length) {
          markerIndex = 0;
        }
        _selectMarker(markers[markerIndex]);
      }
    }
  }

  void _miniMapMarkerClicked(workspace.Marker marker) {
    _selectMarker(marker);
  }

  void _selectMarker(workspace.Marker marker) {
    // TODO(ericarnold): Marker range should be selected, but we either need
    // Marker to include col info or we need a way to convert col to char-pos
    _aceEditor.gotoLine(marker.lineNum);
    _currentMarker = marker;
  }

  void _recreateMiniMap() {
    if (_editorElement == null) {
      return;
    }
    html.Element scrollbarElement =
        _editorElement.getElementsByClassName("ace_scrollbar").first;
    if (scrollbarElement.style.right != "10px") {
      scrollbarElement.style.right = "10px";
    }

    html.Element miniMap = new html.Element.div();
    miniMap.classes.add("minimap");

    if (_minimapElement != null) {
      _minimapElement.replaceWith(miniMap);
    } else {
      _editorElement.append(miniMap);
    }
  }

  /**
   * Show an overlay dialog to tell the user that a binary file cannot be
   * shown.
   *
   * TODO(dvh): move this logic to editors/editor_area.
   * See https://github.com/dart-lang/spark/issues/906
   */
  void createDialog(String filename) {
    if (_editorElement == null) {
      return;
    }
    html.Element dialog = _editorElement.querySelector('.editor-dialog');
    if (dialog != null) {
      // Dialog already exists.
      return;
    }

    dialog = new html.Element.div();
    dialog.classes.add("editor-dialog");

    // Add an overlay dialog using the template #editor-dialog.
    html.DocumentFragment template =
        (html.querySelector('#editor-dialog') as html.TemplateElement).content;
    html.DocumentFragment templateClone = template.clone(true);
    html.Element element = templateClone.querySelector('.editor-dialog');
    element.classes.remove('editor-dialog');
    dialog.append(element);

    // Set actions of the dialog.
    SparkButton button = dialog.querySelector('.view-as-text-button');
    button.onClick.listen((_) {
      dialog.classes.add("transition-hidden");
      focus();
    });
    html.Element link = dialog.querySelector('.always-view-as-text-button');
    link.onClick.listen((_) {
      dialog.classes.add("transition-hidden");
      String extention = path.extension(currentFile.name);
      delegate.setAlwaysShowAsText(extention, true);
      focus();
    });

    if (delegate.canShowFileAsText(filename)) {
      dialog.classes.add('hidden');
    }

    _editorElement.append(dialog);
  }

  void clearMarkers() => currentSession.clearAnnotations();

  String get theme => _aceEditor.theme.name;

  set theme(String value) => _aceEditor.theme = new ace.Theme.named(value);

  Future<String> getKeyBinding() {
    var handler = _aceEditor.keyBinding.keyboardHandler;
    return handler.onLoad.then((_) {
      return KEY_BINDINGS.contains(handler.name) ? handler.name : null;
    });
  }

  void setKeyBinding(String name) {
    var handler = new ace.KeyboardHandler.named(name);
    handler.onLoad.then((_) => _aceEditor.keyBinding.keyboardHandler = handler);
  }

  void focus() => _aceEditor.focus();

  void resize() => _aceEditor.resize(false);

  ace.EditSession createEditSession(String text, String fileName) {
    ace.EditSession session = ace.createEditSession(
        text, new ace.Mode.forFile(fileName));
    _applyCustomSession(session, fileName);
    return session;
  }

  void _applyCustomSession(ace.EditSession session, String fileName) {
    String extention = path.extension(fileName);
    switch (extention) {
      case '.dart':
        session.tabSize = 2;
        session.useSoftTabs = true;
        break;
      default:
        // For now, 2-space for all file types by default. This can be changed
        // in the future.
        session.tabSize = 2;
        session.useSoftTabs = true;
        break;
    }
    // Disable Ace's analysis (this shows up in JavaScript files).
    session.useWorker = false;
  }

  html.Point get cursorPosition {
    ace.Point cursorPosition = _aceEditor.cursorPosition;
    return new html.Point(cursorPosition.column, cursorPosition.row);
  }

  void set cursorPosition(html.Point position) {
    _aceEditor.navigateTo(position.y, position.x);
  }

  ace.EditSession get currentSession => _aceEditor.session;

  void switchTo(ace.EditSession session, [workspace.File file]) {
    if (_foldListenerSubscription != null) {
      _foldListenerSubscription.cancel();
      _foldListenerSubscription = null;
    }

    if (session == null) {
      _aceEditor.session = ace.createEditSession('', new ace.Mode('ace/mode/text'));
      _aceEditor.readOnly = true;
    } else {
      _aceEditor.session = session;

      if (_aceEditor.readOnly) {
        _aceEditor.readOnly = false;
      }

      _foldListenerSubscription = currentSession.onChangeFold.listen((_) {
        setMarkers(file.getMarkers());
      });

      // TODO(ericarnold): Markers aren't shown until file is edited.  Fix.
      setMarkers(file.getMarkers());
    }

    // Setup the code completion options for the current file type.
    if (file != null) {
      currentFile = file;
      _aceEditor.setOption(
          'enableBasicAutocompletion', path.extension(file.name) != '.dart');

      if (_markerSubscription == null) {
        _markerSubscription = file.workspace.onMarkerChange.listen(
            _handleMarkerChange);
      }
    }
  }

  void _handleMarkerChange(workspace.MarkerChangeEvent event) {
    if (event.hasChangesFor(currentFile)) {
      setMarkers(currentFile.getMarkers());
    }
  }

  String _convertMarkerSeverity(int markerSeverity) {
    switch (markerSeverity) {
      case workspace.Marker.SEVERITY_ERROR:
        return ace.Annotation.ERROR;
      case workspace.Marker.SEVERITY_WARNING:
        return ace.Annotation.WARNING;
      default:
        return ace.Annotation.INFO;
    }
  }
}

class ThemeManager {
  AceManager aceManager;
  PreferenceStore prefs;
  html.Element _label;

  ThemeManager(this.aceManager, this.prefs, this._label) {
    prefs.getValue('aceTheme').then((String value) {
      if (value != null) {
        aceManager.theme = value;
        _updateName(value);
      } else {
        _updateName(aceManager.theme);
      }
    });
  }

  void inc(html.Event e) {
   e.stopPropagation();
    _changeTheme(1);
  }

  void dec(html.Event e) {
    e.stopPropagation();
    _changeTheme(-1);
  }

  void _changeTheme(int direction) {
    int index = AceManager.THEMES.indexOf(aceManager.theme);
    index = (index + direction) % AceManager.THEMES.length;
    String newTheme = AceManager.THEMES[index];
    prefs.setValue('aceTheme', newTheme);
    _updateName(newTheme);
    aceManager.theme = newTheme;
  }

  void _updateName(String name) {
    _label.text = utils.toTitleCase(name.replaceAll('_', ' '));
  }
}

class KeyBindingManager {
  AceManager aceManager;
  PreferenceStore prefs;
  html.Element _label;

  KeyBindingManager(this.aceManager, this.prefs, this._label) {
    prefs.getValue('keyBinding').then((String value) {
      if (value != null) {
        aceManager.setKeyBinding(value);
      }
      _updateName(value);
    });
  }

  void inc(html.Event e) {
    e.stopPropagation();
    _changeBinding(1);
  }

  void dec(html.Event e) {
    e.stopPropagation();
    _changeBinding(-1);
  }

  void _changeBinding(int direction) {
    aceManager.getKeyBinding().then((String name) {
      int index = math.max(AceManager.KEY_BINDINGS.indexOf(name), 0);
      index = (index + direction) % AceManager.KEY_BINDINGS.length;
      String newBinding = AceManager.KEY_BINDINGS[index];
      prefs.setValue('keyBinding', newBinding);
      _updateName(newBinding);
      aceManager.setKeyBinding(newBinding);
    });
  }

  void _updateName(String name) {
    _label.text = (name == null ? 'Default' : utils.capitalize(name));
  }
}

abstract class AceManagerDelegate {
  /**
   * Mark the files with the given file extension as editable in text format.
   */
  void setAlwaysShowAsText(String extension, bool enabled);

  /**
   * Returns true if the file with the given filename can be edited as text.
   */
  bool canShowFileAsText(String filename);
}

String _calcMD5(String text) {
  crypto.MD5 md5 = new crypto.MD5();
  md5.add(text.codeUnits);
  return crypto.CryptoUtils.bytesToHex(md5.close());
}
