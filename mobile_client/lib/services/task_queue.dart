import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';

class TaskQueueService {
  static final TaskQueueService _instance = TaskQueueService._internal();
  factory TaskQueueService() => _instance;
  TaskQueueService._internal();

  final List<Task> _tasks = [];
  bool _loaded = false;

  Future<void> loadFromStorage() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('task_queue') ?? [];
    for (final item in list) {
      try {
        _tasks.add(Task.fromJson(json.decode(item)));
      } catch (_) {
        // skip
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _tasks.map((t) => json.encode(t.toJson())).toList();
    await prefs.setStringList('task_queue', data);
  }

  List<Task> get tasks => List.unmodifiable(_tasks);

  Future<void> addTask(Task task) async {
    await loadFromStorage();
    _tasks.removeWhere((t) => t.id == task.id);
    _tasks.add(task);
    await _save();
  }

  Future<void> updateTask(Task task) async {
    await loadFromStorage();
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) {
      _tasks[idx] = task;
      await _save();
    }
  }

  /// Tasks ready to inject into session (success/failed) and not delivered yet
  List<Task> getUndeliveredReady() {
    return _tasks.where((t) => (t.status == TaskStatus.success || t.status == TaskStatus.failed) && !t.delivered).toList();
  }

  /// Mark tasks as delivered after injecting into sessionRefs
  Future<void> markDelivered(List<String> ids) async {
    bool changed = false;
    for (int i = 0; i < _tasks.length; i++) {
      if (ids.contains(_tasks[i].id) && !_tasks[i].delivered) {
        _tasks[i] = _tasks[i].copyWith(delivered: true);
        changed = true;
      }
    }
    if (changed) await _save();
  }

  /// Poll tasks with statusUrl to update their status/result
  Future<void> pollTasks({Duration timeout = const Duration(seconds: 15)}) async {
    await loadFromStorage();
    final now = DateTime.now();
    bool changed = false;

    for (int i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];

      // Expire very old pending tasks (2 hours)
      if ((task.status == TaskStatus.pending || task.status == TaskStatus.running) &&
          now.difference(task.createdAt).inHours >= 2) {
        _tasks[i] = task.copyWith(status: TaskStatus.expired, error: '任务超时未完成', updatedAt: now);
        changed = true;
        continue;
      }

      if ((task.status == TaskStatus.pending || task.status == TaskStatus.running) && task.statusUrl != null && task.statusUrl!.isNotEmpty) {
        try {
          final resp = await http.get(Uri.parse(task.statusUrl!)).timeout(timeout);
          if (resp.statusCode == 200) {
            final data = json.decode(utf8.decode(resp.bodyBytes));
            final statusStr = (data['status'] ?? data['state'] ?? '').toString().toLowerCase();
            final resultStr = data['result']?.toString() ?? data['content']?.toString();
            final errorStr = data['error']?.toString();

            TaskStatus newStatus = task.status;
            if (statusStr.contains('success') || statusStr.contains('done') || statusStr.contains('completed')) {
              newStatus = TaskStatus.success;
            } else if (statusStr.contains('fail') || statusStr.contains('error')) {
              newStatus = TaskStatus.failed;
            } else if (statusStr.contains('running') || statusStr.contains('processing')) {
              newStatus = TaskStatus.running;
            }

            _tasks[i] = task.copyWith(
              status: newStatus,
              result: resultStr ?? task.result,
              error: errorStr ?? task.error,
              updatedAt: now,
            );
            changed = true;
          }
        } catch (_) {
          // Ignore polling error; will retry next round
        }
      }
    }

    if (changed) await _save();
  }
}
