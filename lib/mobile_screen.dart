import 'package:client/utils/transfer_record.dart';
import "package:flutter/material.dart";
import "dart:io";
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import "dart:async";

// ============================================================================
// 📱 MOBILE SYSTEM
// ============================================================================
class MobileP2PClientView extends StatelessWidget {
  const MobileP2PClientView({super.key});

  @override
  Widget build(BuildContext context) => const MobileP2PClientContent();
}

class MobileP2PClientContent extends StatefulWidget {
  const MobileP2PClientContent({super.key});

  @override
  State<MobileP2PClientContent> createState() => _MobileP2PClientViewState();
}

class _MobileP2PClientViewState extends State<MobileP2PClientContent> {
  final TextEditingController _ipInputController = TextEditingController();
  Socket? _sessionSocket;
  bool _isConnected = false;
  List<TransferRecord> historyLogs = [];

  late String _cachedStorageDirectoryPath;
  List<FileSystemEntity> _mobileVaultFiles = [];
  List<PlatformFile> _selectedFilesForPC = [];

  bool _isProcessingFile = false;
  double _streamProgress = 0.0;
  String _transferLabel = "Channel Idle";
  Timer? _pingTimer;

  void _triggerSystemToast(String message, Color badgeColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        backgroundColor: badgeColor,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showCenterModal({
    required BuildContext context,
    required String title,
    required String content,
    required Color color,
  }) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(
            content,
            textAlign: TextAlign.justify,
            style: TextStyle(color: color),
            softWrap: true,
          ),
          actions: [
            TextButton(
              child: const Text("Ok"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _preResolveStoragePaths();
  }

  // Locate this method inside your _MobileP2PClientViewState
  Future<void> _preResolveStoragePaths() async {
    String rootPath = "";

    if (Platform.isAndroid) {
      // 1. Try to target the public /storage/emulated/0/Download folder
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        rootPath = downloadDir.path;
      } else {
        // Fallback if the standard Android download tree is altered
        Directory? externalDir = await getExternalStorageDirectory();
        rootPath = externalDir?.path ?? (await getApplicationDocumentsDirectory()).path;
      }
    } else {
      // Logic handling for iOS or other systems
      Directory appDocDir = await getApplicationDocumentsDirectory();
      rootPath = appDocDir.path;
    }

    // 2. Append the dedicated visible folder name
    Directory shadowSyncFolder = Directory('$rootPath/ShadowSync');

    // 3. Create the physical directory on disk if it doesn't exist yet
    if (!await shadowSyncFolder.exists()) {
      await shadowSyncFolder.create(recursive: true);
    }

    setState(() {
      _cachedStorageDirectoryPath = shadowSyncFolder.path;
    });

    // _showCenterModal(
    //   context: context,
    //   title: "Alert!",
    //   content: "Both devices should be on the same network.\n Or \n Use Hotspot and Wifi.",
    //   color: Colors.amberAccent,
    // );
    _refreshMobileVault();
  }

  void _refreshMobileVault() {
    if (Directory(_cachedStorageDirectoryPath).existsSync()) {
      setState(() {
        _mobileVaultFiles = Directory(_cachedStorageDirectoryPath).listSync().whereType<File>().toList();
      });
    }
  }

  MobileScannerController _mobileScannerController = MobileScannerController();

  Future<void> _fireQRScannerView() async {
    _mobileScannerController.start();

    final String? scannedTarget = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text("Scan Target Host QR")),
          body: MobileScanner(
            controller: _mobileScannerController,
            onDetect: (BarcodeCapture capture) {
              final List<Barcode> codes = capture.barcodes;
              if (codes.isNotEmpty && codes.first.rawValue != null) {
                _mobileScannerController.stop();
                Navigator.of(context).pop(codes.first.rawValue);
              }
            },
          ),
        ),
      ),
    );
    if (scannedTarget != null) {
      _ipInputController.text = scannedTarget;
      try {
        await _initializeP2PLink(scannedTarget);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Connection failed: Device is unreachable or offline."),
            backgroundColor: Colors.redAccent,
            action: SnackBarAction(label: "Retry Scan", textColor: Colors.white, onPressed: _fireQRScannerView),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _mobileScannerController.dispose();
    super.dispose();
  }

  Future<void> _initializeP2PLink(String endpoint) async {
    String destinationIp = endpoint.trim();
    int destinationPort = 4040;
    if (destinationIp.contains(':')) {
      final hostParts = destinationIp.split(':');
      destinationIp = hostParts[0];
      destinationPort = int.tryParse(hostParts[1]) ?? 4040;
    }

    try {
      _updateStatus("Connecting to the server...", 0.0, state: true);
      Socket socket = await Socket.connect(destinationIp, destinationPort, timeout: const Duration(seconds: 10));
      _triggerSystemToast("Connected to the server successfully.", Colors.green);
      setState(() {
        _sessionSocket = socket;
        _isConnected = true;
      });

      _updateStatus("Paired with Server", 0.0, state: false);

      bool fileHeaderParsed = false;
      String incomingFilename = "";
      int incomingFileSize = 0;
      int payloadBytesCollected = 0;
      IOSink? downloadSink;
      List<int> packetBuffer = [];

      // _startMobilePingEmitter(socket);

      socket.listen(
        (List<int> segment) async {
          // _resetMobilePingEmitter();
          // if (segment.length == 1 && segment.first == 9) {
          //   return;
          // }

          if (!fileHeaderParsed) {
            packetBuffer.addAll(segment);
            String initialStr = utf8.decode(packetBuffer, allowMalformed: true);

            if (initialStr.contains("||")) {
              final blocks = initialStr.split("||");
              final dataFields = blocks[0].replaceAll("P2P_META:", "").split('|');
              incomingFilename = dataFields[0];
              incomingFileSize = int.parse(dataFields[1]);

              int headerLength = utf8.encode("${blocks[0]}||").length;
              List<int> dataRemainder = packetBuffer.sublist(headerLength);

              File targetLocalFile = File("$_cachedStorageDirectoryPath/$incomingFilename");
              downloadSink = targetLocalFile.openWrite();

              fileHeaderParsed = true;
              packetBuffer.clear();

              if (dataRemainder.isNotEmpty) {
                // Precise math truncation calculation logic safety threshold guard rule inside metadata block
                int bytesToWrite = dataRemainder.length;
                if (payloadBytesCollected + bytesToWrite > incomingFileSize) {
                  bytesToWrite = incomingFileSize - payloadBytesCollected;
                }

                downloadSink!.add(dataRemainder.sublist(0, bytesToWrite));
                payloadBytesCollected += bytesToWrite;

                setState(() {
                  _streamProgress = incomingFileSize > 0
                      ? (payloadBytesCollected / incomingFileSize).clamp(0.0, 1.0)
                      : 0.0;
                  _transferLabel = "Downloading: $incomingFilename";
                  _isProcessingFile = true;
                });
              }

              if (payloadBytesCollected >= incomingFileSize && incomingFileSize > 0) {
                await downloadSink!.flush();
                await downloadSink!.close();
                _refreshMobileVault();
                _transferLabel = "Downloaded: $incomingFilename";
                _notify("Saved asset: $incomingFilename");
                _updateStatus("Paired with Server", 0.0, state: false);
                fileHeaderParsed = false;
                payloadBytesCollected = 0;
              }
            }
          } else {
            // Precise math truncation calculation logic safety threshold guard rule inside continuous streaming chunk block
            int bytesToWrite = segment.length;
            if (payloadBytesCollected + bytesToWrite > incomingFileSize) {
              bytesToWrite = incomingFileSize - payloadBytesCollected;
            }

            downloadSink!.add(segment.sublist(0, bytesToWrite));
            payloadBytesCollected += bytesToWrite;

            setState(() {
              _streamProgress = incomingFileSize > 0 ? (payloadBytesCollected / incomingFileSize).clamp(0.0, 1.0) : 0.0;
              _transferLabel = "Downloading: $incomingFilename";
              _isProcessingFile = true;
            });

            if (payloadBytesCollected >= incomingFileSize) {
              await downloadSink!.flush();
              await downloadSink!.close();
              _refreshMobileVault();
              // _transferLabel = "Downloaded: $incomingFilename";
              _triggerSystemToast("Received successfully: $incomingFilename", Colors.green);
              setState(() {
                historyLogs.insert(
                  0,
                  TransferRecord(
                    id: DateTime.now().toString(),
                    fileName: incomingFilename,
                    fileBytesSize: incomingFileSize,
                    fileExtensionType: incomingFilename.split('.').last.toUpperCase(),
                    timestamp: DateTime.now(),
                    direction: TransferDirection.receive,
                  ),
                );
              });
              _notify("Saved asset: $incomingFilename");
              _updateStatus("Paired with Server", 0.0, state: false);
              fileHeaderParsed = false;
              payloadBytesCollected = 0;
            }
          }
        },
        onDone: () {
          _triggerSystemToast("Disconnected.", Color.fromARGB(255, 173, 150, 0));
          // _notify("");
          _disconnectSession();
        },
        onError: (e) {
          downloadSink?.close();
          _notify("Network error: $e");
          _disconnectSession();
        },
      );
    } catch (e) {
      _triggerSystemToast("Connection Error: ", Colors.redAccent);
      _updateStatus("Connection Error: $e", 0.0, state: false);
      _disconnectSession();
    }
  }

  Future<void> _pickMultipleFiles() async {
    FilePickerResult? picked = await FilePicker.pickFiles(type: FileType.any, allowMultiple: true);
    if (picked != null && picked.files.isNotEmpty) {
      setState(() {
        _selectedFilesForPC = picked.files;
      });
    }
  }

  Future<void> _pushBatchToDesktopHost() async {
    if (_sessionSocket == null || _selectedFilesForPC.isEmpty) return;
    setState(() => _isProcessingFile = true);

    try {
      for (var targetFileObj in _selectedFilesForPC) {
        if (targetFileObj.path == null) continue;

        File uploadFile = File(targetFileObj.path!);
        String filename = targetFileObj.name;
        int filesize = targetFileObj.size;

        _updateStatus("Streaming: $filename", 0.0, state: true);
        _sessionSocket!.write("P2P_META:$filename|$filesize||");
        await _sessionSocket!.flush();

        Stream<List<int>> systemPipe = uploadFile.openRead();
        int uploadedBytesCount = 0;

        await for (List<int> piece in systemPipe) {
          _sessionSocket!.add(piece);
          uploadedBytesCount += piece.length;
          setState(() {
            _streamProgress = filesize > 0 ? (uploadedBytesCount / filesize).clamp(0.0, 1.0) : 0.0;
          });
        }
        await _sessionSocket!.flush();
        await Future.delayed(const Duration(milliseconds: 300));
      }
      _notify("All files uploaded successfully.");
      setState(() {
        _selectedFilesForPC.clear();
      });
    } catch (e) {
      _notify("Transmission error: $e");
    } finally {
      _updateStatus("Paired with Server", 0.0, state: false);
    }
  }

  void _disconnectSession() {
    _sessionSocket?.destroy();
    setState(() {
      _sessionSocket = null;
      _isConnected = false;
      _isProcessingFile = false;
      _streamProgress = 0.0;
      _selectedFilesForPC.clear();
      _transferLabel = "Disconnected Channel";
    });
    _pingTimer?.cancel();
  }

  void _updateStatus(String label, double progress, {required bool state}) {
    setState(() {
      _transferLabel = label;
      _streamProgress = progress;
      _isProcessingFile = state;
    });
  }

  void _notify(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090A0F),
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 1.0),
          child: Image.asset('assets/icon/app_icon.png', fit: BoxFit.contain),
        ),
        leadingWidth: 60,
        title: const Text("ShadowSync Premium", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        centerTitle: true,
        backgroundColor: const Color(0xFF111217),
        elevation: 0,
        actions: [
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.link_off_rounded, color: Colors.redAccent),
              onPressed: _disconnectSession,
            ),
          IconButton(
            icon: const Icon(Icons.info, color: Colors.white),
            onPressed: () => _showCenterModal(
              context: context,
              title: "Info",
              content:
                  "Both devices should be on the same network. Connect both devices with same wifi Or Use Hotspot and Wifi then scan the QR code on desktop app to link or Enter IP address of desktop manually and press Connect",
              color: Colors.white,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Link Configuration Anchor Deck Panel
            if (!_isConnected) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipInputController,
                      decoration: InputDecoration(
                        hintText: "Enter Server IP Address",
                        filled: true,
                        fillColor: const Color(0xFF171923),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _fireQRScannerView,
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF00CEC9),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _ipInputController.text.length > 6
                      ? _initializeP2PLink(_ipInputController.text)
                      : ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text("Invalid IP"), behavior: SnackBarBehavior.floating)),

                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Connect"),
                ),
              ),
            ] else ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const CircleAvatar(
                            radius: 16,
                            backgroundColor: Colors.white10,
                            child: Icon(Icons.swap_horizontal_circle_rounded, color: Color(0xFF00CEC9), size: 18),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _transferLabel,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (_isProcessingFile) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _streamProgress,
                          color: const Color(0xFF00CEC9),
                          backgroundColor: Colors.white10,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessingFile ? null : _pickMultipleFiles,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white10,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.file_open_rounded, size: 16),
                      label: Text(
                        _selectedFilesForPC.isEmpty ? "Select Files" : "${_selectedFilesForPC.length} Selected",
                      ),
                    ),
                  ),
                  if (_selectedFilesForPC.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isProcessingFile ? null : _pushBatchToDesktopHost,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00CEC9),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.cloud_upload_rounded, size: 16),
                        label: const Text("Push to PC"),
                      ),
                    ),
                  ],
                ],
              ),
            ],

            const SizedBox(height: 16),
            const Text(
              "📁 RECEIVED FILE VAULT",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _cachedStorageDirectoryPath,
              style: const TextStyle(color: Colors.white30, fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),

            // In-App File Browser Vault Explorer
            Expanded(
              child: _mobileVaultFiles.isEmpty
                  ? const Center(
                      child: Text("No files received yet.", style: TextStyle(color: Colors.white24, fontSize: 13)),
                    )
                  : ListView.builder(
                      itemCount: _mobileVaultFiles.length,
                      itemBuilder: (context, idx) {
                        File targetFile = _mobileVaultFiles[idx] as File;
                        String label = targetFile.path.split('/').last;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.insert_drive_file_outlined, color: Color(0xFF00CEC9)),
                            title: Text(
                              label,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              "${(targetFile.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB",
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                            ),
                            trailing: Icon(
                              Icons.open_in_new_rounded,
                              size: 16,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                            onTap: () => OpenFilex.open(targetFile.path), // Launch native player/viewer setup
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
