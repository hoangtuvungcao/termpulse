import 'dart:convert';
import 'dart:math';

/// Command recipes, deliberately separate from raw terminal input/recording.
class CommandMacro {
  static const maxMacros = 128;
  static const maxSteps = 64;
  static const maxCommandLength = 8192;
  static const maxDelayMs = 600000;
  static const maxJsonBytes = 2 * 1024 * 1024;

  final String id;
  final String name;
  final List<MacroStep> steps;

  CommandMacro({
    required this.id,
    required this.name,
    required List<MacroStep> steps,
  }) : steps = List.unmodifiable(steps);

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

  CommandMacro copyWith({String? id, String? name, List<MacroStep>? steps}) =>
      CommandMacro(
        id: id ?? this.id,
        name: name ?? this.name,
        steps: steps ?? this.steps,
      );

  void validate() {
    if (id.isEmpty ||
        id.length > 100 ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('ID macro không hợp lệ.');
    }
    if (name.trim().isEmpty ||
        name.length > 100 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException(
        'Tên macro cần 1–100 ký tự, không chứa ký tự điều khiển.',
      );
    }
    if (steps.isEmpty || steps.length > maxSteps) {
      throw const FormatException('Macro cần 1–64 bước lệnh.');
    }
    for (final step in steps) {
      step.validate();
    }
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'steps': steps.map((step) => step.toJson()).toList(),
  };

  factory CommandMacro.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['steps'] is! List) {
      throw const FormatException('Mỗi macro cần id, name và danh sách steps.');
    }
    final steps = value['steps'] as List;
    if (steps.isEmpty || steps.length > maxSteps) {
      throw const FormatException('Macro cần 1–64 bước lệnh.');
    }
    final macro = CommandMacro(
      id: value['id'] as String,
      name: value['name'] as String,
      steps: steps.map(MacroStep.fromJson).toList(),
    );
    macro.validate();
    return macro;
  }

  static List<CommandMacro> decodeLibrary(String raw) {
    if (raw.length > maxJsonBytes || utf8.encode(raw).length > maxJsonBytes) {
      throw const FormatException('JSON macro vượt giới hạn 2 MiB.');
    }
    final dynamic value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('JSON macro không hợp lệ.');
    }
    if (value is! Map<String, dynamic> ||
        value['format'] != 'termpulse.command-macros' ||
        value['version'] != 1 ||
        value['macros'] is! List) {
      throw const FormatException(
        'Cần JSON TermPulse command macros, version 1.',
      );
    }
    final macros = value['macros'] as List;
    if (macros.length > maxMacros) {
      throw const FormatException('Thư viện chỉ chứa tối đa 128 macro.');
    }
    final result = macros.map(CommandMacro.fromJson).toList();
    validateLibrary(result);
    return List.unmodifiable(result);
  }

  static void validateLibrary(List<CommandMacro> macros) {
    if (macros.length > maxMacros) {
      throw const FormatException('Thư viện chỉ chứa tối đa 128 macro.');
    }
    final ids = <String>{};
    for (final macro in macros) {
      macro.validate();
      if (!ids.add(macro.id)) {
        throw const FormatException('JSON có ID macro trùng.');
      }
    }
  }

  static String encodeLibrary(List<CommandMacro> macros) {
    validateLibrary(macros);
    final raw = const JsonEncoder.withIndent('  ').convert({
      'format': 'termpulse.command-macros',
      'version': 1,
      'macros': macros.map((macro) => macro.toJson()).toList(),
    });
    if (utf8.encode(raw).length > maxJsonBytes) {
      throw const FormatException('Thư viện macro vượt giới hạn 2 MiB.');
    }
    return raw;
  }
}

class MacroStep {
  final String command;

  /// Milliseconds to wait after sending this command, not shell completion.
  final int delayAfterMs;

  const MacroStep({required this.command, this.delayAfterMs = 0});

  void validate() {
    if (command.trim().isEmpty ||
        command.length > CommandMacro.maxCommandLength) {
      throw const FormatException('Mỗi lệnh cần 1–8192 ký tự.');
    }
    // Keep newline/tab for ordinary shell scripts, reject terminal escapes.
    if (command.contains(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'))) {
      throw const FormatException(
        'Lệnh chứa ký tự điều khiển terminal không được phép.',
      );
    }
    if (delayAfterMs < 0 || delayAfterMs > CommandMacro.maxDelayMs) {
      throw const FormatException('Thời gian chờ phải từ 0 đến 600000 ms.');
    }
  }

  Map<String, Object> toJson() => {
    'command': command,
    'delayAfterMs': delayAfterMs,
  };

  factory MacroStep.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['command'] is! String ||
        (value['delayAfterMs'] != null && value['delayAfterMs'] is! int)) {
      throw const FormatException(
        'Bước cần command và delayAfterMs dạng số nguyên.',
      );
    }
    final step = MacroStep(
      command: value['command'] as String,
      delayAfterMs: value['delayAfterMs'] as int? ?? 0,
    );
    step.validate();
    return step;
  }
}
