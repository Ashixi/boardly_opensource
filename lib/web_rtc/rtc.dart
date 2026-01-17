import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
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

  final Map<String, RTCPeerConnection?> _peerConnections = {};
  final Map<String, RTCDataChannel?> _dataChannels = {};
  final List<Map<String, dynamic>> _pendingMessages = [];
  final List<Map<String, dynamic>> _pendingFiles = [];
  final Map<String, List<Map<String, dynamic>>> _peerPendingMessages = {};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};

  final List<Function(String)> _onConnectedListeners = [];
  final List<VoidCallback> _onDisconnectedListeners = [];

  Function(String peerId, Map<String, dynamic> data)? _onDataReceived;
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
    for (final channel in _dataChannels.values) {
      try {
        channel?.close();
      } catch (_) {}
    }
    _dataChannels.clear();
    for (final pc in _peerConnections.values) {
      try {
        pc?.close();
      } catch (_) {}
    }
    _peerConnections.clear();
    _channel?.sink.close();
    _channel = null;
    _pendingCandidates.clear();
    _peerPendingMessages.clear();
    _pendingMessages.clear();
    _pendingFiles.clear();

    _notifyDisconnected();
  }

  void _notifyDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    _myPeerId = null;
    for (var listener in _onDisconnectedListeners) {
      listener();
    }
  }

  void _handleConnectedMessage(Map<String, dynamic> data) {
    _myPeerId = data['peer_id'];
    _isConnected = true;

    for (var listener in _onConnectedListeners) {
      listener(_myPeerId!);
    }

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

  void disconnectPeer(String peerId) {
    _sendSignalingMessage({'type': 'kick', 'to': peerId, 'from': _myPeerId});
    _removePeer(peerId);
  }

  void _handleRequestSlot(Map<String, dynamic> data) {
    if (_dataChannels.length < maxPeers) {
      final requesterId = data['from'];
      logger.i("RTC: Accepted slot request from $requesterId");
      _sendSignalingMessage({
        'type': 'offer-slot',
        'to': requesterId,
        'from': _myPeerId,
      });
    } else {
      logger.w("RTC: Rejected slot request (Max connections reached).");

      onHostLimitReached?.call();

      _sendSignalingMessage({
        'type': 'session-full',
        'to': data['from'],
        'from': _myPeerId,
      });
    }
  }

  String _generateMsgId() {
    return const Uuid().v4();
  }

  void _handleOfferSlot(Map<String, dynamic> data) {
    final potentialParentId = data['from'];

    if (potentialParentId == _myPeerId) {
      return;
    }

    if (_dataChannels.length < 3) {
      if (!_dataChannels.containsKey(potentialParentId)) {
        logger.i("RTC: Connecting to mesh peer: $potentialParentId");
        _createPeerConnection(potentialParentId, true);
      } else {
        logger.w("RTC: Already connected/connecting to $potentialParentId");
      }
    }
  }

  void _handleSignalingMessage(Map<String, dynamic> data) {
    final type = data['type'];
    if (type != 'candidate') {
      logger.i("📥 RTC MSG: $type from ${data['from'] ?? 'server'}");
    }

    switch (type) {
      case 'connected':
        _handleConnectedMessage(data);
        break;
      case 'new-peer':
        logger.i(
          "RTC: 👋 New peer joined the room: ${data['peer_id'] ?? data['from']}",
        );
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
        logger.i("RTC: Peer left: ${data['from']}");
        _removePeer(data['from']);
        break;
      case 'request-slot':
        _handleRequestSlot(data);
        break;
      case 'offer-slot':
        _handleOfferSlot(data);
        break;
      case 'session-full':
        logger.w("RTC: Session is full. Access denied.");
        onSessionFull?.call();
        break;
      case 'kick':
        logger.w("⚠️ You have been disconnected by the host.");
        disconnect();
        break;
    }
  }

  Future<void> _handleOfferMessage(Map<String, dynamic> data) async {
    final peerId = data['from'];
    final offer = data['offer'];
    logger.i("RTC: Handling OFFER from $peerId");

    final pc = await _createPeerConnection(peerId, false);
    if (pc == null) return;

    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );
      if (_pendingCandidates.containsKey(peerId)) {
        for (final candidate in _pendingCandidates[peerId]!) {
          await pc.addCandidate(candidate);
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
    } catch (e) {
      logger.e('Error handling offer: $e');
    }
  }

  Future<void> _handleAnswerMessage(Map<String, dynamic> data) async {
    final peerId = data['from'];
    final answer = data['answer'];
    logger.i("RTC: Handling ANSWER from $peerId");

    final pc = _peerConnections[peerId];
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
    } catch (e) {
      logger.e('Error handling answer: $e');
    }
  }

  Future<void> _handleCandidateMessage(Map<String, dynamic> data) async {
    final peerId = data['from'];
    final candidateMap = data['candidate'];
    final candidate = RTCIceCandidate(
      candidateMap['candidate'],
      candidateMap['sdpMid'],
      candidateMap['sdpMLineIndex'],
    );
    final pc = _peerConnections[peerId];

    if (pc == null || (await pc.getRemoteDescription()) == null) {
      if (!_pendingCandidates.containsKey(peerId)) {
        _pendingCandidates[peerId] = [];
      }
      _pendingCandidates[peerId]!.add(candidate);
      return;
    }
    await pc.addCandidate(candidate);
  }

  Future<RTCPeerConnection?> _createPeerConnection(
    String peerId,
    bool isOffer,
  ) async {
    try {
      final configuration = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {
            'urls': 'turn:178.18.253.94:3478',
            'username': 'admin',
            'credential': 'password123',
          },
        ],
        'iceTransportPolicy': 'all',
      };

      final pc = await createPeerConnection(configuration, {});
      _peerConnections[peerId] = pc;

      pc.onIceCandidate = (candidate) {
        _sendSignalingMessage({
          'type': 'candidate',
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
          'to': peerId,
        });
      };

      pc.onIceConnectionState = (state) {
        logger.i("RTC: ICE Connection State with $peerId: $state");
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
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
    } catch (e) {
      logger.e('Error creating PC: $e');
      return null;
    }
  }

  Future<void> _addDataChannel(String peerId, bool isOffer) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    if (isOffer) {
      final dc = await pc.createDataChannel(
        'noty',
        RTCDataChannelInit()..ordered = true,
      );
      _setupDataChannelCallbacks(dc, peerId);
      _dataChannels[peerId] = dc;
    }

    pc.onDataChannel = (channel) {
      _setupDataChannelCallbacks(channel, peerId);
      _dataChannels[peerId] = channel;
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
        logger.w("RTC: Link closed with $peerId");
        _removePeer(peerId);
      }
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      try {
        final data = jsonDecode(message.text);
        final String? msgId = data['msgId'];
        final String? toUser = data['to'];

        if (msgId != null) {
          if (_processedMessageIds.contains(msgId)) return;
          _processedMessageIds.add(msgId);
          if (_processedMessageIds.length > 500) {
            _processedMessageIds.remove(_processedMessageIds.first);
          }
        }

        if (data['target'] == 'broadcast') {
          _relayToNeighbors(message.text, excludePeerId: peerId);
        }

        if (toUser != null && toUser != _myPeerId) {
          return;
        }

        _onDataReceived?.call(peerId, data);
      } catch (e) {
        logger.e('Data channel message error: $e');
      }
    };
  }

  void _relayToNeighbors(String jsonMessage, {required String excludePeerId}) {
    for (final entry in _dataChannels.entries) {
      final targetId = entry.key;
      final channel = entry.value;

      if (targetId == excludePeerId) continue;

      if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          channel?.send(RTCDataChannelMessage(jsonMessage));
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
      if (!_peerPendingMessages.containsKey(peerId)) {
        _peerPendingMessages[peerId] = [];
      }
      _peerPendingMessages[peerId]!.add(message);
    }
  }

  void _broadcastMessage(Map<String, dynamic> message) {
    if (!message.containsKey('msgId')) {
      message['msgId'] = _generateMsgId();
    }
    if (!message.containsKey('target')) {
      message['target'] = 'broadcast';
    }

    final msgId = message['msgId'];
    _processedMessageIds.add(msgId);

    final openChannels =
        _dataChannels.values
            .where((c) => c?.state == RTCDataChannelState.RTCDataChannelOpen)
            .toList();

    if (openChannels.isEmpty) {
      _pendingMessages.add(message);
      return;
    }

    bool sentAny = false;
    for (final channel in openChannels) {
      try {
        channel?.send(RTCDataChannelMessage(jsonEncode(message)));
        sentAny = true;
      } catch (e) {
        logger.e("RTC: Send failed: $e");
      }
    }

    if (!sentAny) {
      _pendingMessages.add(message);
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

    if (!await file.exists()) {
      logger.e("❌ File not found for announcing: ${file.path}");
      return;
    }

    final int fileSize = await file.length();

    final announcement = {
      'type': 'file-available',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileHash': fileHash,
      'originalPath': originalPath,
      'ownerPeerId': _myPeerId,
      'target': 'broadcast',
      'msgId': _generateMsgId(),
      'isInitial': false,
    };

    _broadcastMessage(announcement);
    logger.i(
      "📢 Announced file availability: $fileName (Size: $fileSize, Hash: $fileHash)",
    );
  }

  void requestFile(String targetPeerId, String fileId, String fileName) {
    logger.i("📥 REQUEST: Asking $targetPeerId for file $fileName");

    _broadcastMessage({
      'type': 'request-file',
      'fileId': fileId,
      'fileName': fileName,
      'to': targetPeerId,
      'target': 'broadcast',
      'msgId': _generateMsgId(),
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
    await _sendFileInternal(
      originalPath,
      fileName,
      file,
      peerId,
      customFileId: fileId,
      fileHash: fileHash,
    );
  }

  Future<void> _sendFileInternal(
    String originalPath,
    String fileName,
    File file,
    String? peerId, {
    String? customFileId,
    String? fileHash,
  }) async {
    final fileId =
        customFileId ??
        '${originalPath}_${DateTime.now().millisecondsSinceEpoch}';

    if (!await file.exists()) {
      logger.e("❌ File not found for sending: ${file.path}");
      return;
    }

    final int fileSize = await file.length();
    const int chunkSize = 16 * 1024;

    bool useRelay = false;
    RTCDataChannel? channel;

    if (peerId != null) {
      channel = _dataChannels[peerId];
      if (channel == null) useRelay = true;
    }

    final String targetType =
        (peerId == null || useRelay) ? 'broadcast' : 'direct';

    final Map<String, dynamic> startMessage = {
      'type': 'file-transfer-start',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileHash': fileHash,
      'originalPath': originalPath,
      'target': targetType,
      'msgId': _generateMsgId(),
    };

    if (useRelay || peerId == null) {
      _broadcastMessage(startMessage);
    } else {
      sendMessageToPeer(peerId, startMessage);
    }

    await Future.delayed(const Duration(milliseconds: 100));

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      int index = 0;
      int bytesSent = 0;

      while (bytesSent < fileSize) {
        if (channel != null &&
            channel.state == RTCDataChannelState.RTCDataChannelOpen) {
          int? buffered = channel.bufferedAmount;
          while (buffered != null && buffered > 256 * 1024) {
            await Future.delayed(const Duration(milliseconds: 10));
            buffered = channel.bufferedAmount;
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
          'msgId': _generateMsgId(),
        };

        try {
          if (useRelay || peerId == null) {
            _broadcastMessage(chunkMessage);
            await Future.delayed(const Duration(milliseconds: 5));
          } else {
            sendMessageToPeer(peerId, chunkMessage);
            if (index % 10 == 0)
              await Future.delayed(const Duration(milliseconds: 1));
          }
        } catch (e) {
          logger.e("Error sending chunk: $e");
          break;
        }

        bytesSent += chunk.length;
        index++;
      }
    } catch (e) {
      logger.e("Error streaming file: $e");
    } finally {
      await raf?.close();
    }

    await Future.delayed(const Duration(milliseconds: 200));

    final Map<String, dynamic> endMessage = {
      'type': 'file-transfer-end',
      'fileId': fileId,
      'target': targetType,
      'msgId': _generateMsgId(),
    };

    if (useRelay || peerId == null) {
      _broadcastMessage(endMessage);
    } else {
      sendMessageToPeer(peerId, endMessage);
    }

    logger.i("✅ File sent successfully: $fileName");
  }

  void addConnectedListener(Function(String) listener) {
    _onConnectedListeners.add(listener);
  }

  void removeConnectedListener(Function(String) listener) {
    _onConnectedListeners.remove(listener);
  }

  void addDisconnectedListener(VoidCallback listener) {
    _onDisconnectedListeners.add(listener);
  }

  void removeDisconnectedListener(VoidCallback listener) {
    _onDisconnectedListeners.remove(listener);
  }

  void sendFullBoardToPeer(String peerId, String boardJson) {
    sendMessageToPeer(peerId, {'type': 'full-board', 'board': boardJson});
  }

  void sendFullBoard(String boardJson) {
    _broadcastMessage({'type': 'full-board', 'board': boardJson});
  }

  void broadcastItemUpdate(BoardItem item) {
    _broadcastMessage({'type': 'item-update', 'item': item.toJson()});
  }

  void broadcastConnectionUpdate(List<Connection> connections) {
    _broadcastMessage({
      'type': 'connection-update',
      'connections': connections.map((c) => c.toJson()).toList(),
    });
  }

  void broadcastItemAdd(BoardItem item) {
    _broadcastMessage({'type': 'item-add', 'item': item.toJson()});
  }

  void broadcastItemDelete(String itemId) {
    _broadcastMessage({'type': 'item-delete', 'id': itemId});
  }

  void broadcastBoardDescriptionUpdate(String description) {
    _broadcastMessage({
      'type': 'board-description-update',
      'description': description,
    });
  }

  void broadcastFullFileContent(String filePath, String contentBase64) {
    _broadcastMessage({
      'type': 'full-file-content',
      'path': filePath,
      'content_base64': contentBase64,
    });
  }

  void broadcastFileTransferStart(
    String fileId,
    String fileName,
    int fileSize,
    String originalPath,
  ) {
    _broadcastMessage({
      'type': 'file-transfer-start',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'originalPath': originalPath,
    });
  }

  void broadcastFileChunk(String fileId, int index, String base64Data) {
    _broadcastMessage({
      'type': 'file-chunk',
      'fileId': fileId,
      'index': index,
      'data': base64Data,
    });
  }

  void broadcastFileRename(String fileId, String oldName, String newName) {
    _broadcastMessage({
      'type': 'file-rename',
      'fileId': fileId,
      'oldName': oldName,
      'newName': newName,
    });
  }

  void broadcastFolderRename(
    String connectionId,
    String oldName,
    String newName,
  ) {
    _broadcastMessage({
      'type': 'folder-rename',
      'connectionId': connectionId,
      'oldName': oldName,
      'newName': newName,
    });
  }

  void broadcastFileTransferEnd(String fileId) {
    _broadcastMessage({'type': 'file-transfer-end', 'fileId': fileId});
  }

  set onDataReceived(Function(String, Map<String, dynamic>) callback) {
    _onDataReceived = callback;
  }

  void dispose() {
    disconnect();
    _onDataReceived = null;
    onConnected = null;
    onDataChannelOpen = null;
    onDisconnected = null;
    // Очищаємо нові колбеки
    onSessionFull = null;
    onHostLimitReached = null;
  }
}
