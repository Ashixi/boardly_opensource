import 'package:boardly/data/board_storage.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/screens/aboutdialog.dart';
import 'package:boardly/screens/host_screen.dart';
import 'package:boardly/screens/join_screen.dart';
import 'package:boardly/screens/my_boards_screen.dart';
import 'package:boardly/screens/tab.dart';
import 'package:boardly/services/board_api_service.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:flutter/material.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:boardly/services/localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'package:boardly/screens/payment_dialog.dart';

import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:boardly/widgets/policy_dialog.dart';

import 'package:boardly/screens/deletedialog.dart';

class AuthHttpClient {
  final http.Client _inner = http.Client();

  Future<http.Response> request(
    Uri url, {
    String? method,
    Map<String, String>? headers,
    dynamic body,
  }) async {
    String? accessToken = await AuthStorage.getAccessToken();
    final requestHeaders = {...?headers};
    if (accessToken != null) {
      requestHeaders['Authorization'] = 'Bearer $accessToken';
    }

    http.Response response;
    try {
      switch (method?.toUpperCase()) {
        case 'POST':
          response = await _inner.post(
            url,
            headers: requestHeaders,
            body: body,
          );
          break;
        case 'PUT':
          response = await _inner.put(url, headers: requestHeaders, body: body);
          break;
        case 'PATCH':
          response = await _inner.patch(
            url,
            headers: requestHeaders,
            body: body,
          );
          break;
        case 'DELETE':
          response = await _inner.delete(url, headers: requestHeaders);
          break;
        default:
          response = await _inner.get(url, headers: requestHeaders);
      }

      if (response.statusCode == 401) {
        final refreshed = await _refreshToken();
        if (refreshed) {
          accessToken = await AuthStorage.getAccessToken();
          if (accessToken != null) {
            requestHeaders['Authorization'] = 'Bearer $accessToken';
            switch (method?.toUpperCase()) {
              case 'POST':
                response = await _inner.post(
                  url,
                  headers: requestHeaders,
                  body: body,
                );
                break;
              case 'PUT':
                response = await _inner.put(
                  url,
                  headers: requestHeaders,
                  body: body,
                );
                break;
              case 'PATCH':
                response = await _inner.patch(
                  url,
                  headers: requestHeaders,
                  body: body,
                );
                break;
              case 'DELETE':
                response = await _inner.delete(url, headers: requestHeaders);
                break;
              default:
                response = await _inner.get(url, headers: requestHeaders);
            }
          }
        }
      }
      return response;
    } catch (e) {
      rethrow;
    }
  }

  Future<bool> _refreshToken() async {
    try {
      final refreshToken = await AuthStorage.getRefreshToken();
      if (refreshToken == null) return false;

      final response = await _inner.post(
        Uri.parse('https://boardly.studio/api/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'refresh_token': refreshToken,
          'device_id': 'default_device',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await AuthStorage.saveTokens(
          data['access_token'],
          data['refresh_token'],
        );
        return true;
      }

      if (response.statusCode == 401) {
        await AuthStorage.clearAll();
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  void close() {
    _inner.close();
  }
}

class UserData {
  final String userId;
  final String username;
  final String email;
  final String publicId;
  final bool isPro;

  UserData({
    required this.userId,
    required this.username,
    required this.email,
    required this.publicId,
    this.isPro = false,
  });

  factory UserData.fromJson(Map<String, dynamic> json) {
    return UserData(
      userId: json['user_id'] ?? '',
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      publicId: json['public_id'] ?? '',
      isPro: json['is_pro'] == true || json['is_pro'] == 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'username': username,
      'email': email,
      'public_id': publicId,
      'is_pro': isPro,
    };
  }
}

class AuthStorage {
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _userDataKey = 'user_data';

  static Future<void> saveTokens(
    String accessToken,
    String refreshToken,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    await prefs.setString(_refreshTokenKey, refreshToken);
  }

  static Future<String?> getAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessTokenKey);
  }

  static Future<String?> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey);
  }

  static Future<void> saveUserData(UserData userData) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userDataKey, jsonEncode(userData.toJson()));
  }

  static Future<UserData?> getUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final userDataJson = prefs.getString(_userDataKey);
    if (userDataJson != null) {
      try {
        final data = jsonDecode(userDataJson);
        return UserData.fromJson(data);
      } catch (e) {
        logger.e("Error parsing user data: $e");
        return null;
      }
    }
    return null;
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_userDataKey);
  }
}

class MenuStatCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String statLine1;
  final String statLine2;
  final VoidCallback? onTap;
  final bool isDisabled;

  const MenuStatCard({
    super.key,
    required this.title,
    required this.icon,
    required this.statLine1,
    required this.statLine2,
    this.onTap,
    this.isDisabled = false,
  });

  @override
  Widget build(BuildContext context) {
    const double cardWidth = 380;
    const double cardHeight = 360;

    return Card(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: isDisabled ? Colors.grey.shade200 : Colors.grey.shade300,
          width: 2.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: cardWidth,
          height: cardHeight,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 90,
                color:
                    isDisabled
                        ? Colors.grey.shade300
                        : Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 32),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: isDisabled ? Colors.grey : Colors.black87,
                ),
              ),
              const SizedBox(height: 20),
              if (!isDisabled) ...[
                Text(
                  statLine1,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  statLine2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class Addboard extends StatefulWidget {
  const Addboard({super.key});

  @override
  State<Addboard> createState() => _AddboardState();
}

class _AddboardState extends State<Addboard> with WidgetsBindingObserver {
  int _localBoardsCount = 0;
  String _localBoardsSize = "...";

  int _hostingBoardsCount = 0;
  int _joinedBoardsCount = 0;

  final String _trafficSent = "0 MB";
  final String _trafficReceived = "0 MB";

  bool _isLoggedIn = false;
  UserData? _userData;
  WebRTCManager? _webRTCManager;
  String? _rootDirectory;

  int _logoTapCount = 0;
  DateTime? _lastLogoTapTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this as WidgetsBindingObserver);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      PolicyService.checkPolicy(context);
    });
    _initStorage();
    _checkAuthStatus();
    _loadStats();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this as WidgetsBindingObserver);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshUserDataFromServer();
    }
  }

  Future<void> _refreshUserDataFromServer() async {
    if (!_isLoggedIn) return;

    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/user/me'),
      );

      if (response.statusCode == 200) {
        final userDataJson = jsonDecode(response.body);
        final newUserData = UserData.fromJson(userDataJson);

        await AuthStorage.saveUserData(newUserData);

        if (mounted) {
          setState(() {
            _userData = newUserData;
          });

          if (newUserData.isPro) {
            logger.i("Payment check: USER IS PRO NOW!");
          }
        }
      }
    } catch (e) {
      logger.e("Error refreshing user data: $e");
    } finally {
      client.close();
    }
  }

  Future<void> _loadStats() async {
    try {
      final allBoards = await BoardStorage.loadAllBoards();

      final localBoards =
          allBoards.where((b) {
            return !b.isJoined && !b.isConnectionBoard && b.ownerId == null;
          }).toList();
      allBoards.where((b) {
        return !b.isJoined && !b.isConnectionBoard && b.ownerId == null;
      }).toList();

      final hostingBoards =
          allBoards.where((b) {
            return !b.isJoined && b.ownerId != null;
          }).toList();

      final joinedBoards = allBoards.where((b) => b.isJoined == true).toList();

      int localSizeBytes = 0;
      for (var b in localBoards) {
        if (b.id != null) {
          localSizeBytes += await _calculateFolderSize(b.id!);
        }
      }

      if (mounted) {
        setState(() {
          _localBoardsCount = localBoards.length;
          _localBoardsSize = _formatBytes(localSizeBytes);

          _hostingBoardsCount = hostingBoards.length;
          _joinedBoardsCount = joinedBoards.length;
        });
      }
    } catch (e) {
      logger.e("Error loading stats: $e");
    }
  }

  Future<int> _calculateFolderSize(
    String boardId, {
    bool isConnected = false,
  }) async {
    try {
      final path = await BoardStorage.getBoardFilesDir(
        boardId,
        isConnected: isConnected,
      );
      final dir = Directory(path);
      if (!await dir.exists()) return 0;
      int size = 0;
      await for (var file in dir.list(recursive: true, followLinks: false)) {
        if (file is File) {
          size += await file.length();
        }
      }
      return size;
    } catch (e) {
      return 0;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _initStorage() async {
    final path = await BoardStorage.getRootPath();
    if (mounted) {
      setState(() {
        _rootDirectory = path;
      });
      if (path != null) _loadStats();
    }
  }

  Future<void> _pickRootDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      await BoardStorage.setRootPath(selectedDirectory);
      final newRoot = await BoardStorage.getRootPath();

      setState(() {
        _rootDirectory = newRoot;
      });
      _loadStats();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${S.t('dir_set')} $newRoot")));
      }
    }
  }

  Future<void> _checkAuthStatus() async {
    final accessToken = await AuthStorage.getAccessToken();
    final userData = await AuthStorage.getUserData();

    if (accessToken != null && userData != null) {
      setState(() {
        _isLoggedIn = true;
        _userData = userData;
      });
    }
  }

  // void _handleLogoTap() {
  //   final now = DateTime.now();
  //   if (_lastLogoTapTime != null &&
  //       now.difference(_lastLogoTapTime!) > const Duration(seconds: 1)) {
  //     _logoTapCount = 0;
  //   }

  //   _lastLogoTapTime = now;
  //   _logoTapCount++;

  //   if (_logoTapCount >= 10) {
  //     _logoTapCount = 0;
  //     _showContributorsDialog();
  //   }
  // }

  Future<void> _updateUsername(String newName) async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/user/update-me'),
        method: 'PATCH',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': newName}),
      );

      if (response.statusCode == 200) {
        final currentData = await AuthStorage.getUserData();
        if (currentData != null) {
          final newData = UserData(
            userId: currentData.userId,
            username: newName,
            email: currentData.email,
            publicId: currentData.publicId,
          );
          await AuthStorage.saveUserData(newData);
          setState(() => _userData = newData);
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.t('name_changed'))));
      }
    } catch (e) {
      logger.e("Update error: $e");
    } finally {
      client.close();
    }
  }

  Widget _buildContributorTile({
    required String name,
    required String role,
    required String socialLink,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
        child: Text(
          name[0],
          style: TextStyle(color: Theme.of(context).primaryColor),
        ),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(role),
      trailing: IconButton(
        icon: const Icon(Icons.link),
        tooltip: S.t('open_profile'),
        onPressed: () async {
          final uri = Uri.parse(socialLink);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(S.t('link_error'))));
            }
          }
        },
      ),
    );
  }

  Future<BoardModel> _createAndSaveHostingBoard(String boardName) async {
    final userData = await AuthStorage.getUserData();
    if (userData == null || userData.publicId.isEmpty) {
      throw Exception("User data not found. Please relogin.");
    }

    final boardApi = BoardApiService();

    try {
      final serverBoardData = await boardApi.createBoard(boardName);
      final String serverId = serverBoardData['id'];

      final newBoard = BoardModel(
        id: serverId,
        title: boardName,
        ownerId: userData.publicId,
        isConnectionBoard: false,
        isJoined: false,
      );

      await BoardStorage.saveBoard(newBoard, isConnectedBoard: false);
      await _loadStats();
      return newBoard;
    } on BoardLimitException {
      if (mounted) {
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: Text(S.t('limit_reached') ?? "Ліміт вичерпано"),
                content: Text(
                  S.t('limit_host_desc') ??
                      "Ви досягли ліміту створення дошок для вашого тарифу.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(S.t('cancel') ?? "Відміна"),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openProfileMenu();
                    },
                    child: Text(S.t('upgrade_pro') ?? "Оновити до Pro"),
                  ),
                ],
              ),
        );
      }
      throw Exception("Limit reached");
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _deleteBoardForHostScreen(BoardModel boardToDelete) async {
    try {
      if (boardToDelete.id != null) {
        try {
          final api = BoardApiService();
          await api.deleteBoard(boardToDelete.id!);
        } catch (e) {
          logger.w(
            "Could not delete from server (maybe offline or already deleted): $e",
          );
        }
      }

      await BoardStorage.deleteBoard(
        boardToDelete.id!,
        isConnectedBoard: false,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.t('board_deleted_success')),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadStats();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("${S.t('delete_error')}: $e")));
    }
  }

  Future<void> _openAndHostBoard(BoardModel board) async {
    _hostBoard(board);
  }

  void _hostBoard(BoardModel boardToHost) {
    if (_rootDirectory == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.t('dir_error'))));
      return;
    }

    final int limit = (_userData?.isPro == true) ? 100 : 4;

    _webRTCManager = WebRTCManager(
      signalingServerUrl: 'ws://178.18.253.94:8000/ws',
      maxPeers: limit,
      boardId: '',
    );

    _webRTCManager?.onLimitReached = () {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text("Ліміт підключень"),
                content: const Text(
                  "На цій дошці забагато людей для Free тарифу.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("OK"),
                  ),
                ],
              ),
        );
      }
    };

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => CanvasTabbedBoard(
              initialBoard: boardToHost,
              webRTCManager: _webRTCManager,
            ),
      ),
    ).then((_) => _loadStats());
  }

  Future<void> _joinToBoard(String boardId, String boardTitle) async {
    _webRTCManager = WebRTCManager(
      signalingServerUrl: 'ws://178.18.253.94:8000/ws',
      boardId: boardId,
    );
    _webRTCManager?.onLimitReached = () {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);

        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text("Доступ заборонено"),
                content: const Text(
                  "Досягнуто ліміт учасників на цій дошці.\n\n"
                  "Власник використовує безкоштовний тариф, який дозволяє лише до 3-х активних підключень одночасно.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Зрозуміло"),
                  ),
                ],
              ),
        );
      }
    };

    BoardModel joiningBoard;
    try {
      final allBoards = await BoardStorage.loadAllBoards();

      final existing = allBoards.firstWhere(
        (b) => b.id == boardId,
        orElse:
            () => BoardModel(id: boardId, title: boardTitle, isJoined: true),
      );

      joiningBoard = existing;
      joiningBoard.isJoined = true;
      joiningBoard.title = boardTitle;
    } catch (e) {
      logger.e("Error preparing board model: $e");
      joiningBoard = BoardModel(id: boardId, title: boardTitle, isJoined: true);
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => CanvasTabbedBoard(
              initialBoard: joiningBoard,
              webRTCManager: _webRTCManager,
            ),
      ),
    ).then((_) {
      _loadStats();
    });
  }

  void _navigateToMyBoardsScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MyBoardsScreen()),
    ).then((_) => _loadStats());
  }

  Future<void> _navigateToHostScreen() async {
    if (!_isLoggedIn) {
      showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(S.t('access_denied') ?? 'Увага'),
              content: Text(
                S.t('login_required_hosting') ??
                    'Будь ласка, увійдіть або зареєструйтесь.',
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(S.t('ok') ?? 'OK'),
                ),
              ],
            ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/user/me'),
      );

      if (response.statusCode == 200) {
        final userDataJson = jsonDecode(response.body);
        final newUserData = UserData.fromJson(userDataJson);
        await AuthStorage.saveUserData(newUserData);

        if (mounted) {
          setState(() {
            _userData = newUserData;
          });
        }
      }
    } catch (e) {
      logger.e("Не вдалося оновити статус: $e");
    } finally {
      client.close();
    }

    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => HostScreen(
                onOpenAndHostBoard: _openAndHostBoard,
                onAddNewAndHostBoard: _createAndSaveHostingBoard,
                onDeleteBoard: _deleteBoardForHostScreen,
                isPro: _userData?.isPro ?? false,
              ),
        ),
      ).then((_) => _loadStats());
    }
  }

  void _navigateToJoinScreen() {
    // 1. ПЕРЕВІРКА АВТОРИЗАЦІЇ
    if (!_isLoggedIn) {
      showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(S.t('access_denied') ?? 'Увага'),
              content: Text(
                S.t('login_required_hosting') ??
                    'Будь ласка, увійдіть або зареєструйтесь.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(S.t('ok') ?? 'OK'),
                ),
              ],
            ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => JoinScreen(
              onJoinBoard: _joinToBoard,
              onSelectDirectory: () async => _rootDirectory,
              isPro: _userData?.isPro ?? false,
            ),
      ),
    ).then((_) => _loadStats());
  }

  void _openProfileMenu() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final width = MediaQuery.of(context).size.width;
        final dialogWidth = width > 800 ? 500.0 : width * 0.9;
        final bool isPro = _userData?.isPro == true;

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Container(
            width: dialogWidth,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isPro)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          S.t('pro_badge'),
                          style: TextStyle(
                            color: Colors.amber[900],
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      )
                    else
                      const SizedBox(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child:
                        _isLoggedIn ? _buildProfileMenu() : _buildAuthOptions(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileMenu() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person, color: Colors.teal),
            title: Text(
              _userData?.username ?? S.t('unknown'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            subtitle: Text(S.t('username')),
            trailing: IconButton(
              icon: const Icon(Icons.edit, size: 20),
              onPressed: () {
                final controller = TextEditingController(
                  text: _userData?.username,
                );
                showDialog(
                  context: context,
                  builder:
                      (ctx) => AlertDialog(
                        title: Text(S.t('change_name')),
                        content: TextField(
                          controller: controller,
                          decoration: InputDecoration(
                            hintText: S.t('enter_new_name'),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(S.t('cancel')),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              _updateUsername(controller.text.trim());
                              Navigator.pop(ctx);
                            },
                            child: Text(S.t('save')),
                          ),
                        ],
                      ),
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.email_outlined),
            title: Text(_userData?.email ?? S.t('unknown')),
            subtitle: const Text("Email"),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: Text(
              _userData?.publicId ?? S.t('unknown'),
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(S.t('public_id_hint')),
            trailing: IconButton(
              icon: const Icon(Icons.content_copy, size: 20),
              onPressed: () {
                if (_userData?.publicId != null) {
                  Clipboard.setData(ClipboardData(text: _userData!.publicId));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(S.t('id_copied'))));
                }
              },
            ),
          ),

          ListTile(
            leading: const Icon(Icons.workspace_premium, color: Colors.amber),
            title: Text(
              S.t('manage_subscription'),
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(S.t('subscription_settings')),
            onTap: () async {
              String urlString;
              if (appLocale.value.languageCode == 'uk') {
                urlString = "https://boardly.studio/ua/profile.html";
              } else {
                urlString = "https://boardly.studio/en/login.html";
              }

              final Uri url = Uri.parse(urlString);

              if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Не вдалося відкрити сторінку"),
                    ),
                  );
                }
              }
            },
          ),

          // --------------------------------------------------
          const Divider(),
          ListTile(
            leading: const Icon(Icons.lock_reset, color: Colors.orange),
            title: Text(S.t('change_password')),
            onTap: () {
              Navigator.pop(context);
              _showForgotPasswordDialog();
            },
          ),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: Colors.redAccent),
            title: Text(S.t('logout')),
            onTap: _logout,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 20.0, bottom: 10.0),
            child: TextButton.icon(
              onPressed: () {
                bool isUserPro = _userData?.isPro ?? false;
                showDeleteAccountDialog(context, isUserPro);
              },
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              label: Text(
                S.t('delete_account'),
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                backgroundColor: Colors.red.withOpacity(0.05),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showForgotPasswordDialog() {
    final emailController = TextEditingController();
    final codeController = TextEditingController();
    final passwordController = TextEditingController();
    bool codeSent = false;
    bool isLoading = false;

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  title: Text(S.t('reset_password')),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: emailController,
                        decoration: InputDecoration(
                          labelText: S.t('your_email'),
                          prefixIcon: const Icon(Icons.email_outlined),
                        ),
                        enabled: !codeSent,
                      ),
                      if (codeSent) ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: codeController,
                          decoration: InputDecoration(
                            labelText: S.t('email_code'),
                            prefixIcon: const Icon(Icons.key),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: passwordController,
                          decoration: InputDecoration(
                            labelText: S.t('new_password'),
                            prefixIcon: const Icon(Icons.lock_outline),
                          ),
                          obscureText: true,
                        ),
                      ],
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(S.t('cancel')),
                    ),
                    ElevatedButton(
                      onPressed:
                          isLoading
                              ? null
                              : () async {
                                final email = emailController.text.trim();
                                if (email.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(S.t('enter_email'))),
                                  );
                                  return;
                                }

                                setDialogState(() => isLoading = true);
                                final client = AuthHttpClient();
                                try {
                                  if (!codeSent) {
                                    final res = await client.request(
                                      Uri.parse(
                                        "https://boardly.studio/api/auth/request-confirmation",
                                      ),
                                      method: 'POST',
                                      headers: {
                                        "Content-Type": "application/json",
                                      },
                                      body: jsonEncode({'email': email}),
                                    );
                                    if (res.statusCode == 200) {
                                      setDialogState(() => codeSent = true);
                                    } else {
                                      final msg =
                                          jsonDecode(res.body)['detail'] ??
                                          S.t('request_error');
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text(msg)),
                                      );
                                    }
                                  } else {
                                    final res = await client.request(
                                      Uri.parse(
                                        "https://boardly.studio/api/auth/reset-password",
                                      ),
                                      method: 'POST',
                                      headers: {
                                        "Content-Type": "application/json",
                                      },
                                      body: jsonEncode({
                                        'email': email,
                                        'code': codeController.text.trim(),
                                        'new_password':
                                            passwordController.text.trim(),
                                      }),
                                    );
                                    if (res.statusCode == 200) {
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            S.t('password_changed_success'),
                                          ),
                                        ),
                                      );
                                    } else {
                                      final msg =
                                          jsonDecode(res.body)['detail'] ??
                                          S.t('reset_error');
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text(msg)),
                                      );
                                    }
                                  }
                                } finally {
                                  client.close();
                                  setDialogState(() => isLoading = false);
                                }
                              },
                      child:
                          isLoading
                              ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : Text(
                                codeSent ? S.t('update_pass') : S.t('get_code'),
                              ),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _logout() {
    return AuthStorage.clearAll().then((_) {
      if (!mounted) return;
      setState(() {
        _isLoggedIn = false;
        _userData = null;
      });
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(S.t('logout_confirm'))));
    });
  }

  Widget _buildAuthOptions() {
    return Container(
      padding: const EdgeInsets.only(bottom: 32, left: 16, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _AuthSquareButton(
            title: S.t('registration'),
            icon: Icons.person_add_rounded,
            color: Colors.teal,
            onTap: _showRegistrationDialog,
            size: 180,
          ),
          const SizedBox(width: 32),
          _AuthSquareButton(
            title: S.t('login'),
            icon: Icons.login_rounded,
            color: Colors.blueAccent,
            onTap: _showLoginDialog,
            size: 180,
          ),
        ],
      ),
    );
  }

  void _showRegistrationDialog() {
    Navigator.pop(context);
    showDialog(
      context: context,
      builder:
          (BuildContext context) =>
              RegistrationDialog(onAuthSuccess: _handleAuthSuccess),
    );
  }

  void _showLoginDialog() {
    Navigator.pop(context);
    showDialog(
      context: context,
      builder:
          (BuildContext context) => LoginDialog(
            onAuthSuccess: _handleAuthSuccess,
            onForgotPassword: _showForgotPasswordDialog,
          ),
    );
  }

  Future<void> _handleAuthSuccess(
    String accessToken,
    String refreshToken,
  ) async {
    await AuthStorage.saveTokens(accessToken, refreshToken);
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/user/me'),
      );
      if (response.statusCode == 200) {
        final userDataJson = jsonDecode(response.body);
        final userData = UserData.fromJson(userDataJson);
        await AuthStorage.saveUserData(userData);
        if (!mounted) return;
        setState(() {
          _isLoggedIn = true;
          _userData = userData;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${S.t('welcome_user')} ${userData.username}!'),
          ),
        );
        return;
      }
      throw Exception('${S.t('data_fetch_error')} ${response.statusCode}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${S.t('error_prefix')} $e')));
    } finally {
      client.close();
    }
  }

  Widget _buildWithProBadge({required Widget child}) {
    if (_userData?.isPro != true) return child;

    return Stack(
      children: [
        child,
        Positioned(
          top: 20,
          right: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              S.t('pro_badge'),
              style: TextStyle(
                color: Colors.amber[900],
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  vertical: 40,
                  horizontal: 20,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      child: Container(
                        height: 100,
                        alignment: Alignment.center,
                        child: Image.asset(
                          'assets/icons/boardly_logo_horizontal.png',
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return const Text(
                              "Boardly",
                              style: TextStyle(
                                fontSize: 72,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF009688),
                                letterSpacing: -2.0,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    const SizedBox(height: 60),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 32,
                      runSpacing: 32,
                      children: [
                        MenuStatCard(
                          title: S.t('my_boards'),
                          icon: Icons.dashboard_outlined,
                          statLine1: "$_localBoardsCount ${S.t('boards')}",
                          statLine2: "${S.t('weight')}: $_localBoardsSize",
                          isDisabled: _rootDirectory == null,
                          onTap: _navigateToMyBoardsScreen,
                        ),
                        _buildWithProBadge(
                          child: MenuStatCard(
                            title: S.t('hosting'),
                            icon: Icons.cloud_upload_outlined,
                            statLine1: "$_hostingBoardsCount ${S.t('boards')}",
                            statLine2:
                                "${S.t('sent')}: $_trafficSent\n${S.t('received')}: $_trafficReceived",
                            isDisabled: _rootDirectory == null,
                            onTap: _navigateToHostScreen,
                          ),
                        ),
                        _buildWithProBadge(
                          child: MenuStatCard(
                            title: S.t('joined'),
                            icon: Icons.link_outlined,
                            statLine1: "$_joinedBoardsCount ${S.t('joined')}",
                            statLine2:
                                "${S.t('sent')}: $_trafficSent\n${S.t('received')}: $_trafficReceived",
                            isDisabled: _rootDirectory == null,
                            onTap: _navigateToJoinScreen,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 50),
                    if (_rootDirectory != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          "📂 $_rootDirectory",
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    TextButton.icon(
                      onPressed: _pickRootDirectory,
                      icon: Icon(
                        Icons.folder_open,
                        color: Colors.grey[700],
                        size: 24,
                      ),
                      label: Text(
                        _rootDirectory == null
                            ? S.t('select_dir')
                            : S.t('change_dir'),
                        style: TextStyle(
                          color: Colors.grey[800],
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 18,
                        ),
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const AboutAppDialog(),
                          );
                        },
                        icon: Icon(
                          Icons.info_outline,
                          color: Colors.grey[700],
                          size: 24,
                        ),
                        label: Text(
                          S.t('about_title'),
                          style: TextStyle(
                            color: Colors.grey[800],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 18,
                          ),
                          backgroundColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(343),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              top: 16,
              right: 64,
              child: ValueListenableBuilder<Locale>(
                valueListenable: appLocale,
                builder: (context, locale, _) {
                  return TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black87,
                      textStyle: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      appLocale.value =
                          locale.languageCode == 'uk'
                              ? const Locale('en')
                              : const Locale('uk');
                    },
                    child: Text(locale.languageCode == 'uk' ? 'UA' : 'EN'),
                  );
                },
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: _openProfileMenu,
                icon: const Icon(Icons.person, size: 28),
                tooltip: _isLoggedIn ? S.t('profile') : S.t('login'),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  foregroundColor: Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RegistrationDialog extends StatefulWidget {
  final Function(String, String) onAuthSuccess;
  const RegistrationDialog({super.key, required this.onAuthSuccess});
  @override
  State<RegistrationDialog> createState() => _RegistrationDialogState();
}

class _RegistrationDialogState extends State<RegistrationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isCodeSent = false;
  bool _isLoading = false;

  String parseErrorMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data['detail']?.toString() ?? S.t('unknown_error');
    } else if (data is List) {
      return data.map((e) => e.toString()).join(', ');
    } else {
      return data.toString();
    }
  }

  Future<void> _sendVerificationCode() async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    setState(() => _isLoading = true);
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/auth/request-confirmation'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _emailController.text}),
      );
      if (response.statusCode == 200) {
        if (!mounted) return;
        setState(() => _isCodeSent = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.t('code_sent_email'))));
        return;
      }
      dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        data = response.body;
      }
      final errorMessage = parseErrorMessage(data);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${S.t('network_error')} $e')));
    } finally {
      client.close();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    setState(() => _isLoading = true);
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/auth/register'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': _emailController.text,
          'username': _usernameController.text,
          'password': _passwordController.text,
          'email_code': _codeController.text,
        }),
      );
      dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        data = response.body;
      }

      if (response.statusCode == 200 && data is Map<String, dynamic>) {
        final accessToken = data['access_token'] as String?;
        final refreshToken = data['refresh_token'] as String?;
        if (accessToken != null && refreshToken != null) {
          widget.onAuthSuccess(accessToken, refreshToken);
          if (mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(S.t('reg_success'))));
          }
          return;
        }
      }
      final errorMessage = parseErrorMessage(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${S.t('reg_error')} $errorMessage')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${S.t('network_error')} $e')));
      }
    } finally {
      client.close();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final dialogWidth = width > 800 ? 500.0 : width * 0.9;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: dialogWidth,
        padding: const EdgeInsets.all(32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    S.t('registration'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    if (!_isCodeSent) ...[
                      TextFormField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          labelText: S.t('username'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.person_outline),
                        ),
                        validator:
                            (value) =>
                                value?.isEmpty == true
                                    ? S.t('enter_new_name')
                                    : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: S.t('email'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.email_outlined),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        validator:
                            (value) =>
                                value?.contains('@') != true
                                    ? S.t('invalid_email')
                                    : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: S.t('password'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                        validator:
                            (value) =>
                                (value?.length ?? 0) < 6
                                    ? S.t('min_6_chars')
                                    : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmPasswordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: S.t('confirm_pass'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.check_circle_outline),
                        ),
                        validator:
                            (value) =>
                                value != _passwordController.text
                                    ? S.t('pass_mismatch')
                                    : null,
                      ),
                    ] else ...[
                      TextFormField(
                        controller: _codeController,
                        decoration: InputDecoration(
                          labelText: S.t('confirm_code'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.key),
                        ),
                        keyboardType: TextInputType.number,
                        validator:
                            (value) =>
                                (value?.length ?? 0) != 6
                                    ? S.t('6_digits')
                                    : null,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  onPressed:
                      _isLoading
                          ? null
                          : (_isCodeSent ? _register : _sendVerificationCode),
                  child:
                      _isLoading
                          ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                          : Text(
                            _isCodeSent ? S.t('finish_reg') : S.t('get_code'),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _codeController.dispose();
    super.dispose();
  }
}

class LoginDialog extends StatefulWidget {
  final Function(String, String) onAuthSuccess;
  final VoidCallback onForgotPassword;
  const LoginDialog({
    super.key,
    required this.onAuthSuccess,
    required this.onForgotPassword,
  });
  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _userEmail;

  String parseErrorMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data['detail']?.toString() ?? S.t('error_prefix');
    }
    return data.toString();
  }

  Future<void> _requestCode() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailController.text.trim();
    if ([
      "ms_test_free@boardly.app",
      "ms_test_pro@boardly.app",
    ].contains(email)) {
      setState(() => _userEmail = email);
      await _completeLogin("000000");
      return;
    }

    if (!mounted) return;
    setState(() => _isLoading = true);
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse("https://boardly.studio/api/auth/request-confirmation"),
        method: 'POST',
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({'email': _emailController.text}),
      );
      if (response.statusCode == 200) {
        setState(() => _userEmail = _emailController.text);
        if (mounted) _showCodeVerificationDialog();
      } else {
        final msg = parseErrorMessage(jsonDecode(response.body));
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${S.t('error_prefix')} $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
      client.close();
    }
  }

  Future<void> _showCodeVerificationDialog() async {
    final codeController = TextEditingController();
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(S.t('confirm_code')),
            content: TextField(
              controller: codeController,
              decoration: InputDecoration(labelText: S.t('email_code')),
              keyboardType: TextInputType.number,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.t('cancel')),
              ),
              ElevatedButton(
                onPressed: () {
                  if (codeController.text.isEmpty) return;
                  Navigator.pop(context);
                  _completeLogin(codeController.text.trim());
                },
                child: Text(S.t('confirm')),
              ),
            ],
          ),
    );
    codeController.dispose();
  }

  Future<void> _completeLogin(String code) async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse("https://boardly.studio/api/auth/login"),
        method: 'POST',
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "data": {
            "email": _userEmail,
            "password": _passwordController.text,
            "email_code": code,
          },
          "device_id": "default_device",
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        widget.onAuthSuccess(data['access_token'], data['refresh_token']);
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      } else {
        final msg = parseErrorMessage(jsonDecode(response.body));
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${S.t('error_prefix')} $e')));
    } finally {
      client.close();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final dialogWidth = width > 800 ? 500.0 : width * 0.9;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: dialogWidth,
        padding: const EdgeInsets.all(32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    S.t('login'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: S.t('email'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.email_outlined),
                      ),
                      validator:
                          (v) => v?.isEmpty == true ? S.t('enter_email') : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: S.t('password'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                      validator:
                          (v) => v?.isEmpty == true ? S.t('min_6_chars') : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _isLoading ? null : _requestCode,
                  child:
                      _isLoading
                          ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                          : Text(
                            S.t('login_btn'),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onForgotPassword();
                },
                child: Text(S.t('forgot_password')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}

class _AuthSquareButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  const _AuthSquareButton({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 130,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.grey.shade300, width: 2),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        hoverColor: color.withOpacity(0.05),
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.all(size * 0.1),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: size * 0.25, color: color),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: size * 0.11,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
