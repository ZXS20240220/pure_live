import 'package:remixicon/remixicon.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:pure_live/common/index.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_device.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_service.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_protocol.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_preview_page.dart';

class RemoteSyncPage extends StatefulWidget {
  const RemoteSyncPage({super.key});

  @override
  State<RemoteSyncPage> createState() => _RemoteSyncPageState();
}

class _RemoteSyncPageState extends State<RemoteSyncPage> {
  /// 暂时隐藏旧版"全量接收/全量发送"按钮（设备列表与手动地址两组），
  /// 只保留"选择性同步"入口；置回 true 可恢复原布局。
  static const bool _showLegacySyncButtons = false;

  final RemoteSyncService service = Get.find<RemoteSyncService>();

  final TextEditingController addressController = TextEditingController();

  Worker? _pendingWorker;
  bool _offeringPreview = false;

  @override
  void initState() {
    super.initState();
    // 接收到远端推送（POST /settings）时提示用户进入预览选择。
    _pendingWorker = ever<Map<String, dynamic>?>(
      service.pendingReceivedSettings,
      _onPendingSettingsChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _onPendingSettingsChanged(service.pendingReceivedSettings.value);
      }
    });
  }

  void _onPendingSettingsChanged(Map<String, dynamic>? payload) {
    if (!mounted || payload == null || _offeringPreview) return;
    _offeringPreview = true;
    _showReceivedOffer();
  }

  Future<void> _showReceivedOffer() async {
    final ip = service.pendingReceivedIp.value;
    final port = service.pendingReceivedPort.value;

    final action = await Get.dialog<String>(
      AlertDialog(
        title: const Text('收到远端配置'),
        content: Text('来自 $ip:$port 的同步数据已暂存，是否打开预览并选择要应用的模块？未选中的数据不会被改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('later'),
            child: Text(i18n('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('preview'),
            child: const Text('打开预览'),
          ),
        ],
      ),
    );

    _offeringPreview = false;

    if (action != 'preview' || !mounted) return;

    final settings = service.pendingReceivedSettings.value;
    if (settings == null) return;

    Get.to(() => RemoteSyncPreviewPage(ip: ip, port: port, settings: settings));
  }

  @override
  void dispose() {
    _pendingWorker?.dispose();
    addressController.dispose();
    super.dispose();
  }

  Future<void> _sendToDevice(String ip, int port) async {
    final success = await service.syncToAddress(ip, port);

    if (!mounted) {
      return;
    }

    ToastUtil.show(success ? i18n('remote_sync_send_success') : i18n('remote_sync_send_failed'));
  }

  /// 选择性同步入口：拉取对方完整配置并打开双模式预览页
  /// （应用到本地 / 返回配置给对方）。
  Future<void> _openSyncPreview(String ip, int port) async {
    final settings = await service.getRemoteSettings(ip, port);

    if (settings == null) {
      ToastUtil.show(i18n('remote_sync_receive_failed'));
      return;
    }

    Get.to(() => RemoteSyncPreviewPage(ip: ip, port: port, settings: settings));
  }

  Future<void> _sendManual() async {
    final value = addressController.text.trim();

    if (value.isEmpty) {
      ToastUtil.show(i18n('remote_sync_enter_address'));
      return;
    }

    final parsed = RemoteSyncService.to;

    final success = await parsed.syncByAddress(value);

    if (!mounted) {
      return;
    }

    ToastUtil.show(success ? i18n('remote_sync_send_success') : i18n('remote_sync_send_failed'));
  }

  /// 手动地址的选择性同步：解析输入的 ip:port 后打开预览页。
  Future<void> _selectiveSyncManual() async {
    final value = addressController.text.trim();

    final parsed = RemoteSyncProtocol.parseHttpAddress(value);

    if (parsed == null) {
      ToastUtil.show(i18n('remote_sync_invalid_address'));
      return;
    }

    await _openSyncPreview(parsed.ip, parsed.port);
  }

  Future<void> _scanQr() async {
    if (PlatformUtils.isDesktop) {
      return;
    }

    final result = await Get.to<String>(() => const _RemoteSyncScannerPage());

    if (result == null || result.trim().isEmpty) {
      return;
    }

    final parsed = RemoteSyncProtocol.parseQr(result);

    if (parsed == null) {
      ToastUtil.show(i18n('remote_sync_invalid_qr'));
      return;
    }

    final action = await Get.dialog<String>(
      AlertDialog(
        title: Text(i18n('remote_sync_select_action')),
        content: Text('${parsed.ip}:${parsed.port}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('receive'),
            child: Text(i18n('remote_sync_receive')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('send'),
            child: Text(i18n('remote_sync_send')),
          ),
        ],
      ),
    );

    if (action == 'send') {
      await _sendToDevice(parsed.ip, parsed.port);
    } else if (action == 'receive') {
      await _openSyncPreview(parsed.ip, parsed.port);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(i18n('remote_sync')),
        actions: [
          if (!PlatformUtils.isDesktop)
            IconButton(onPressed: _scanQr, icon: const Icon(Icons.qr_code_scanner)),
          Obx(
            () => IconButton(
              onPressed: service.isDiscovering.value ? service.stop : service.start,
              icon: Icon(
                service.isDiscovering.value ? Remix.stop_circle_line : Remix.play_circle_line,
              ),
              tooltip: service.isDiscovering.value ? i18n('stop') : i18n('start'),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Obx(
        () => ListView(
          physics: const PureLiveScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _buildLocalDevice(),
            const SizedBox(height: 16),
            _buildDiscoveredDevices(),
            const SizedBox(height: 16),
            _buildManualAddress(),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalDevice() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              i18n('remote_sync_my_device'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (service.qrData.isNotEmpty)
              QrImageView(
                data: service.qrData,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                size: 180.0,
                padding: const EdgeInsets.all(12),
              ),
            const SizedBox(height: 12),
            SelectableText(
              service.address.isEmpty ? i18n('remote_sync_no_address') : service.address,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(i18n('remote_sync_scan_hint'), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(service.isServerRunning.value ? Icons.check_circle : Icons.error, size: 18),
                const SizedBox(width: 6),
                Text(
                  service.isServerRunning.value
                      ? i18n('remote_sync_running')
                      : i18n('remote_sync_not_running'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredDevices() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    i18n('remote_sync_devices'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                if (service.isDiscovering.value)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (service.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text(i18n('remote_sync_no_devices'))),
              )
            else
              ...service.devices.map(_buildDevice),
          ],
        ),
      ),
    );
  }

  Widget _buildDevice(RemoteSyncDevice device) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.devices),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(device.address),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_showLegacySyncButtons)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: service.isSyncing.value
                          ? null
                          : () => _openSyncPreview(device.ip, device.port),
                      icon: const Icon(Icons.download),
                      label: Text(i18n('remote_sync_receive')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: service.isSyncing.value
                          ? null
                          : () => _sendToDevice(device.ip, device.port),
                      icon: const Icon(Icons.upload),
                      label: Text(i18n('remote_sync_send')),
                    ),
                  ),
                ],
              )
            else
              Tooltip(
                message: '拉取对方配置并打开预览：可选择应用到本地或返回配置给对方',
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: service.isSyncing.value
                        ? null
                        : () => _openSyncPreview(device.ip, device.port),
                    icon: const Icon(Icons.tune),
                    label: const Text('选择性同步'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualAddress() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i18n('remote_sync_manual'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: addressController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: '192.168.1.100:39888',
                prefixIcon: Icon(Icons.lan),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_showLegacySyncButtons) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: service.isSyncing.value ? null : _sendManual,
                  icon: const Icon(Icons.upload),
                  label: Text(i18n('remote_sync_send')),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: service.isSyncing.value ? null : _selectiveSyncManual,
                  icon: const Icon(Icons.download),
                  label: Text(i18n('remote_sync_receive')),
                ),
              ),
            ] else
              Tooltip(
                message: '拉取对方配置并打开预览：可选择应用到本地或返回配置给对方',
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: service.isSyncing.value ? null : _selectiveSyncManual,
                    icon: const Icon(Icons.tune),
                    label: const Text('选择性同步'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RemoteSyncScannerPage extends StatefulWidget {
  const _RemoteSyncScannerPage();

  @override
  State<_RemoteSyncScannerPage> createState() => _RemoteSyncScannerPageState();
}

class _RemoteSyncScannerPageState extends State<_RemoteSyncScannerPage> {
  final MobileScannerController controller = MobileScannerController();

  bool found = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(i18n('remote_sync_scan_qr'))),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) {
          if (found) {
            return;
          }

          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue?.trim();

            if (value == null || value.isEmpty) {
              continue;
            }

            if (RemoteSyncProtocol.parseQr(value) == null) {
              continue;
            }

            found = true;
            Navigator.of(context).pop(value);
            break;
          }
        },
      ),
    );
  }
}
