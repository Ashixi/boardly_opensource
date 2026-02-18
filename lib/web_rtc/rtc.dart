import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'package:boardly/models/connection_model.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/models/board_items.dart';

class WebRTCManager {
  final String signalingServerUrl;
  final String boardId;
  final int maxPeers;

  WebSocketChannel? _channel;
  String? _myPeerId;
  bool _isConnected = false;
  bool _hasConnectedOnce = false;

  String? _myPublicId;
  String? _myUsername;

  final Queue<Future<void> Function()> _outgoingQueue = Queue();
  bool _isProcessingOutgoing = false;

  final Queue<Future<void> Function()> _incomingQueue = Queue();
  bool _isProcessingIncoming = false;

  final Map<String, RTCPeerConnection?> _peerConnections = {};
  final Map<String, RTCDataChannel?> _dataChannels = {};

  final List<Map<String, dynamic>> _pendingMessages = [];
  final Map<String, List<Map<String, dynamic>>> _peerPendingMessages = {};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};

  final List<Function(String)> _onConnectedListeners = [];
  final List<VoidCallback> _onDisconnectedListeners = [];

  Future<void> Function(String peerId, Map<String, dynamic> data)?
  _onDataReceived;

  Function(String peerId)? onConnected;
  Function(String peerId)? onDataChannelOpen;
  Function()? onDisconnected;

  Function()? onSessionFull;
  Function()? onHostLimitReached;

  final Set<String> _processedMessageIds = {};

  WebRTCManager({
    required this.signalingServerUrl,
    required this.boardId,
    this.maxPeers = 4,
  });

  bool get isConnected => _isConnected;
  bool get hasConnectedOnce => _hasConnectedOnce;
  bool get hasOpenConnections => _dataChannels.values.any(
    (channel) => channel?.state == RTCDataChannelState.RTCDataChannelOpen,
  );
  String? get myPeerId => _myPeerId;

  set onLimitReached(Null Function() onLimitReached) {}

  Future<void> connect({String? publicId, String? username}) async {
    _myPublicId = publicId;
    _myUsername = username;
    await Future.delayed(Duration.zero);

    if (_isConnected) return;
    if (_channel != null) disconnect();

    try {
      final urlStr = '$signalingServerUrl/$boardId';
      logger.i("🔌 [RTC] Connecting to: $urlStr");

      final socket = await WebSocket.connect(
        urlStr,
      ).timeout(const Duration(seconds: 5));

      logger.i("✅ [RTC] WebSocket Handshake success!");

      _channel = IOWebSocketChannel(socket);
      _isConnected = true;
      _hasConnectedOnce = true;

      _channel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);
            _handleSignalingMessage(data);
          } catch (e) {
            logger.e('WebSocket decoding error: $e');
          }
        },
        onError: (error) {
          logger.e('🔥 WebSocket Stream Error: $error');
          _notifyDisconnected();
        },
        onDone: () {
          logger.w('⚠️ WebSocket closed by server.');
          _notifyDisconnected();
        },
      );
    } on TimeoutException {
      logger.e("❌ [RTC] TIMEOUT! Сервер не відповідає за 5 сек.");
      _notifyDisconnected();
    } on SocketException catch (e) {
      logger.e("❌ [RTC] Network Error: $e");
      _notifyDisconnected();
    } catch (e) {
      logger.e("❌ [RTC] Unknown error: $e");
      _notifyDisconnected();
    }
  }

  void disconnect() {
    logger.i("🔌 RTC Disconnecting...");
    _dataChannels.values.forEach((c) => c?.close());
    _dataChannels.clear();

    _peerConnections.values.forEach((c) => c?.close());
    _peerConnections.clear();

    _channel?.sink.close();
    _channel = null;

    _incomingQueue.clear();
    _outgoingQueue.clear();
    _pendingMessages.clear();
    _peerPendingMessages.clear();
    _pendingCandidates.clear();

    logger.i("✅ RTC Disconnected completely.");
    _notifyDisconnected();
  }

  void _notifyDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    _myPeerId = null;
    for (var listener in _onDisconnectedListeners) listener();
    onDisconnected?.call();
  }

  void scheduleTask(Future<void> Function() task) {
    _outgoingQueue.add(task);
    _processOutgoingQueue();
  }

  Future<void> _processOutgoingQueue() async {
    if (_isProcessingOutgoing) return;
    _isProcessingOutgoing = true;

    while (_outgoingQueue.isNotEmpty) {
      try {
        final task = _outgoingQueue.removeFirst();
        await task();
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (e) {
        logger.e("Error executing queued task: $e");
      }
    }
    _isProcessingOutgoing = false;
  }

  Future<void> _processIncomingQueue() async {
    if (_isProcessingIncoming) return;
    _isProcessingIncoming = true;

    while (_incomingQueue.isNotEmpty) {
      try {
        final task = _incomingQueue.removeFirst();
        await task();
      } catch (e) {
        logger.e("Error processing incoming message: $e");
      }
    }
    _isProcessingIncoming = false;
  }

  void _handleSignalingMessage(Map<String, dynamic> data) {
    final type = data['type'];
    switch (type) {
      case 'connected':
        _handleConnectedMessage(data);
        break;
      case 'new-peer':
        logger.i("New peer: ${data['peer_id']}");
        break;
      case 'offer':
        _handleOfferMessage(data);
        break;
      case 'answer':
        _handleAnswerMessage(data);
        break;
      case 'candidate':
        _handleCandidateMessage(data);
        break;
      case 'peer-left':
        _removePeer(data['from']);
        break;
      case 'request-slot':
        _handleRequestSlot(data);
        break;
      case 'offer-slot':
        _handleOfferSlot(data);
        break;
      case 'session-full':
        onSessionFull?.call();
        break;
      case 'kick':
        disconnect();
        break;
    }
  }

  void _handleConnectedMessage(Map<String, dynamic> data) {
    _myPeerId = data['peer_id'];
    _isConnected = true;
    for (var listener in _onConnectedListeners) listener(_myPeerId!);

    final rawPeers = List<String>.from(data['existing_peers'] ?? []);
    final existingPeers = rawPeers.where((id) => id != _myPeerId).toList();

    for (var peerId in existingPeers) {
      _sendSignalingMessage({
        'type': 'request-slot',
        'from': _myPeerId,
        'to': peerId,
        'publicId': _myPublicId,
        'username': _myUsername,
      });
    }
  }

  void _handleRequestSlot(Map<String, dynamic> data) {
    if (_dataChannels.length < maxPeers) {
      _sendSignalingMessage({
        'type': 'offer-slot',
        'to': data['from'],
        'from': _myPeerId,
      });
    } else {
      onHostLimitReached?.call();
      _sendSignalingMessage({
        'type': 'session-full',
        'to': data['from'],
        'from': _myPeerId,
      });
    }
  }

  void _handleOfferSlot(Map<String, dynamic> data) {
    if (data['from'] != _myPeerId &&
        _dataChannels.length < maxPeers &&
        !_dataChannels.containsKey(data['from'])) {
      _createPeerConnection(data['from'], true);
    }
  }

  Future<void> _handleOfferMessage(Map<String, dynamic> data) async {
    final peerId = data['from'];
    final pc = await _createPeerConnection(peerId, false);
    if (pc == null) return;

    await pc.setRemoteDescription(
      RTCSessionDescription(data['offer']['sdp'], data['offer']['type']),
    );

    if (_pendingCandidates.containsKey(peerId)) {
      for (final c in _pendingCandidates[peerId]!) {
        await pc.addCandidate(c);
      }
      _pendingCandidates.remove(peerId);
    }

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    _sendSignalingMessage({
      'type': 'answer',
      'answer': {'sdp': answer.sdp, 'type': answer.type},
      'to': peerId,
    });
  }

  Future<void> _handleAnswerMessage(Map<String, dynamic> data) async {
    final pc = _peerConnections[data['from']];
    if (pc != null) {
      await pc.setRemoteDescription(
        RTCSessionDescription(data['answer']['sdp'], data['answer']['type']),
      );
    }
  }

  Future<void> _handleCandidateMessage(Map<String, dynamic> data) async {
    final peerId = data['from'];
    final candidate = RTCIceCandidate(
      data['candidate']['candidate'],
      data['candidate']['sdpMid'],
      data['candidate']['sdpMLineIndex'],
    );

    final pc = _peerConnections[peerId];
    if (pc == null || await pc.getRemoteDescription() == null) {
      _pendingCandidates.putIfAbsent(peerId, () => []).add(candidate);
    } else {
      await pc.addCandidate(candidate);
    }
  }

  Future<RTCPeerConnection?> _createPeerConnection(
    String peerId,
    bool isOffer,
  ) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    }, {});

    _peerConnections[peerId] = pc;

    pc.onIceCandidate =
        (c) => _sendSignalingMessage({
          'type': 'candidate',
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
          'to': peerId,
        });

    pc.onIceConnectionState = (s) {
      logger.d('RTC: ICE State with $peerId: $s');
      if (s == RTCIceConnectionState.RTCIceConnectionStateConnected) {
      } else if (s == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        pc.restartIce();
      }
    };

    await _addDataChannel(peerId, isOffer);

    if (isOffer) {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendSignalingMessage({
        'type': 'offer',
        'offer': {'sdp': offer.sdp, 'type': offer.type},
        'to': peerId,
      });
    }

    return pc;
  }

  Future<void> _addDataChannel(String peerId, bool isOffer) async {
    final pc = _peerConnections[peerId];
    if (isOffer) {
      final dc = await pc!.createDataChannel(
        'noty',
        RTCDataChannelInit()..ordered = true,
      );
      _setupDataChannelCallbacks(dc, peerId);
      _dataChannels[peerId] = dc;
    }

    pc!.onDataChannel = (dc) {
      _setupDataChannelCallbacks(dc, peerId);
      _dataChannels[peerId] = dc;
    };
  }

  void _setupDataChannelCallbacks(RTCDataChannel channel, String peerId) {
    channel.onDataChannelState = (RTCDataChannelState state) {
      logger.i("RTC: DataChannel state for $peerId changed to: $state");

      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        logger.i(
          "✅✅✅ LINK ESTABLISHED with $peerId. Sending pending messages...",
        );
        onDataChannelOpen?.call(peerId);
        _processPendingMessages(peerId);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _removePeer(peerId);
      }
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      try {
        final data = jsonDecode(message.text);
        final String? msgId = data['msgId'];
        final String? toUser = data['to'];

        // Дедуплікація повідомлень
        if (msgId != null) {
          if (_processedMessageIds.contains(msgId)) return;
          _processedMessageIds.add(msgId);
          if (_processedMessageIds.length > 500) {
            _processedMessageIds.remove(_processedMessageIds.first);
          }
        }

        // Релей (Mesh network)
        if (data['target'] == 'broadcast') {
          _relayToNeighbors(message.text, excludePeerId: peerId);
        }

        if (toUser != null && toUser != _myPeerId) {
          return;
        }

        _incomingQueue.add(() async {
          await _onDataReceived?.call(peerId, data);
        });
        _processIncomingQueue();
      } catch (e) {
        logger.e('Data channel message error: $e');
      }
    };
  }

  Future<void> syncBoardSmartly(
    String targetPeerId,
    List<BoardItem> itemsToSync,
    List<Connection> connectionsToSync,
    String? myPeerId,
  ) async {
    logger.i(
      "🚀 [Smart Sync] Starting synchronization for ${itemsToSync.length} items...",
    );

    for (final conn in connectionsToSync) {
      sendMessageToPeer(targetPeerId, {
        'type': 'folder-create',
        'folder': conn.toJson(),
      });
      await Future.delayed(const Duration(milliseconds: 50));
    }

    final sortedItems = List<BoardItem>.from(itemsToSync);
    sortedItems.sort((a, b) {
      if (a.connectionId == null && b.connectionId != null) return -1;
      if (a.connectionId != null && b.connectionId == null) return 1;
      return 0;
    });

    for (final item in sortedItems) {
      if (item.type == 'folder') continue;

      final file = File(item.originalPath);
      if (!await file.exists()) continue;

      await sendFileToPeer(
        targetPeerId,
        item.originalPath,
        item.fileName,
        file,
        fileId: item.id,
      );

      await Future.delayed(const Duration(milliseconds: 300));
    }

    logger.i("✅ [Smart Sync] Completed.");
  }

  void _relayToNeighbors(String jsonMessage, {required String excludePeerId}) {
    for (final entry in _dataChannels.entries) {
      if (entry.key == excludePeerId) continue;
      if (entry.value?.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          entry.value?.send(RTCDataChannelMessage(jsonMessage));
        } catch (_) {}
      }
    }
  }

  void _processPendingMessages(String peerId) {
    for (final msg in List.from(_pendingMessages)) {
      _sendMessageToPeer(peerId, msg);
      _pendingMessages.remove(msg);
    }
    final peerMsgs = _peerPendingMessages[peerId];
    if (peerMsgs != null) {
      for (final msg in List.from(peerMsgs)) {
        _sendMessageToPeer(peerId, msg);
        peerMsgs.remove(msg);
      }
      _peerPendingMessages.remove(peerId);
    }
  }

  void sendMessageToPeer(String peerId, Map<String, dynamic> message) {
    _sendMessageToPeer(peerId, message);
  }

  void _sendMessageToPeer(String peerId, Map<String, dynamic> message) {
    final channel = _dataChannels[peerId];
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        channel?.send(RTCDataChannelMessage(jsonEncode(message)));
      } catch (_) {}
    } else {
      _peerPendingMessages.putIfAbsent(peerId, () => []).add(message);
    }
  }

  void _broadcastMessage(Map<String, dynamic> message) {
    if (!message.containsKey('msgId')) message['msgId'] = const Uuid().v4();
    if (!message.containsKey('target')) message['target'] = 'broadcast';

    _processedMessageIds.add(message['msgId']);

    final openChannels =
        _dataChannels.values
            .where((c) => c?.state == RTCDataChannelState.RTCDataChannelOpen)
            .toList();
    if (openChannels.isEmpty) {
      _pendingMessages.add(message);
      return;
    }
    for (final channel in openChannels) {
      try {
        channel?.send(RTCDataChannelMessage(jsonEncode(message)));
      } catch (_) {}
    }
  }

  void _sendSignalingMessage(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _removePeer(String peerId) {
    _peerConnections[peerId]?.close();
    _peerConnections.remove(peerId);
    _dataChannels.remove(peerId);
    _peerPendingMessages.remove(peerId);
    _pendingCandidates.remove(peerId);
  }

  void disconnectPeer(String peerId) {
    _sendSignalingMessage({'type': 'kick', 'to': peerId, 'from': _myPeerId});
    _removePeer(peerId);
  }

  Future<void> broadcastFile(
    String originalPath,
    String fileName,
    File file, {
    String? customFileId,
    String? fileHash,
  }) async {
    final fileId =
        customFileId ??
        '${originalPath}_${DateTime.now().millisecondsSinceEpoch}';
    if (!await file.exists()) return;
    final int fileSize = await file.length();

    _broadcastMessage({
      'type': 'file-available',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileHash': fileHash,
      'originalPath': originalPath,
      'ownerPeerId': _myPeerId,
      'target': 'broadcast',
      'msgId': const Uuid().v4(),
      'isInitial': false,
    });
  }

  void requestFile(String targetPeerId, String fileId, String fileName) {
    _broadcastMessage({
      'type': 'request-file',
      'fileId': fileId,
      'fileName': fileName,
      'to': targetPeerId,
      'target': 'broadcast',
      'msgId': const Uuid().v4(),
    });
  }

  Future<void> sendFileToPeer(
    String peerId,
    String originalPath,
    String fileName,
    File file, {
    String? fileId,
    String? fileHash,
  }) async {
    scheduleTask(() async {
      logger.i("📤 Starting queued file transfer: $fileName");
      await _sendFileInternal(
        originalPath,
        fileName,
        file,
        peerId,
        customFileId: fileId,
        fileHash: fileHash,
      );
    });
  }

  Future<void> _sendFileInternal(
    String originalPath,
    String fileName,
    File file,
    String? peerId, {
    String? customFileId,
    String? fileHash,
  }) async {
    final sanitizedFileName = fileName.replaceAll(
      RegExp(r'[^\x20-\x7Eа-яА-ЯіІїЇєЄ._-]'),
      '',
    );
    final fileId =
        customFileId ??
        '${originalPath}_${DateTime.now().millisecondsSinceEpoch}';
    if (!await file.exists()) return;
    final int fileSize = await file.length();
    const int chunkSize = 32 * 1024;

    RTCDataChannel? channel;
    if (peerId != null) channel = _dataChannels[peerId];
    final String targetType = (peerId == null) ? 'broadcast' : 'direct';

    final Map<String, dynamic> startMessage = {
      'type': 'file-transfer-start',
      'fileId': fileId,
      'fileName': sanitizedFileName,
      'fileSize': fileSize,
      'fileHash': fileHash,
      'originalPath': originalPath,
      'target': targetType,
      'msgId': const Uuid().v4(),
    };

    if (peerId == null)
      _broadcastMessage(startMessage);
    else
      sendMessageToPeer(peerId, startMessage);

    await Future.delayed(const Duration(milliseconds: 100));

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      int index = 0;
      int bytesSent = 0;
      while (bytesSent < fileSize) {
        if (channel != null &&
            channel.state == RTCDataChannelState.RTCDataChannelOpen) {
          if ((channel.bufferedAmount ?? 0) > 1024 * 1024) {
            await Future.delayed(const Duration(milliseconds: 50));
            continue;
          }
        }

        final Uint8List chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;

        final base64Data = base64Encode(chunk);
        final Map<String, dynamic> chunkMessage = {
          'type': 'file-chunk',
          'fileId': fileId,
          'index': index,
          'data': base64Data,
          'target': targetType,
        };

        if (peerId == null) {
          _broadcastMessage(chunkMessage);
          await Future.delayed(const Duration(milliseconds: 5));
        } else {
          sendMessageToPeer(peerId, chunkMessage);
          if (index % 50 == 0) await Future.delayed(Duration.zero);
        }
        bytesSent += chunk.length;
        index++;
      }
    } finally {
      await raf?.close();
    }

    await Future.delayed(const Duration(milliseconds: 200));
    final endMessage = {
      'type': 'file-transfer-end',
      'fileId': fileId,
      'target': targetType,
      'msgId': const Uuid().v4(),
    };
    if (peerId == null)
      _broadcastMessage(endMessage);
    else
      sendMessageToPeer(peerId, endMessage);

    logger.i("✅ File sent successfully: $sanitizedFileName");
  }

  void sendFullBoardToPeer(String peerId, String boardJson) {
    sendMessageToPeer(peerId, {'type': 'full-board', 'board': boardJson});
  }

  void broadcastItemAdd(BoardItem item) =>
      _broadcastMessage({'type': 'item-add', 'item': item.toJson()});

  void broadcastConnectionUpdate(List<Connection> connections) {
    _broadcastMessage({
      'type': 'connection-update',
      'connections': connections.map((c) => c.toJson()).toList(),
    });
  }

  void broadcastFolderCreate(Connection folder) =>
      _broadcastMessage({'type': 'folder-create', 'folder': folder.toJson()});
  void broadcastFolderRename(String id, String oldN, String newN) =>
      _broadcastMessage({
        'type': 'folder-rename',
        'connectionId': id,
        'oldName': oldN,
        'newName': newN,
      });
  void broadcastFolderDelete(String id, String name) => _broadcastMessage({
    'type': 'folder-delete',
    'connectionId': id,
    'folderName': name,
  });
  void broadcastFileRename(String id, String oldN, String newN) =>
      _broadcastMessage({
        'type': 'file-rename',
        'fileId': id,
        'oldName': oldN,
        'newName': newN,
      });
  void broadcastItemUpdate(BoardItem item) =>
      _broadcastMessage({'type': 'item-update', 'item': item.toJson()});
  void broadcastItemDelete(String id) =>
      _broadcastMessage({'type': 'item-delete', 'id': id});
  void broadcastBoardDescriptionUpdate(String desc) => _broadcastMessage({
    'type': 'board-description-update',
    'description': desc,
  });
  void broadcastFileMove(String id, String? connId, String name) =>
      _broadcastMessage({
        'type': 'file-move',
        'fileId': id,
        'targetConnectionId': connId,
        'fileName': name,
      });

  // --- LISTENERS & DISPOSE ---

  void addConnectedListener(Function(String) listener) =>
      _onConnectedListeners.add(listener);
  void removeConnectedListener(Function(String) listener) =>
      _onConnectedListeners.remove(listener);
  void addDisconnectedListener(VoidCallback listener) =>
      _onDisconnectedListeners.add(listener);
  void removeDisconnectedListener(VoidCallback listener) =>
      _onDisconnectedListeners.remove(listener);

  set onDataReceived(
    Future<void> Function(String, Map<String, dynamic>) callback,
  ) {
    _onDataReceived = callback;
  }

  void dispose() {
    disconnect();
    _onDataReceived = null;
    onConnected = null;
    onDataChannelOpen = null;
    onDisconnected = null;
    onSessionFull = null;
    onHostLimitReached = null;
  }
}
