import "package:client/utils/transfer_record.dart";
import "package:flutter/material.dart";
// import "package:shadowsync/utils/transfer_record.dart";

class HistoryLogsWidget extends StatelessWidget {
  final List<TransferRecord> records;
  const HistoryLogsWidget({super.key, required this.records});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF161623),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.history_rounded, color: Colors.cyanAccent),
                SizedBox(width: 10),
                Text("TRANSACTION RECORD ARCHIVE", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
              ],
            ),
            const Divider(height: 24, color: Colors.white24),
            Expanded(
              child: records.isEmpty
                  ? const Center(
                      child: Text("No transactions recorded in this session.", style: TextStyle(color: Colors.white38)),
                    )
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final logItem = records[index];
                        final isSend = logItem.direction == TransferDirection.send;

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isSend ? const Color(0x2200CEC9) : const Color(0x226C5CE7),
                            child: Icon(
                              isSend ? Icons.arrow_upward : Icons.arrow_downward,
                              color: isSend
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            logItem.fileName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            "Format: ${logItem.fileExtensionType}  •  ${logItem.timestamp.hour}:${logItem.timestamp.minute.toString().padLeft(2, '0')}",
                            style: const TextStyle(color: Colors.white54),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                logItem.formattedSize,
                                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                              ),
                              Text(
                                isSend ? "SENT" : "RECEIVED",
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isSend
                                      ? Theme.of(context).colorScheme.secondary
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
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
