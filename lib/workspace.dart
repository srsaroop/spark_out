// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * A resource workspace implementation.
 */
library spark.workspace;

import 'dart:async';
import 'dart:collection';
import 'dart:convert' show JSON;
import 'dart:math' as math;

import 'package:chrome/chrome_app.dart' as chrome;
import 'package:logging/logging.dart';

import 'builder.dart';
import 'jobs.dart';
import 'preferences.dart';

final Logger _logger = new Logger('spark.workspace');

final _ChromeHelper _chromeHelper = new _ChromeHelper();

/**
 * The Workspace is a top-level entity that can contain files and projects. The
 * files that it contains are loose files; they do not have parent projects.
 */
class Workspace implements Container {
  int _resourcePauseCount = 0;
  List<ChangeDelta> _resourceChangeList = [];

  int _markersPauseCount = 0;
  List<MarkerDelta> _makerChangeList = [];

  Container _parent = null;

  BuilderManager _builderManager;

  chrome.Entry get _entry => null;
  set _entry(chrome.Entry value) => null;
  Map<String, dynamic> _metadata;
  chrome.Entry get entry => null;

  List<WorkspaceRoot> _roots = [];

  chrome.FileSystem _syncFileSystem;

  PreferenceStore _store;
  Completer<Workspace> _whenAvailable = new Completer();
  Completer<Workspace> _whenAvailableSyncFs = new Completer();

  StreamController<ResourceChangeEvent> _resourceController =
      new StreamController.broadcast();

  StreamController<MarkerChangeEvent> _markerController =
      new StreamController.broadcast();

  Workspace([this._store]);

  Future<Workspace> whenAvailable() => _whenAvailable.future;
  Future<Workspace> whenAvailableSyncFs() => _whenAvailableSyncFs.future;

  BuilderManager get builderManager => _builderManager;

  void createBuilderManager(JobManager jobManager) {
    _builderManager = new BuilderManager(this, jobManager);
  }

  String get name => null;
  String get path => '';
  bool get isTopLevel => false;
  bool get isFile => false;
  String get uuid => '';

  Future delete() => new Future.value();
  Future rename(String name) => new Future.value();

  Container get parent => null;
  Project get project => null;
  Workspace get workspace => this;

  /**
   * Stops the posting of [ResourceChangeEvent] to the stream. Clients should
   * call [resumeResourceEvents] to resume posting of maker events.
   */
  void pauseResourceEvents() {
    _resourcePauseCount++;
  }

  /**
   * Resumes posting of resource events to the stream. All resource changes made
   * when the stream was paused will be posted on resume.
   */
  void resumeResourceEvents() {
    _resourcePauseCount--;
    if (_resourcePauseCount == 0 && _resourceChangeList.isNotEmpty) {
      _resourceController.add(new ResourceChangeEvent.fromList(_resourceChangeList));
      _resourceChangeList.clear();
    }
  }

  /**
   * Stops the posting of [MarkerChangeEvent] to the stream. Clients should
   * call [resumeMakerEventStream] to resume posting of maker events.
   */
  void pauseMarkerStream() {
    _markersPauseCount++;
  }

  /**
   * Resumes posting of marker events to the stream. All marker changes made
   * when the stream was paused will be posted on resume.
   */
  void resumeMarkerStream() {
    _markersPauseCount--;
    if (_markersPauseCount == 0 && _makerChangeList.isNotEmpty) {
      _markerController.add(new MarkerChangeEvent.fromList(_makerChangeList));
      _makerChangeList.clear();
    }
  }

  /**
   * Adds a new [WorkspaceRoot] to the workspace.
   */
  Future<Resource> link(WorkspaceRoot root, {bool fireEvent: true}) {
    root.resource = root.createResource(this);
    _roots.add(root);

    if (root.resource is Container) {
      return _gatherChildren(root.resource).then((Container container) {
        if (fireEvent) {
          _resourceController.add(new ResourceChangeEvent.fromSingle(
              new ChangeDelta(container, EventType.ADD)));
        }
        return container;
      });
    } else {
      if (fireEvent) {
        _resourceController.add(new ResourceChangeEvent.fromSingle(
            new ChangeDelta(root.resource, EventType.ADD)));
      }
      return new Future.value(root.resource);
    }
  }

  void unlink(Resource resource) {
    _removeChild(resource);
  }

  /**
   * Moves all the [Resource] resources in the [List] to the given [Container]
   * container. Fires a list of [ResourceChangeEvent] events with deletes and
   * adds for the resources after the moves are completed.
   */
  Future moveTo(List<Resource> resources, Container container) {
    List futures = resources.map((r) => _moveTo(r, container));
    return Future.wait(futures).then((events) {
      List<ChangeDelta> list = [];
      resources.forEach((r) => list.add(new ChangeDelta(r, EventType.DELETE)));
      list.addAll(events);
      _resourceController.add(new ResourceChangeEvent.fromList(list));
    });
  }

  /**
   * Removes the given resource from parent, moves to the specifed container,
   * and adds it to the container's children.
   */
  Future<ChangeDelta> _moveTo(Resource resource, Container container) {
    return resource.entry.moveTo(container.entry).then((chrome.Entry newEntry) {
      resource.parent._removeChild(resource, fireEvent: false);

      if (newEntry.isFile) {
        var file = new File(container, newEntry);
        container.getChildren().add(file);
        return new Future.value(new ChangeDelta(file, EventType.ADD));
      } else {
        var folder = new Folder(container, newEntry);
        container.getChildren().add(folder);
        return _gatherChildren(folder).then((_) => new ChangeDelta(folder, EventType.ADD));
      }
    });
  }

  bool isSyncResource(Resource resource) {
    return _roots.any((root) => root is SyncFolderRoot && root.resource == resource);
  }

  Resource getChild(String name) {
    return getChildren().firstWhere((c) => c.name == name, orElse: () => null);
  }

  Resource getChildPath(String childPath) {
    int index = childPath.indexOf('/');
    if (index == -1) {
      return getChild(childPath);
    } else {
      Resource child = getChild(childPath.substring(0, index));
      if (child is Container) {
        return child.getChildPath(childPath.substring(index + 1));
      } else {
        return null;
      }
    }
  }

  List<Resource> getChildren() {
    return _roots.map((root) => root.resource).toList(growable: false);
  }

  Iterable<Resource> traverse() => Resource._workspaceTraversal(this);

  List<File> getFiles() {
    return _roots
        .map((root) => root.resource)
        .where((resource) => resource is File).toList();
  }

  List<Project> getProjects() {
    return _roots
        .map((root) => root.resource)
        .where((resource) => resource is Project).toList();
  }

  Stream<ResourceChangeEvent> get onResourceChange => _resourceController.stream;

  Stream<MarkerChangeEvent> get onMarkerChange => _markerController.stream;

  // TODO(ericarnold): We can remove this method once we analyze whole projects.
  void checkResource(Resource resource) {
    // TODO(devoncarew): temporarily disabled while we investigate a performance
    // issue
    //_fireResourceEvent(new ChangeDelta(resource, EventType.CHANGE));
  }

  void _fireResourceEvent(ChangeDelta delta) {
    if (_resourcePauseCount == 0) {
      _resourceController.add(new ResourceChangeEvent.fromSingle(delta));
    } else {
      _resourceChangeList.add(delta);
    }
  }

  void _fireMarkerEvent(MarkerDelta delta) {
    if (_markersPauseCount == 0) {
      _markerController.add(new MarkerChangeEvent(delta));
    } else {
      _makerChangeList.add(delta);
    }
  }

  /**
   * Read the workspace data from storage and restore entries.
   */
  Future restore() {
    _store.getValue('workspaceRoots').then((s) {
      if (s == null) {
        _whenAvailable.complete(this);
        return null;
      }

      try {
        pauseResourceEvents();

        List<Map> data = JSON.decode(s);

        List<WorkspaceRoot> roots = [];

        for (Map m in data) {
          WorkspaceRoot root = WorkspaceRoot.restoreRoot(m);
          if (root != null) roots.add(root);
        }

        Future.forEach(roots, (WorkspaceRoot root) {
          return root.restore().then((_) {
            return link(root, fireEvent: false);
          });
        }).whenComplete(() {
          resumeResourceEvents();
        }).then((_) => _whenAvailable.complete(this));
      } catch (e) {
        _logger.log(Level.INFO, 'Exception in workspace restore', e);
        _whenAvailable.complete(this);
      }
    });

    return whenAvailable();
  }

  /**
   * Store info for workspace children.
   */
  Future save() {
    List<Map> data = [];

    for (WorkspaceRoot root in _roots) {
      Map m = root.persistState();
      if (m != null) data.add(m);
    }

    return _store.setValue('workspaceRoots', JSON.encode(data));
  }

  bool get syncFsIsAvailable => _syncFileSystem != null;

  /**
   * Read the sync file system and restore entries.
   */
  Future restoreSyncFs() {
    chrome.syncFileSystem.requestFileSystem().then((/*chrome.FileSystem*/ fs) {
      _syncFileSystem = fs;
      _syncFileSystem.root.createReader().readEntries().then((List<chrome.Entry> entries) {
        pauseResourceEvents();
        Future.forEach(entries, (chrome.Entry entry) {
          return link(new SyncFolderRoot(entry));
        }).whenComplete(() {
          resumeResourceEvents();
        }).then((_) => _whenAvailableSyncFs.complete(this));
      });
    }, onError: (e) {
        _logger.log(Level.INFO, 'Exception in workspace restore sync file system', e);
        _whenAvailableSyncFs.complete(this);
    });

    return whenAvailableSyncFs();
  }

  /**
   * Restore a [Resource] given a uuid for that Resource.
   */
  Resource restoreResource(String uuid) {
    if (uuid == '') return this;

    String first = uuid;
    String rest = null;

    int index = uuid.indexOf('/');
    if (index != -1) {
      first = uuid.substring(0, index);
      rest = uuid.substring(index + 1);
    }

    WorkspaceRoot root = _roots.firstWhere(
        (r) => r.id == first, orElse: () => null);

    if (root == null) return null;
    if (rest == null) return root.resource;

    Resource resource = root.resource;

    if (resource is Container) {
      return resource.getChildPath(rest);
    } else {
      return null;
    }
  }

  List<Marker> getMarkers() => [];

  void clearMarkers() { }

  int findMaxProblemSeverity() => Marker.SEVERITY_NONE;

  Future<Resource> _gatherChildren(Container container) {
    chrome.DirectoryEntry dir = container.entry;
    List futures = [];

    return dir.createReader().readEntries().then((entries) {
      for (chrome.Entry ent in entries) {
        if (ent.isFile) {
          var file = new File(container, ent);
          container.getChildren().add(file);
        } else {
          var folder = new Folder(container, ent);
          container.getChildren().add(folder);
          futures.add(_gatherChildren(folder));
        }
      }
      return Future.wait(futures).then((_) => container);
    });
  }

  /**
   * This method checks if the layout of files on the filesystem has changed
   * and will update the content of the workspace if needed.
   */
  Future refresh() {
    List<Project> projects = getProjects().toList();

    return Future.forEach(projects, (Project project) {
      return _runInTimer(() => project.refresh());
    });
  }

  dynamic getMetadata(String key, [dynamic defaultValue]) => defaultValue;

  void setMetadata(String key, dynamic data) { }

  bool isScmPrivate() => false;

  void _removeChild(Resource resource, {bool fireEvent: true}) {
    _roots.removeWhere((root) => root.resource == resource);
    if (fireEvent) {
      _fireResourceEvent(new ChangeDelta(resource, EventType.DELETE));
    }
  }
}

abstract class Container extends Resource {
  Container(Container parent, chrome.Entry entry) : super(parent, entry);

  Resource getChild(String name) {
    for (Resource resource in getChildren()) {
      if (resource.name == name) {
        return resource;
      }
    }

    return null;
  }

  Resource getChildPath(String childPath) {
    int index = childPath.indexOf('/');
    if (index == -1) {
      return getChild(childPath);
    } else {
      Resource child = getChild(childPath.substring(0, index));
      if (child is Container) {
        return child.getChildPath(childPath.substring(index + 1));
      } else {
        return null;
      }
    }
  }

  void _removeChild(Resource resource, {bool fireEvent: true}) {
    getChildren().remove(resource);
    if (fireEvent) {
      _fireResourceEvent(new ChangeDelta(resource, EventType.DELETE));
    }
  }

  List<Resource> getChildren();

  List<Marker> getMarkers() {
    return traverse().where((r) => r is File)
        .expand((f) => f.getMarkers()).toList();
  }

  void clearMarkers() {
    workspace.pauseMarkerStream();

    for (Resource resource in getChildren()) {
      resource.clearMarkers();
    }

    workspace.resumeMarkerStream();
  }

  int findMaxProblemSeverity() {
    int severity = Marker.SEVERITY_NONE;

    for (Resource resource in getChildren()) {
      severity = math.max(severity, resource.findMaxProblemSeverity());

      if (severity == Marker.SEVERITY_ERROR) {
        return severity;
      }
    }

    return severity;
  }
}

abstract class Resource {
  Container _parent;
  chrome.Entry _entry;

  /**
   * This map stores arbitrary metadata that clients can get and set on the
   * resource. In the future, this metadata will automatically be persisted
   * with the resource, and available across session restarts.
   */
  Map<String, dynamic> _metadata;

  Resource(this._parent, this._entry);

  String get name => _entry.name;

  chrome.Entry get entry => _entry;

  /**
   * Return the path to this element from the workspace. Paths are not
   * guaranteed to be unique. For uniqueness, see [uuid].
   */
  String get path => '${parent.path}/${name}';

  /**
   * Return a unique identifier for this [Resource]. This is a token that can be
   * later used to deserialize this [Resource].
   */
  String get uuid => '${parent.uuid}/${name}';

  bool get isTopLevel => _parent is Workspace;

  bool get isFile => false;

  Container get parent => _parent;

  void _fireResourceEvent(ChangeDelta delta) => _parent._fireResourceEvent(delta);

  void _fireMarkerEvent(MarkerDelta delta) => _parent._fireMarkerEvent(delta);

  Future delete();

  Future rename(String name) {
    return entry.moveTo(_parent._entry, name: name).then((chrome.Entry e) {
      workspace.pauseResourceEvents();
      _fireResourceEvent(new ChangeDelta(this, EventType.DELETE));
      _fireResourceEvent(new ChangeDelta(this, EventType.ADD));
      workspace.resumeResourceEvents();
    });
  }

  /**
   * Returns the containing [Project]. This can return null for loose files and
   * for the workspace.
   */
  Project get project => parent is Project ? parent : parent.project;

  Workspace get workspace => parent.workspace;

  bool operator ==(other) =>
      this.runtimeType == other.runtimeType && uuid == other.uuid;

  int get hashCode => uuid.hashCode;

  String toString() => '${this.runtimeType} ${name}';

  /**
   * Returns a [List] of [Marker] from all the [Resources] in the [Container].
   */
  List<Marker> getMarkers();

  void clearMarkers();

  int findMaxProblemSeverity();

  /**
   * Get arbitrary metadata associated with this resource.
   */
  dynamic getMetadata(String key, [dynamic defaultValue]) {
    if (_metadata == null) {
      return defaultValue;
    } else {
      var val = _metadata[key];
      return val == null ? defaultValue : val;
    }
  }

  /**
   * Associate arbitrary metadata with this resource.
   */
  void setMetadata(String key, dynamic data) {
    if (_metadata == null) {
      _metadata = {};
    }

    var currentVal = _metadata[key];

    if (data != currentVal) {
      // TODO: In the future, we may want to fire metadata change events that
      // clients can listen for.
      _metadata[key] = data;
    }
  }

  /**
   * Returns whether the given resource should be considered hidden SCM
   * meta-data.
   */
  bool isScmPrivate() => false;

  /**
   * Returns an iterable of the children of the resource as a pre-order traversal
   * of the tree of subcontainers and their children.
   */
  Iterable<Resource> traverse() => _workspaceTraversal(this);

  static Iterable<Resource> _workspaceTraversal(Resource r) {
    if (r is Container) {
      if (r.isScmPrivate()) {
        return [];
      } else {
        return
            [[r], r.getChildren().expand(_workspaceTraversal)].expand((i) => i);
      }
    } else {
      return [r];
    }
  }
}

class Folder extends Container {
  List<Resource> _children = [];

  Folder(Container parent, chrome.Entry entry) : super(parent, entry);

  List<Resource> getChildren() => _children;

  /**
   * Creates a new [File] with the given name
   */
  Future<File> createNewFile(String name) {
    return _dirEntry.createFile(name).then((entry) {
      File file = new File(this, entry);
      _children.add(file);
      _fireResourceEvent(new ChangeDelta(file, EventType.ADD));
      return file;
    });
  }

  Future<Folder> createNewFolder(String name) {
    return _dirEntry.createDirectory(name).then((entry) {
      Folder folder = new Folder(this, entry);
      _children.add(folder);
      _fireResourceEvent(new ChangeDelta(folder, EventType.ADD));
      return folder;
    });
  }

  Future delete() {
    return _dirEntry.removeRecursively().then((_) => _parent._removeChild(this));
  }

  bool isScmPrivate() => name == '.git' || name == '.svn';

  Future _refresh() {
    return _dirEntry.createReader().readEntries().then((List<chrome.Entry> entries) {
      List<String> currentNames = _children.map((r) => r.name).toList();
      List<String> newNames = entries.map((e) => e.name).toList();
      List<Resource> checkChanged = [];

      // Check for deleted files.
      for (int i = currentNames.length - 1; i >= 0; i--) {
        String name = currentNames[i];

        if (newNames.contains(name)) {
          checkChanged.add(_children[i]);
        } else {
          Resource resource = _children.removeAt(i);
          _fireResourceEvent(new ChangeDelta(resource, EventType.DELETE));
        }
      }

      List<Future> futures = [];

      // Check for added files.
      for (int i = newNames.length - 1; i >= 0; i--) {
        String name = newNames[i];

        if (!currentNames.contains(name)) {
          Resource resource;

          if (entries[i].isFile) {
            resource = new File(this, entries[i]);
          } else {
            resource = new Folder(this, entries[i]);
            futures.add(workspace._gatherChildren(resource));
          }

          _children.add(resource);
          _fireResourceEvent(new ChangeDelta(resource, EventType.ADD));
        }
      }

      // Check for modified files.
      return Future.forEach(checkChanged, (Resource resource) {
        if (resource is File) {
          return resource._refresh();
        } else if (resource is Folder) {
          return resource._refresh();
        }
      }).then((_) {
        return Future.wait(futures);
      });
    });
  }

  chrome.DirectoryEntry get _dirEntry => entry;
}

class File extends Resource {
  List<Marker> _markers = [];
  int _timestamp;

  File(Container parent, chrome.Entry entry) : super(parent, entry) {
    entry.getMetadata().then((/*Metadata*/ metaData) {
      _timestamp = metaData.modificationTime.millisecondsSinceEpoch;
    });
  }

  Future<String> getContents() => _fileEntry.readText();

  Future<chrome.ArrayBuffer> getBytes() => _fileEntry.readBytes();

  Future setContents(String contents) {
    return _fileEntry.writeText(contents).then((_) {
      workspace._fireResourceEvent(new ChangeDelta(this, EventType.CHANGE));
    });
  }

  Future delete() {
    return _fileEntry.remove().then((_) => _parent._removeChild(this));
  }

  Future setBytes(List<int> data) {
    chrome.ArrayBuffer bytes = new chrome.ArrayBuffer.fromBytes(data);
    return _fileEntry.writeBytes(bytes).then((_) {
      workspace._fireResourceEvent(new ChangeDelta(this, EventType.CHANGE));
    });
  }

  Marker createMarker(String type, int severity, String message, int lineNum,
                    [int charStart = -1, int charEnd = -1]) {
    Marker marker = new Marker(
        this, type, severity, message, lineNum, charStart, charEnd);
    _markers.add(marker);
    _fireMarkerEvent(new MarkerDelta(this, marker, EventType.ADD));
    return marker;
  }

  bool get isFile => true;

  List<Marker> getMarkers() => _markers;

  void clearMarkers() {
    if (_markers.isNotEmpty) {
      _markers.clear();
      _fireMarkerEvent(new MarkerDelta(this, null, EventType.DELETE));
    }
  }

  int findMaxProblemSeverity() {
    int severity = Marker.SEVERITY_NONE;

    for (Marker marker in _markers) {
      severity = math.max(severity, marker.severity);

      if (severity == Marker.SEVERITY_ERROR) {
        return severity;
      }
    }

    return severity;
  }

  Future _refresh() {
    return entry.getMetadata().then((/*Metadata*/ metaData) {
      final int newStamp = metaData.modificationTime.millisecondsSinceEpoch;
      if (newStamp != _timestamp) {
        _timestamp = newStamp;
        _fireResourceEvent(new ChangeDelta(this, EventType.CHANGE));
      }
    });
  }

  chrome.ChromeFileEntry get _fileEntry => entry;
}

/**
 * The top-level container resource for the workspace. Only [File]s and
 * [Projects]s can be immediate child elements of a [Workspace].
 */
class Project extends Folder {
  WorkspaceRoot _root;

  Project(Workspace workspace, WorkspaceRoot root) : super(workspace, root.entry) {
    _root = root;
  }

  Project get project => this;

  String get uuid => '${_root.id}';

  /**
   * Check the files on disk for changes that we don't know about. Fire resource
   * change events as necessary.
   */
  Future refresh() {
    workspace.pauseResourceEvents();

    return _refresh().whenComplete(() {
      workspace.resumeResourceEvents();
    });
  }
}

/**
 * This class represents a top-level file.
 */
class LooseFile extends File {
  WorkspaceRoot _root;

  LooseFile(Workspace workspace, WorkspaceRoot root) : super(workspace, root.entry) {
    _root = root;
  }

  String get uuid => '${_root.id}';
}

/**
 * A [WorkspaceRoot] is something that can be linked into the top-level of the
 * workspace.
 */
abstract class WorkspaceRoot {

  static WorkspaceRoot restoreRoot(Map m) {
    if (m['type'] == 'file') {
      return new FileRoot._(m);
    } else if (m['type'] == 'folder') {
      return new FolderRoot._(m);
    } else if (m['type'] == 'folderChild') {
      return new FolderChildRoot._(m);
    } else {
      return null;
    }
  }

  chrome.Entry entry;
  Resource resource;
  String get id;

  Resource createResource(Workspace workspace);
  Future restore();
  Map persistState();
}

/**
 * A workspace root that represents a single loose file.
 */
class FileRoot extends WorkspaceRoot {
  String token;

  FileRoot(chrome.FileEntry fileEntry) {
    entry = fileEntry;
    token = _chromeHelper.retainEntry(fileEntry);
  }

  FileRoot._(Map m) {
    token = m['token'];
  }

  String get id => token;

  Resource createResource(Workspace workspace) => new LooseFile(workspace, this);

  Future restore() {
    return _chromeHelper.restoreEntry(token).then((e) {
      entry = e;
    });
  }

  Map persistState() {
    return {
      'type': 'file',
      'token': token
    };
  }
}

/**
 * A workspace root that represents a folder specifically selected by the user.
 */
class FolderRoot extends WorkspaceRoot {
  String token;

  FolderRoot(chrome.DirectoryEntry folderEntry) {
    entry = folderEntry;
    token = _chromeHelper.retainEntry(folderEntry);
  }

  FolderRoot._(Map m) {
    token = m['token'];
  }

  String get id => token;

  Resource createResource(Workspace workspace) => new Project(workspace, this);

  Future restore() {
    return _chromeHelper.restoreEntry(token).then((e) {
      entry = e;
    });
  }

  Map persistState() {
    if (token == null) return null;

    return {
      'type': 'folder',
      'token': token
    };
  }
}

/**
 * A workspace root that represents a folder inside a folder selected by the
 * user.
 */
class FolderChildRoot extends WorkspaceRoot {
  String parentToken;
  String name;

  FolderChildRoot(chrome.DirectoryEntry parent, chrome.DirectoryEntry folderEntry) {
    parentToken = _chromeHelper.retainEntry(parent);
    entry = folderEntry;
    name = folderEntry.name;
  }

  FolderChildRoot._(Map m) {
    parentToken = m['parentToken'];
    name = m['name'];
  }

  String get id => '${parentToken}-${name}';

  Resource createResource(Workspace workspace) => new Project(workspace, this);

  Future restore() {
    return _chromeHelper.restoreEntry(parentToken).then((parent) {
      return parent.getDirectory(name).then((e) {
        entry = e;
      });
    });
  }

  Map persistState() {
    return {
      'type': 'folderChild',
      'parentToken': parentToken,
      'name': name
    };
  }
}

/**
 * A workspace root that represents a folder on the sync file system.
 */
class SyncFolderRoot extends WorkspaceRoot {

  SyncFolderRoot(chrome.DirectoryEntry folderEntry) {
    entry = folderEntry;
  }

  String get id => '\$sync-${entry.name}';

  Resource createResource(Workspace workspace) => new Project(workspace, this);

  // Nothing to restore - these are created differently.
  Future restore() => new Future.value();

  // We do not persist infomation about the sync filesystem root.
  Map persistState() => null;
}

/**
 * An enum of the valid [ResourceChangeEvent] types.
 */
class EventType {
  final String name;

  const EventType._(this.name);

  /**
   * Event type indicates resource has been added to workspace.
   */
  static const EventType ADD = const EventType._('ADD');

  /**
   * Event type indicates resource has been removed from workspace.
   */
  static const EventType DELETE = const EventType._('DELETE');

  /**
   * Event type indicates resource has changed.
   */
  static const EventType CHANGE = const EventType._('CHANGE');

  String toString() => name;
}

/**
 * Used to indicate changes to the Workspace.
 */
class ResourceChangeEvent {
  final List<ChangeDelta> changes;

  factory ResourceChangeEvent.fromSingle(ChangeDelta delta) {
    return new ResourceChangeEvent._([delta]);
  }

  factory ResourceChangeEvent.fromList(List<ChangeDelta> deltas) {
    return new ResourceChangeEvent._(deltas.toList());
  }

  ResourceChangeEvent._(List<ChangeDelta> delta) :
    changes = new UnmodifiableListView(delta);

  /**
   * A convenience getter used to return modified (new or changed) files.
   */
  Iterable<File> get modifiedFiles => changes
      .where((delta) => !delta.isDelete && delta.resource is File)
      .map((delta) => delta.resource);

  /**
   * Returns an [Iterable] of the changed projects in this event.
   */
  Iterable<Project> get modifiedProjects => changes
      .map((delta) => delta.resource.project)
      .toSet()
      .where((project) => project != null);

  List<ChangeDelta> getChangesFor(Project project) {
    return changes.where((c) => c.resource.project == project).toList();
  }
}

/**
 * Indicates a change on a particular resource.
 */
class ChangeDelta {
  final Resource resource;
  final EventType type;

  ChangeDelta(this.resource, this.type);

  bool get isAdd => type == EventType.ADD;
  bool get isChange => type == EventType.CHANGE;
  bool get isDelete => type == EventType.DELETE;

  String toString() => '${type}: ${resource}';
}

/**
 * Used to associate a error, warning or info for a [File].
 */
class Marker {

  /**
   * The file for the marker.
   */
  File file;

  /**
   * Stores all the attributes of the marker - severity, line number etc.
   */
  Map<String, dynamic> _attributes = new Map();

  /**
   * Key for type of marker, based on type of file association - html,
   * dart, js etc.
   */
  static const String TYPE = "type";

  /**
   * Key for severity of the marker, from the set of error, warning and info
   * severities.
   */
  static const String SEVERITY = "severity";

  /**
   * The key to for a string describing the nature of the marker.
   */
  static const String MESSAGE = "message";

  /**
   * An integer value indicating the line number for a marker.
   */
  static const String LINE_NO = "lineno";

  /**
   * Key to an integer value indicating where a marker starts.
   */
  static const String CHAR_START = "charStart";

  /**
   * Key to an integer value indicating where a marker ends.
   */
  static const String CHAR_END = "charEnd";

  /**
   * The severity of the marker, error being the highest severity.
   */
  static const int SEVERITY_ERROR = 3;

  /**
   * Indicates maker is a warning.
   */
  static const int SEVERITY_WARNING = 2;

  /**
   * Indicates marker is informational.
   */
  static const int SEVERITY_INFO = 1;

  static const int SEVERITY_NONE = 0;

  Marker(this.file, String type, int severity, String message, int lineNum,
      [int charStart = -1, int charEnd = -1]) {
    _attributes[TYPE] = type;
    _attributes[SEVERITY] = severity;
    _attributes[MESSAGE] = message;
    _attributes[LINE_NO] = lineNum;
    _attributes[CHAR_START] = charStart;
    _attributes[CHAR_END] = charEnd;
  }

  String get type => _attributes[TYPE];

  int get severity => _attributes[SEVERITY];

  String get message => _attributes[MESSAGE];

  int get lineNum => _attributes[LINE_NO];

  int get charStart => _attributes[CHAR_START];

  int get charEnd => _attributes[CHAR_END];

  void addAttribute(String key, dynamic value) => _attributes[key] = value;

  dynamic getAttribute(String key) => _attributes[key];

  String toString() => '${severityDescription}: ${message}, line ${lineNum}';

  String get severityDescription {
    if (severity == SEVERITY_ERROR) return 'error';
    if (severity == SEVERITY_WARNING) return 'warning';
    if (severity == SEVERITY_INFO) return 'info';
    return '';
  }
}

/**
 * Used to indicate changes to markers
 */
class MarkerChangeEvent {
  List<MarkerDelta> changes;

  MarkerChangeEvent(MarkerDelta delta) {
    changes = new UnmodifiableListView([delta]);
  }

  factory MarkerChangeEvent.fromList(List<MarkerDelta> deltas) {
    return new MarkerChangeEvent._(deltas.toList());
  }

  MarkerChangeEvent._(List<MarkerDelta> delta) :
    changes = new UnmodifiableListView(delta);

  /**
   * Checks if the given [File] is present in the list of marker changes.
   */
  bool hasChangesFor(File file) {
    return changes.any((delta) => delta.resource == file);
  }
}

/**
 * Indicates change on a marker
 */
class MarkerDelta {
  final Marker marker;
  final EventType type;
  final Resource resource;

  MarkerDelta(this.resource, this.marker, this.type);

  bool get isAdd => type == EventType.ADD;
  bool get isChange => type == EventType.CHANGE;
  bool get isDelete => type == EventType.DELETE;

  String toString() => '${type}: ${marker}';
}

/**
 * Cache lookups into retained file entries, so that the same entry retained
 * twice will return the same id.
 */
class _ChromeHelper {
  Map<String, chrome.Entry> _map = {};

  String retainEntry(chrome.Entry entry) {
    for (String key in _map.keys) {
      if (_map[key] == entry) {
        return key;
      }
    }

    String id = chrome.fileSystem.retainEntry(entry);
    _map[id] = entry;
    return id;
  }

  Future<chrome.Entry> restoreEntry(String id) {
    if (_map.containsKey(id)) {
      return new Future.value(_map[id]);
    } else {
      return chrome.fileSystem.restoreEntry(id).then((entry) {
        _map[id] = entry;
        return entry;
      });
    }
  }
}

/**
 * Run the given closure in a timer task.
 */
Future _runInTimer(var closure) {
  Completer completer = new Completer();

  Timer.run(() {
    var result = closure();
    if (result is Future) {
      result.whenComplete(() => completer.complete());
    } else {
      completer.complete();
    }
  });

  return completer.future;
}
