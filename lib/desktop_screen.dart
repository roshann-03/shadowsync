import 'package:client/utils/network_discovery.dart';
import 'package:client/utils/transfer_record.dart';
import "package:flutter/material.dart";
import "dart:io";
import "dart:convert";
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import "dart:async";

// ============================================================================
// DESKTOP HOST SYSTEM
// ============================================================================
class DesktopP2PHostView extends StatefulWidget {
  const DesktopP2PHostView({super.key});

  @override
  State<DesktopP2PHostView> createState() => _DesktopP2PHostViewState();
}

class _DesktopP2PHostViewState extends State<DesktopP2PHostView> {
  String _serverIp = "Detecting...";
  // bool _noNetworkFound = false;
  ServerSocket? _serverSocket;
  Socket? _connectedPeerSocket;
  // Timer? _heartbeatTimer;
  // Duration _heartbeatTimeout = Duration(seconds: 5);

  int _port = 4040;

  final List<Map<String, dynamic>> _historyLogs = [];
  List<TransferRecord> historyLogs = [];
  List<FileSystemEntity> _vaultFiles = [];
  late String _vaultFolderPath;

  List<PlatformFile> _selectedFilesForPhone = [];
  bool _isTransferring = false;
  double _transferProgress = 0.0;
  String _currentTransferName = "";

  @override
  void initState() {
    super.initState();
    _bootP2PHost();
  }

  // To change the vault Directory by asking user.
  Future<String> selectDirectory() async {
    String? selectedDirectory = await FilePicker.getDirectoryPath();
    if (selectedDirectory != null) {
      return selectedDirectory;
    } else {
      return "";
    }
  }

  // void _startHeartbeatCheck() {
  //   _heartbeatTimer?.cancel();

  //   _heartbeatTimer = Timer(_heartbeatTimeout, () {
  //     _terminateActiveSession();
  //     _triggerSystemToast("Error: Connection Lost", Colors.red);
  //   });
  // }

  Future<void> _bootP2PHost() async {
    final root = await getApplicationDocumentsDirectory();
    Directory vaultDir = Directory('${root.path}/ShadowSync_Vault');
    if (!await vaultDir.exists()) await vaultDir.create(recursive: true);
    _vaultFolderPath = vaultDir.path;

    _refreshVaultList();

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      String deviceIp = await NetworkDiscovery.getAvailableIp();
      setState(() {
        _serverIp = deviceIp;
      });

      _log("Listening channel active. Standing by for connection.", "sys");

      _serverSocket!.listen((Socket incomingClient) {
        if (_connectedPeerSocket != null) {
          // _log("Rejected connection attempt from ${incomingClient.remoteAddress.address} (Channel Busy)", "warn");
          _triggerSystemToast("Warning: External connection rejected. Peer session already locked.", Colors.orange);
          incomingClient.destroy();
          return;
        }
        _establishPeerSession(incomingClient);
      });
      // setState(() {});
    } catch (e) {
      _log("Boot Exception: $e", "error");
      _triggerSystemToast("Error binding server components: $e", Colors.red);
    }
  }

  void _refreshVaultList() {
    if (Directory(_vaultFolderPath).existsSync()) {
      setState(() {
        _vaultFiles = Directory(_vaultFolderPath).listSync().whereType<File>().toList();
      });
    }
  }

  void _establishPeerSession(Socket client) {
    setState(() {
      _connectedPeerSocket = client;
    });
    _triggerSystemToast("Pairing Successful with client: ${client.remoteAddress.address}", Colors.green);

    bool headerProcessed = false;
    String fileTargetName = "unknown_asset";
    int totalFileBytes = 0;
    int receivedBytesAccumulator = 0;
    IOSink? localWriterSink;
    List<int> chunkBuffer = [];

    // _startHeartbeatCheck();

    client.listen(
      (List<int> chunk) async {
        if (!headerProcessed) {
          chunkBuffer.addAll(chunk);
          String checkStr = utf8.decode(chunkBuffer, allowMalformed: true);

          if (checkStr.contains("||")) {
            try {
              final segments = checkStr.split("||");
              final metadata = segments[0].replaceAll("P2P_META:", "").split('|');
              fileTargetName = metadata[0];
              totalFileBytes = int.parse(metadata[1]);

              int metaOffset = utf8.encode("${segments[0]}||").length;
              List<int> pureDataPayload = chunkBuffer.sublist(metaOffset);

              File output = File('$_vaultFolderPath/$fileTargetName');
              localWriterSink = output.openWrite();

              setState(() {
                _isTransferring = true;
                _currentTransferName = fileTargetName;
                _transferProgress = 0.0;
              });

              headerProcessed = true;
              chunkBuffer.clear();

              if (pureDataPayload.isNotEmpty) {
                // Exact calculation math truncation logic guard check
                int bytesToAppend = pureDataPayload.length;
                if (receivedBytesAccumulator + bytesToAppend > totalFileBytes) {
                  bytesToAppend = totalFileBytes - receivedBytesAccumulator;
                }

                localWriterSink!.add(pureDataPayload.sublist(0, bytesToAppend));
                receivedBytesAccumulator += bytesToAppend;

                setState(() {
                  _transferProgress = totalFileBytes > 0
                      ? (receivedBytesAccumulator / totalFileBytes).clamp(0.0, 1.0)
                      : 0.0;
                });
              }

              if (receivedBytesAccumulator >= totalFileBytes && totalFileBytes > 0) {
                await localWriterSink!.flush();
                await localWriterSink!.close();
                _triggerSystemToast("Received file via ShadowSync: $fileTargetName", Colors.green);
                _refreshVaultList();
                setState(() {
                  _isTransferring = false;
                  _transferProgress = 0.0;
                });
                headerProcessed = false;
                receivedBytesAccumulator = 0;
              }
            } catch (e) {
              _log("Metadata separation processing fault: $e", "error");
            }
          }
        } else {
          // Continuous Stream packet writing boundary protection logic rule
          int bytesToAppend = chunk.length;
          if (receivedBytesAccumulator + bytesToAppend > totalFileBytes) {
            bytesToAppend = totalFileBytes - receivedBytesAccumulator;
          }

          localWriterSink!.add(chunk.sublist(0, bytesToAppend));
          receivedBytesAccumulator += bytesToAppend;

          setState(() {
            _transferProgress = totalFileBytes > 0 ? (receivedBytesAccumulator / totalFileBytes).clamp(0.0, 1.0) : 0.0;
          });

          if (receivedBytesAccumulator >= totalFileBytes) {
            await localWriterSink!.flush();
            await localWriterSink!.close();
            _triggerSystemToast("Recieved file via ShadowSync: $fileTargetName", Colors.green);
            // _log("Received file via P2P: $fileTargetName", "success");
            setState(() {
              historyLogs.insert(
                0,
                TransferRecord(
                  id: DateTime.now().toString(),
                  fileName: fileTargetName,
                  fileBytesSize: totalFileBytes,
                  fileExtensionType: fileTargetName.split('.').last.toUpperCase(),
                  timestamp: DateTime.now(),
                  direction: TransferDirection.receive,
                ),
              );
              _isTransferring = false;
            });

            _refreshVaultList();
            setState(() {
              _isTransferring = false;
              _transferProgress = 0.0;
            });
            headerProcessed = false;
            receivedBytesAccumulator = 0;
          }
        }
      },
      onDone: () {
        _triggerSystemToast("Peer disconnected.", Color.fromARGB(255, 173, 150, 0));
        _terminateActiveSession();
      },
      onError: (err) {
        localWriterSink?.close();
        _log("Session error: $err", "error");
        _triggerSystemToast("Error: Connection broken - $err", Colors.red);
        _terminateActiveSession();
      },
    );
  }

  void _triggerSystemToast(String message, Color badgeColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: badgeColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _selectMultipleFiles() async {
    FilePickerResult? pickResult = await FilePicker.pickFiles(type: FileType.any, allowMultiple: true);
    if (pickResult != null && pickResult.files.isNotEmpty) {
      setState(() {
        _selectedFilesForPhone = pickResult.files;
      });
    }
  }

  Future<void> _pushBatchToMobilePeer() async {
    if (_connectedPeerSocket == null || _selectedFilesForPhone.isEmpty) return;
    setState(() => _isTransferring = true);

    try {
      for (var platformFile in _selectedFilesForPhone) {
        if (platformFile.path == null) continue;

        File targetFile = File(platformFile.path!);
        String name = platformFile.name;
        int size = platformFile.size;

        setState(() {
          _currentTransferName = name;
          _transferProgress = 0.0;
        });

        _log("Streaming downstream: $name", "sys");
        _connectedPeerSocket!.write("P2P_META:$name|$size||");
        await _connectedPeerSocket!.flush();

        Stream<List<int>> streamReader = targetFile.openRead();
        int bytesPushed = 0;

        await for (List<int> packet in streamReader) {
          _connectedPeerSocket!.add(packet);
          bytesPushed += packet.length;
          setState(() {
            _transferProgress = size > 0 ? (bytesPushed / size).clamp(0.0, 1.0) : 0.0;
          });
        }
        await _connectedPeerSocket!.flush();
        setState(() {
          historyLogs.insert(
            0,
            TransferRecord(
              id: DateTime.now().toString(),
              fileName: name,
              fileBytesSize: size,
              fileExtensionType: name.split('.').last.toUpperCase(),
              timestamp: DateTime.now(),
              direction: TransferDirection.send, // Notice this is flagged as Send!
            ),
          );
        });
        _log("Asset completely transferred: $name", "success");
        await Future.delayed(const Duration(milliseconds: 300));
      }
      _log("All selected files successfully sent!", "success");
      setState(() {
        _selectedFilesForPhone.clear();
      });
    } catch (e) {
      _log("Batch transmission failure: $e", "error");
    } finally {
      setState(() {
        _isTransferring = false;
        _transferProgress = 0.0;
      });
    }
  }

  void _terminateActiveSession() {
    _connectedPeerSocket?.destroy();
    setState(() {
      _connectedPeerSocket = null;
      _isTransferring = false;
      _transferProgress = 0.0;
      _selectedFilesForPhone.clear();
    });
  }

  void _log(String message, String type) {
    setState(() {
      _historyLogs.insert(0, {
        "time": DateTime.now().toString().split(' ').last.substring(0, 8),
        "msg": message,
        "type": type,
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isPaired = _connectedPeerSocket != null;

    return Scaffold(
      body: Row(
        children: [
          // Left Sidebar Control Deck
          Container(
            width: 360,
            color: const Color(0xFF111217),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.share_rounded, size: 44, color: Color(0xFF00CEC9)),
                const SizedBox(height: 12),
                const Text("ShadowSync Desktop Host", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),

                if (!isPaired) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: QrImageView(data: "$_serverIp:$_port", version: QrVersions.auto, size: 180.0),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "Scan QR with mobile client to connect",
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: const Color(0xFF171923), borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      children: [
                        const Icon(Icons.gpp_good_rounded, size: 40, color: Colors.greenAccent),
                        const SizedBox(height: 8),
                        const Text("Channel Encrypted", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        Text(
                          "Peer: ${_connectedPeerSocket!.remoteAddress.address}",
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _isTransferring ? null : _selectMultipleFiles,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.file_copy_rounded, size: 16),
                          label: Text(
                            _selectedFilesForPhone.isEmpty
                                ? "Select Files"
                                : "${_selectedFilesForPhone.length} Selected",
                          ),
                        ),
                        if (_selectedFilesForPhone.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: _isTransferring ? null : _pushBatchToMobilePeer,

                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00CEC9),
                              foregroundColor: Colors.black,
                            ),
                            icon: const Icon(Icons.arrow_circle_up_rounded, size: 16),
                            label: const Text("Send to Phone"),
                          ),
                        ],
                        TextButton(
                          onPressed: _terminateActiveSession,
                          child: const Text("Kill Link", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const Divider(color: Colors.white10),
                const SizedBox(height: 12),
                const Text(
                  "📦 STORAGE VAULT PATH",
                  style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _serverIp == "127.0.0.1" ? "Resolving..." : _vaultFolderPath,
                  style: const TextStyle(color: Colors.white60, fontSize: 10, fontFamily: 'monospace'),
                  textAlign: TextAlign.center,
                ),
                SelectableText(
                  "(Host IP Address: ) $_serverIp:$_port",
                  style: TextStyle(color: Colors.grey, fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          // Right Split Tabs (1. Explorer Vault View | 2. Operational System Ledger)
          Expanded(
            child: DefaultTabController(
              length: 3,
              child: Container(
                color: const Color(0xFF090A0F),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // _noNetworkFound ? Text("Please connect device to a WIFI.") : Text(""),
                    const TabBar(
                      tabs: [
                        Tab(text: "📁 Recieved Data"),
                        Tab(text: "📊 Sent Data"),
                        Tab(text: "📜 Live Logs"),
                      ],
                      indicatorColor: Color(0xFF00CEC9),
                      labelColor: Color(0xFF00CEC9),
                      unselectedLabelColor: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    if (_isTransferring) ...[
                      Text(
                        "Transferring: $_currentTransferName",
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF00CEC9)),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: _transferProgress,
                              color: const Color(0xFF00CEC9),
                              backgroundColor: Colors.white12,
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            "${(_transferProgress * 100).toStringAsFixed(0)}%",
                            style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    Expanded(
                      child: TabBarView(
                        children: [
                          // TAB 1: Shared Vault Directory Local Viewer Container
                          _vaultFiles.isEmpty
                              ? const Center(
                                  child: Text(
                                    "Vault workspace is currently empty.",
                                    style: TextStyle(color: Colors.white30),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _vaultFiles.length,
                                  itemBuilder: (context, idx) {
                                    File file = _vaultFiles[idx] as File;
                                    String name = file.path.split(Platform.pathSeparator).last;
                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      child: ListTile(
                                        leading: const Icon(Icons.insert_drive_file_rounded, color: Color(0xFF00CEC9)),
                                        title: Text(
                                          name,
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                        ),
                                        subtitle: Text(
                                          "${(file.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB",
                                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.launch_rounded, color: Colors.white70, size: 18),
                                          onPressed: () =>
                                              OpenFilex.open(file.path), // Launch Native system app handler
                                          tooltip: "Open File",
                                        ),
                                      ),
                                    );
                                  },
                                ),

                          // FIX - TAB 2: Added Share History Log Array View
                          historyLogs.isEmpty
                              ? const Center(
                                  child: Text(
                                    "No file transfers recorded in this session.",
                                    style: TextStyle(color: Colors.white30),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: historyLogs.length,
                                  itemBuilder: (context, idx) {
                                    final record = historyLogs[idx];
                                    final isReceive = record.direction == TransferDirection.receive;

                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      color: const Color(0xFF13151A),
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          backgroundColor: isReceive
                                              ? Colors.green.withValues(alpha: 0.2)
                                              : Colors.blue.withValues(alpha: 0.2),
                                          child: Icon(
                                            isReceive ? Icons.download_rounded : Icons.upload_rounded,
                                            color: isReceive ? Colors.greenAccent : Colors.blueAccent,
                                          ),
                                        ),
                                        title: Text(
                                          record.fileName,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                        subtitle: Text(
                                          "${(record.fileBytesSize / (1024 * 1024)).toStringAsFixed(2)} MB • ${record.fileExtensionType}",
                                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                                        ),
                                        trailing: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: isReceive
                                                    ? Colors.green.withValues(alpha: 0.2)
                                                    : Colors.blue.withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                isReceive ? "INCOMING" : "OUTGOING",
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                  color: isReceive ? Colors.greenAccent : Colors.blueAccent,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              "${record.timestamp.hour.toString().padLeft(2, '0')}:${record.timestamp.minute.toString().padLeft(2, '0')}",
                                              style: const TextStyle(fontSize: 10, color: Colors.white30),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),

                          // TAB 3: Operational History System Log Matrix Ledger Terminal
                          ListView.builder(
                            itemCount: _historyLogs.length,
                            itemBuilder: (context, idx) {
                              final log = _historyLogs[idx];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4.0),
                                child: Text(
                                  "[${log["time"]}] ${log["msg"]}",
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white70),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
