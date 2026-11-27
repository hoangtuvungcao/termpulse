import 'dart:async';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

Future<void> showSerialConnectDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final config = await showDialog<SerialConfigDto>(
    context: context,
    builder: (_) => const SerialConnectDialog(),
  );
  if (config == null || !context.mounted) return;
  await ref.read(sessionManagerProvider.notifier).openSerial(config);
}

/// Enumerates desktop and Android USB ports, accepting explicit port names.
class SerialConnectDialog extends ConsumerStatefulWidget {
  const SerialConnectDialog({super.key});

  @override
  ConsumerState<SerialConnectDialog> createState() =>
      _SerialConnectDialogState();
}

class _SerialConnectDialogState extends ConsumerState<SerialConnectDialog> {
  final _formKey = GlobalKey<FormState>();
  final _port = TextEditingController();
  final _baud = TextEditingController(text: '115200');
  List<SerialPortInfoDto> _ports = [];
  bool _supported = false;
  bool _loading = false;
  String? _error;
  int _dataBits = 8;
  String _parity = 'none';
  int _stopBits = 1;
  String _flowControl = 'none';

  @override
  void initState() {
    super.initState();
    try {
      _supported = ref.read(backendProvider).serialSupported();
      if (_supported) unawaited(_refreshPorts());
    } catch (error) {
      _error = error.toString();
    }
  }

  Future<void> _refreshPorts() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ports = await ref.read(backendProvider).listSerialPorts();
      if (!mounted) return;
      setState(() => _ports = ports);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _port.dispose();
    _baud.dispose();
    super.dispose();
  }

  void _connect() {
    if (!_supported || !_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      SerialConfigDto(
        portName: _port.text.trim(),
        baudRate: int.parse(_baud.text),
        dataBits: _dataBits,
        parity: _parity,
        stopBits: _stopBits,
        flowControl: _flowControl,
      ),
    );
  }

  Widget _choice<T>({
    required String name,
    required Key key,
    required T value,
    required Map<T, String> choices,
    required ValueChanged<T> onChanged,
  }) => DropdownButtonFormField<T>(
    key: key,
    isExpanded: true,
    initialValue: value,
    decoration: InputDecoration(labelText: name),
    items: choices.entries
        .map(
          (entry) => DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final android = Theme.of(context).platform == TargetPlatform.android;
    return AlertDialog(
      key: const Key('serialConnectDialog'),
      title: Text(context.tr('Kết nối Serial')),
      content: SizedBox(
        width: 460,
        child: !_supported
            ? SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.tr(
                        'Serial hỗ trợ Linux, Windows, macOS và USB OTG trên Android. iOS chưa hỗ trợ USB Serial.',
                      ),
                      key: const Key('serialUnsupportedMessage'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      InlineNotice(
                        key: const Key('serialPortsError'),
                        message: _error!,
                      ),
                    ],
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (android) ...[
                        Text(
                          context.tr(
                            'Kết nối thiết bị USB Serial qua cáp OTG, rồi quét lại và chọn cổng. Android sẽ yêu cầu quyền truy cập khi kết nối.',
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _loading
                                  ? context.tr('Đang tìm cổng Serial…')
                                  : context.tr(
                                      '${_ports.length} cổng được phát hiện',
                                    ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            key: const Key('serialRefreshPortsButton'),
                            tooltip: context.tr('Quét lại cổng Serial'),
                            onPressed: _loading ? null : _refreshPorts,
                            icon: _loading
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                      if (_ports.isNotEmpty) ...[
                        DropdownButtonFormField<String>(
                          key: const Key('serialDetectedPortField'),
                          decoration: InputDecoration(
                            labelText: context.tr('Chọn cổng phát hiện'),
                          ),
                          isExpanded: true,
                          items: _ports
                              .map(
                                (port) => DropdownMenuItem(
                                  value: port.portName,
                                  child: Text(
                                    '${port.portName}${port.product == null ? '' : ' · ${port.product}'}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (name) {
                            if (name != null) _port.text = name;
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        key: const Key('serialPortField'),
                        controller: _port,
                        autofocus: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: context.tr('Cổng Serial'),
                          hintText: context.tr(
                            android
                                ? 'Chọn cổng USB phát hiện ở trên'
                                : '/dev/ttyUSB0, /dev/cu.usbserial… hoặc COM3',
                          ),
                        ),
                        validator: (value) {
                          final name = value?.trim() ?? '';
                          if (name.isEmpty ||
                              name.runes.any(
                                (rune) => rune < 32 || rune == 127,
                              )) {
                            return 'Hãy nhập tên cổng Serial hợp lệ.';
                          }
                          return null;
                        },
                        errorBuilder: (context, error) => Text(
                          context.tr(error),
                          style: TextStyle(color: colors.error, fontSize: 12),
                        ),
                      ),
                      if (!_loading && _ports.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          context.tr(
                            android
                                ? 'Không tìm thấy cổng USB Serial. Kiểm tra cáp OTG và thiết bị rồi quét lại.'
                                : 'Không tìm thấy cổng. Bạn có thể nhập trực tiếp tên cổng của hệ điều hành.',
                          ),
                          key: Key('serialNoPortsMessage'),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('serialBaudField'),
                        controller: _baud,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: context.tr('Baud rate'),
                        ),
                        validator: (value) {
                          final baud = int.tryParse(value ?? '');
                          return baud == null || baud < 1 || baud > 4000000
                              ? 'Baud rate phải từ 1 đến 4000000.'
                              : null;
                        },
                        errorBuilder: (context, error) => Text(
                          context.tr(error),
                          style: TextStyle(color: colors.error, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _choice<int>(
                              name: context.tr('Data bits'),
                              key: const Key('serialDataBitsField'),
                              value: _dataBits,
                              choices: const {5: '5', 6: '6', 7: '7', 8: '8'},
                              onChanged: (value) =>
                                  setState(() => _dataBits = value),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _choice<String>(
                              name: context.tr('Parity'),
                              key: const Key('serialParityField'),
                              value: _parity,
                              choices: {
                                'none': context.tr('None'),
                                'odd': context.tr('Odd'),
                                'even': context.tr('Even'),
                              },
                              onChanged: (value) =>
                                  setState(() => _parity = value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _choice<int>(
                              name: context.tr('Stop bits'),
                              key: const Key('serialStopBitsField'),
                              value: _stopBits,
                              choices: const {1: '1', 2: '2'},
                              onChanged: (value) =>
                                  setState(() => _stopBits = value),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _choice<String>(
                              name: context.tr('Flow control'),
                              key: const Key('serialFlowControlField'),
                              value: _flowControl,
                              choices: {
                                'none': context.tr('None'),
                                'software': 'XON/XOFF',
                                'hardware': 'RTS/CTS',
                              },
                              onChanged: (value) =>
                                  setState(() => _flowControl = value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.tr(
                          'Thông số phải trùng với thiết bị. Cổng cần quyền truy cập và không được ứng dụng khác chiếm dụng.',
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        InlineNotice(
                          key: const Key('serialPortsError'),
                          message: _error!,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_supported ? context.tr('Huỷ') : context.tr('Đóng')),
        ),
        if (_supported)
          FilledButton.icon(
            key: const Key('serialConnectButton'),
            onPressed: _connect,
            icon: const Icon(Icons.cable_rounded, size: 18),
            label: Text(context.tr('Kết nối')),
          ),
      ],
    );
  }
}
