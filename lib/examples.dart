// В мене зараз два аппбари. Мені треба його об'єднати в один. Ну тобто якусь із кнопок перенести в інший аппбар. Ну і також виправити можливі помилки. 



// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:desktop_drop/desktop_drop.dart';
// import 'package:file_picker/file_picker.dart';
// import 'package:cross_file/cross_file.dart';
// import 'package:noty/models/board_model.dart';
// import 'package:noty/models/board_items.dart';
// import 'package:noty/data/board_storage.dart';
// import 'package:url_launcher/url_launcher.dart';
// import 'package:universal_io/io.dart' as io;
// import 'package:flutter/gestures.dart';
// import 'board_painter.dart';
// import 'package:noty/models/connection_model.dart';
// import 'package:noty/screens/tab.dart';

// class CanvasBoard extends StatefulWidget {
//   final BoardModel board;
//   final Function(Connection) onOpenConnectionBoard;
//   final Function(BoardModel) onBoardUpdated;
//   final VoidCallback? onBackPressed;

//   const CanvasBoard({
//     super.key,
//     required this.board,
//     required this.onOpenConnectionBoard,
//     required this.onBoardUpdated,
//     this.onBackPressed,
//   });

//   @override
//   _CanvasBoardState createState() => _CanvasBoardState();
// }

// class _CanvasBoardState extends State<CanvasBoard>
//     with SingleTickerProviderStateMixin {
//   List<BoardItem> items = [];
//   double scale = 1.0;
//   Offset offset = Offset.zero;
//   BoardItem? selectedItem;
//   Offset? dragStartLocalPos;
//   bool _dragging = false;
//   bool _isSpacePressed = false;
//   Size? _canvasSize;
//   Offset lastTapPosition = Offset.zero;
//   DateTime? lastTapTime;
//   int tapCount = 0;
//   late TabController _tabController;
//   bool _isMenuOpen = false;
//   late FocusNode _focusNode;
//   bool _isCtrlPressed = false;
//   bool _isShiftPressed = false;
//   List<BoardItem> _linkItems = [];
//   Set<Connection> _highlightedConnections = {};

//   // Мишка
//   Offset? _selectionStart;
//   Offset? _selectionEnd;
//   final Set<BoardItem> _selectedItems = {};
//   Offset? _dragStartGlobalPos;

//   List<String> _getAllExistingTags() {
//     final allTags = <String>{};
//     for (final item in widget.board.items) {
//       allTags.addAll(item.tags!);
//     }

//     return allTags.toList()..sort();
//   }

//   @override
//   void initState() {
//     super.initState();
//     items = List.from(widget.board.items);

//     // Змінюємо довжину з 2 на 3
//     _tabController = TabController(length: 3, vsync: this); // ОНОВЛЕНО

//     _focusNode = FocusNode();
//     RawKeyboard.instance.addListener(_handleKey);
//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       if (_canvasSize != null) {
//         setState(() => offset = Offset.zero);
//       }
//     });
//   }

//   void _loadBoard() {
//     setState(() {
//       items = widget.board.items;
//     });
//   }

//   @override
//   void dispose() {
//     RawKeyboard.instance.removeListener(_handleKey);
//     _saveBoard().catchError((e) => print("Помилка збереження: $e"));
//     _tabController.dispose();
//     _focusNode.dispose();
//     super.dispose();
//   }

//   void _handleKey(RawKeyEvent event) {
//     setState(() {
//       _isSpacePressed = event.isKeyPressed(LogicalKeyboardKey.space);
//       _isCtrlPressed =
//           event.isKeyPressed(LogicalKeyboardKey.controlLeft) ||
//           event.isKeyPressed(LogicalKeyboardKey.controlRight);

//       final wasShiftPressed = _isShiftPressed;
//       _isShiftPressed =
//           event.isKeyPressed(LogicalKeyboardKey.shiftLeft) ||
//           event.isKeyPressed(LogicalKeyboardKey.shiftRight);

//       if (wasShiftPressed && !_isShiftPressed) {
//         _highlightedConnections.clear();

//         if (_linkItems.length >= 2) {
//           _showConnectionOptionsDialog();
//         }
//       }
//     });
//   }

//   Future<void> _saveBoard() async {
//     widget.board.items = List.from(items);

//     // Викликаємо onBoardUpdated після оновлення даних
//     widget.onBoardUpdated(widget.board);

//     // Далі логіка збереження...
//     final allBoards = await BoardStorage2.loadBoards();
//     final index = allBoards.indexWhere((b) => b.id == widget.board.id);
//     if (index != -1) {
//       allBoards[index] = widget.board;
//     } else {
//       allBoards.add(widget.board);
//     }
//     await BoardStorage2.saveBoards(allBoards);
//   }

//   Future<void> _pickFiles() async {
//     try {
//       FilePickerResult? result = await FilePicker.platform.pickFiles(
//         allowMultiple: true,
//         withData: false,
//       );

//       if (result != null && result.paths.isNotEmpty) {
//         List<BoardItem> newItems = [];
//         for (String? path in result.paths) {
//           if (path != null && path.isNotEmpty) {
//             final fileType = path.split('.').last.toLowerCase();
//             newItems.add(
//               BoardItem(
//                 path: path,
//                 position: Offset(100, 100 + newItems.length * 120),
//                 type: fileType,
//                 id: UniqueKey().toString(),
//               ),
//             );
//           }
//         }

//         if (newItems.isNotEmpty) {
//           setState(() => items.addAll(newItems));
//           await _saveBoard();
//         }
//       }
//     } catch (e) {
//       print('Error in _pickFiles: $e');
//       _showErrorSnackbar('Не вдалося вибрати файли: $e');
//     }
//   }

//   void _cleanUpConnections() {
//     widget.board.connections?.removeWhere((connection) {
//       return !connection.itemIds.any(
//         (id) => items.any((item) => item.id == id),
//       );
//     });
//   }

//   void _scrollToItem(BoardItem item) {
//     final itemCenter = item.position + const Offset(50, 50);
//     setState(() {
//       offset = -itemCenter * scale;
//       selectedItem = item;
//       _selectedItems.clear();
//       _selectedItems.add(item);
//     });
//   }

//   void _handleFileDrop(List<XFile> files, Offset dropPosition) {
//     if (files.isEmpty) return;

//     final localPos = _toLocal(dropPosition);

//     List<BoardItem> newItems = [];
//     for (var file in files) {
//       final path = file.path;

//       final fileType = path.split('.').last.toLowerCase();
//       newItems.add(
//         BoardItem(
//           path: path,
//           position: localPos + Offset(newItems.length * 120, 0),
//           type: fileType,
//           id: UniqueKey().toString(),
//         ),
//       );
//     }

//     if (newItems.isNotEmpty) {
//       setState(() => items.addAll(newItems));
//       _saveBoard();
//     }
//   }

//   BoardItem? _hitTestForContextMenu(Offset localPos) {
//     const hitAreaWidth = 100.0;
//     const hitAreaHeight = 100.0;

//     for (var item in items.reversed) {
//       final rect = Rect.fromLTWH(
//         item.position.dx,
//         item.position.dy,
//         hitAreaWidth,
//         hitAreaHeight,
//       );
//       if (rect.contains(localPos)) return item;
//     }
//     return null;
//   }

//   BoardItem? _hitTestForDrag(Offset localPos) {
//     const hitAreaWidth = 100.0;
//     const hitAreaHeight = 100.0;

//     for (var item in items.reversed) {
//       final rect = Rect.fromLTWH(
//         item.position.dx,
//         item.position.dy,
//         hitAreaWidth,
//         hitAreaHeight,
//       );
//       if (rect.contains(localPos)) return item;
//     }
//     return null;
//   }

//   BoardItem? _hitTestForDoubleClick(Offset localPos) {
//     const hitAreaWidth = 100.0;
//     const hitAreaHeight = 100.0;

//     for (var item in items.reversed) {
//       final rect = Rect.fromLTWH(
//         item.position.dx,
//         item.position.dy,
//         hitAreaWidth,
//         hitAreaHeight,
//       );
//       if (rect.contains(localPos)) return item;
//     }
//     return null;
//   }

//   Offset _toLocal(Offset globalPos) {
//     final center = _canvasCenter();
//     return (globalPos - center - offset) / scale;
//   }

//   Offset _canvasCenter() {
//     return _canvasSize != null
//         ? Offset(_canvasSize!.width / 2, _canvasSize!.height / 2)
//         : Offset.zero;
//   }

//   void _showContextMenu(Offset screenPos, BoardItem? item) {
//     // Якщо клікнули на елемент і він не виділений - виділяємо тільки його
//     if (item != null && !_selectedItems.contains(item)) {
//       setState(() {
//         _selectedItems.clear();
//         selectedItem = item;
//         _selectedItems.add(item);
//       });
//     }

//     showMenu(
//       context: context,
//       position: RelativeRect.fromLTRB(
//         screenPos.dx,
//         screenPos.dy,
//         _canvasSize!.width - screenPos.dx,
//         _canvasSize!.height - screenPos.dy,
//       ),
//       items: [
//         PopupMenuItem(
//           child: const Text('Видалити'),
//           onTap: () {
//             setState(() {
//               items.removeWhere((i) => _selectedItems.contains(i));
//               if (_selectedItems.contains(selectedItem)) {
//                 selectedItem = null;
//               }
//               _selectedItems.clear();
//             });
//             _saveBoard();
//           },
//         ),
//         PopupMenuItem(
//           child: const Text('Відкрити'),
//           onTap: () {
//             for (var item in _selectedItems) {
//               _openFile(item);
//             }
//           },
//         ),
//         PopupMenuItem(
//           child: const Text('Додати тег'),
//           onTap: () {
//             if (_selectedItems.length == 1) {
//               _showTagDialog(_selectedItems.first);
//             } else if (_selectedItems.length > 1) {
//               _showTagDialogForMultipleItems();
//             }
//           },
//         ),

//         PopupMenuItem(
//           child: const Text('Видалити'),
//           onTap: () {
//             setState(() {
//               items.removeWhere((i) => _selectedItems.contains(i));
//               _cleanUpConnections(); // ADDED CLEANUP
//               if (_selectedItems.contains(selectedItem)) {
//                 selectedItem = null;
//               }
//               _selectedItems.clear();
//             });
//             _saveBoard();
//           },
//         ),
//       ],
//     );
//   }

//   Future<void> _showTagDialog(BoardItem item) async {
//     final itemIndex = items.indexWhere((i) => i.id == item.id);
//     if (itemIndex == -1) return;

//     String newTag = '';
//     final allTags = _getAllExistingTags();
//     List<String> tempTags = List.from(item.tags ?? []);

//     await showDialog(
//       context: context,
//       builder: (context) {
//         return StatefulBuilder(
//           builder: (context, setStateDialog) {
//             return AlertDialog(
//               title: Text('Тег(и) для ${(item.path)}'),
//               content: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(
//                     decoration: InputDecoration(hintText: '', prefixText: '#'),
//                     onChanged: (value) => newTag = value,
//                   ),
//                   const SizedBox(height: 16),
//                   if (allTags.isNotEmpty) ...[
//                     const Text('Існуючі теги:'),
//                     const SizedBox(height: 8),
//                     Wrap(
//                       spacing: 4,
//                       children:
//                           allTags
//                               .map(
//                                 (tag) => GestureDetector(
//                                   onTap: () {
//                                     setStateDialog(() {
//                                       if (tempTags.contains(tag)) {
//                                         tempTags.remove(tag);
//                                       } else {
//                                         tempTags.add(tag);
//                                       }
//                                     });
//                                   },
//                                   child: Container(
//                                     padding: const EdgeInsets.symmetric(
//                                       horizontal: 12,
//                                       vertical: 8,
//                                     ),
//                                     decoration: BoxDecoration(
//                                       color:
//                                           tempTags.contains(tag)
//                                               ? Colors.blue[400]
//                                               : Colors.grey[300],
//                                       borderRadius: BorderRadius.circular(16),
//                                     ),
//                                     child: Text(
//                                       '#$tag',
//                                       style: TextStyle(
//                                         color:
//                                             tempTags.contains(tag)
//                                                 ? Colors.white
//                                                 : Colors.black,
//                                       ),
//                                     ),
//                                   ),
//                                 ),
//                               )
//                               .toList(),
//                     ),
//                   ],
//                 ],
//               ),
//               actions: [
//                 TextButton(
//                   onPressed: () => Navigator.pop(context),
//                   child: const Text('Скасувати'),
//                 ),
//                 TextButton(
//                   onPressed: () {
//                     setState(() {
//                       items[itemIndex] = BoardItem(
//                         id: item.id,
//                         path: item.path,
//                         position: item.position,
//                         type: item.type,
//                         tags:
//                             newTag.isNotEmpty
//                                 ? [...tempTags, newTag]
//                                 : tempTags,
//                         // links: item.links,
//                       );
//                     });
//                     Navigator.pop(context);
//                   },
//                   child: const Text('Зберегти'),
//                 ),
//               ],
//             );
//           },
//         );
//       },
//     );
//     await _saveBoard();
//   }

//   Future<void> _showTagDialogForMultipleItems() async {
//     String newTag = '';
//     final allTags = _getAllExistingTags();

//     await showDialog(
//       context: context,
//       builder: (context) {
//         return StatefulBuilder(
//           builder: (context, setStateDialog) {
//             return AlertDialog(
//               title: Text('Додати тег до ${_selectedItems.length} елементів'),
//               content: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   TextField(
//                     decoration: InputDecoration(hintText: '', prefixText: '#'),
//                     onChanged: (value) => newTag = value,
//                   ),
//                   const SizedBox(height: 16),
//                   if (allTags.isNotEmpty) ...[
//                     const Text('Існуючі теги:'),
//                     const SizedBox(height: 8),
//                     Wrap(
//                       spacing: 4,
//                       children:
//                           allTags
//                               .map(
//                                 (tag) => GestureDetector(
//                                   onTap: () {
//                                     setStateDialog(() {
//                                       newTag = tag;
//                                     });
//                                   },
//                                   child: Container(
//                                     padding: const EdgeInsets.symmetric(
//                                       horizontal: 12,
//                                       vertical: 8,
//                                     ),
//                                     decoration: BoxDecoration(
//                                       color:
//                                           newTag == tag
//                                               ? Colors.blue[400]
//                                               : Colors.grey[300],
//                                       borderRadius: BorderRadius.circular(16),
//                                     ),
//                                     child: Text(
//                                       '#$tag',
//                                       style: TextStyle(
//                                         color:
//                                             newTag == tag
//                                                 ? Colors.white
//                                                 : Colors.black,
//                                       ),
//                                     ),
//                                   ),
//                                 ),
//                               )
//                               .toList(),
//                     ),
//                   ],
//                 ],
//               ),
//               actions: [
//                 TextButton(
//                   onPressed: () => Navigator.pop(context),
//                   child: const Text('Скасувати'),
//                 ),
//                 TextButton(
//                   onPressed: () {
//                     if (newTag.isNotEmpty) {
//                       setState(() {
//                         for (var item in _selectedItems) {
//                           final index = items.indexWhere(
//                             (i) => i.id == item.id,
//                           );
//                           if (index != -1) {
//                             final currentTags = List<String>.from(
//                               items[index].tags ?? [],
//                             );
//                             if (!currentTags.contains(newTag)) {
//                               currentTags.add(newTag);
//                             }
//                             items[index] = BoardItem(
//                               id: item.id,
//                               path: item.path,
//                               position: item.position,
//                               type: item.type,
//                               tags: currentTags,
//                               // links: item.links,
//                             );
//                           }
//                         }
//                       });
//                     }
//                     Navigator.pop(context);
//                   },
//                   child: const Text('Зберегти'),
//                 ),
//               ],
//             );
//           },
//         );
//       },
//     );
//     await _saveBoard();
//   }

//   Future<void> _openFile(BoardItem item) async {
//     try {
//       final uri = Uri.file(item.path);
//       if (await canLaunchUrl(uri)) {
//         await launchUrl(uri);
//         return;
//       }

//       if (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS) {
//         final process = await io.Process.start(
//           io.Platform.isWindows ? 'explorer' : 'xdg-open',
//           [item.path],
//           runInShell: true,
//         );
//         final exitCode = await process.exitCode;
//         if (exitCode != 0) {
//           throw Exception('Не вдалося відкрити файл (код помилки: $exitCode)');
//         }
//       } else {
//         throw Exception('Платформа не підтримується');
//       }
//     } catch (e) {
//       _showErrorSnackbar('Не вдалося відкрити файл: ${e.toString()}');
//     }
//   }

//   void _showErrorSnackbar(String message) {
//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(content: Text(message), backgroundColor: Colors.red),
//     );
//   }

//   void _showCreateConnectionDialog() {
//     String connectionName = '';

//     showDialog(
//       context: context,
//       builder:
//           (context) => AlertDialog(
//             title: const Text('Створити зв\'язок'),
//             content: TextField(
//               autofocus: true,
//               decoration: const InputDecoration(
//                 hintText: 'Назва зв\'язку',
//                 border: OutlineInputBorder(),
//               ),
//               onChanged: (value) => connectionName = value,
//             ),
//             actions: [
//               TextButton(
//                 onPressed: () {
//                   setState(() => _linkItems.clear());
//                   Navigator.pop(context);
//                 },
//                 child: const Text('Скасувати'),
//               ),
//               TextButton(
//                 onPressed: () {
//                   if (connectionName.isNotEmpty) {
//                     _createConnection(connectionName);
//                   }
//                   Navigator.pop(context);
//                 },
//                 child: const Text('Зберегти'),
//               ),
//             ],
//           ),
//     );
//   }

//   // void _showMergeConnectionsDialog(List<Connection> connections) {
//   //   String newName = 'Объединенная связь';

//   //   showDialog(
//   //     context: context,
//   //     builder: (context) => AlertDialog(
//   //       title: const Text('Объединить связи'),
//   //       content: Column(
//   //         mainAxisSize: MainAxisSize.min,
//   //         children: [
//   //           TextField(
//   //             decoration: const InputDecoration(
//   //               labelText: 'Название новой связи',
//   //               border: OutlineInputBorder(),
//   //             ),
//   //             onChanged: (value) => newName = value,
//   //           ),
//   //           const SizedBox(height: 16),
//   //           Text(
//   //             'Будут объединены:',
//   //             style: Theme.of(context).textTheme.titleSmall,
//   //           ),
//   //           const SizedBox(height: 8),
//   //           ...connections.map(
//   //             (conn) => Text(
//   //               '- ${conn.name}',
//   //               style: TextStyle(
//   //                 color: _generateConnectionColor(conn.id),
//   //               ),
//   //             ),
//   //           ),
//   //         ],
//   //       ),
//   //       actions: [
//   //         TextButton(
//   //           onPressed: () => Navigator.pop(context),
//   //           child: const Text('Отмена'),
//   //         ),
//   //         TextButton(
//   //           onPressed: () {
//   //             Navigator.pop(context);
//   //             _mergeConnections(connections, newName);
//   //           },
//   //           child: const Text('Объединить'),
//   //         ),
//   //       ],
//   //     ),
//   //   );
//   // }

//   void _showConnectionOptionsDialog() {
//     // Знаходимо зв'язок тільки для ПЕРШОГО вибраного елемента
//     Connection? firstItemConnection;
//     if (_linkItems.isNotEmpty) {
//       final firstItem = _linkItems.first;
//       for (final conn in widget.board.connections ?? []) {
//         if (conn.itemIds.contains(firstItem.id)) {
//           firstItemConnection = conn;
//           break;
//         }
//       }
//     }

//     // Шукаємо незв'язані елементи (для кнопки створення нового зв'язку)
//     final List<BoardItem> unconnectedItems = [];
//     for (final item in _linkItems) {
//       bool hasConnection =
//           widget.board.connections?.any(
//             (conn) => conn.itemIds.contains(item.id),
//           ) ??
//           false;
//       if (!hasConnection) {
//         unconnectedItems.add(item);
//       }
//     }

//     // Фікс: збираємо унікальні зв'язки через where та toSet
//     final Set<Connection> uniqueConnections = {};
//     for (final item in _linkItems) {
//       final connections =
//           widget.board.connections
//               ?.where((conn) => conn.itemIds.contains(item.id))
//               .toList();

//       if (connections != null && connections.isNotEmpty) {
//         uniqueConnections.add(connections.first);
//       }
//     }
//     final canMerge = uniqueConnections.length >= 2;

//     showDialog(
//       context: context,
//       builder: (context) {
//         return AlertDialog(
//           // title: const Text('Опції зв\'язку'),
//           content: SingleChildScrollView(
//             child: Column(
//               mainAxisSize: MainAxisSize.min,
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 // Кнопка тільки для зв'язку ПЕРШОГО елемента
//                 if (firstItemConnection != null)
//                   ListTile(
//                     leading: Icon(
//                       Icons.link,
//                       color: _generateConnectionColor(firstItemConnection.id),
//                     ),
//                     title: Text('Додати до "${firstItemConnection.name}"'),
//                     onTap: () {
//                       Navigator.pop(context);
//                       _addToExistingConnection(firstItemConnection!);
//                     },
//                   ),

//                 // Кнопка об'єднання (якщо є щонайменше 2 унікальних зв'язки)
//                 if (canMerge)
//                   ListTile(
//                     leading: const Icon(Icons.merge),
//                     title: Text(
//                       'Об\'єднати ${uniqueConnections.length} зв\'язки',
//                     ),
//                     onTap: () {
//                       Navigator.pop(context);
//                       _showMergeConnectionsDialog(uniqueConnections.toList());
//                     },
//                   ),

//                 // Кнопка створення нового зв'язку
//                 ListTile(
//                   leading: const Icon(Icons.add),
//                   title: const Text('Створити новий зв\'язок'),
//                   onTap: () {
//                     Navigator.pop(context);
//                     _showCreateConnectionDialog();
//                   },
//                 ),
//               ],
//             ),
//           ),
//           actions: [
//             TextButton(
//               onPressed: () {
//                 setState(() => _linkItems.clear());
//                 Navigator.pop(context);
//               },
//               child: const Text('Скасувати'),
//             ),
//           ],
//         );
//       },
//     );
//   }

//   void _addToExistingConnection(Connection connection) {
//     setState(() {
//       for (final item in _linkItems) {
//         if (!connection.itemIds.contains(item.id)) {
//           connection.itemIds.add(item.id);
//         }
//       }
//       _linkItems.clear();
//       _saveBoard();
//     });
//   }

//   void _showMergeConnectionsDialog(List<Connection> connections) {
//     String newName = 'Об\'єднаний зв\'язок';

//     showDialog(
//       context: context,
//       builder:
//           (context) => AlertDialog(
//             title: const Text('Об\'єднати зв\'язок'),
//             content: Column(
//               mainAxisSize: MainAxisSize.min,
//               children: [
//                 TextField(
//                   decoration: const InputDecoration(
//                     labelText: 'Назва нового зв\'язку',
//                     border: OutlineInputBorder(),
//                   ),
//                   onChanged: (value) => newName = value,
//                 ),
//                 const SizedBox(height: 16),
//                 Text(
//                   'Будуть об\'єднані:',
//                   style: Theme.of(context).textTheme.titleSmall,
//                 ),
//                 const SizedBox(height: 8),
//                 ...connections.map(
//                   (conn) => Text(
//                     '- ${conn.name}',
//                     style: TextStyle(color: _generateConnectionColor(conn.id)),
//                   ),
//                 ),
//               ],
//             ),
//             actions: [
//               TextButton(
//                 onPressed: () {
//                   setState(() => _linkItems.clear());
//                   Navigator.pop(context);
//                 },
//                 child: const Text('Скасувати'),
//               ),
//               TextButton(
//                 onPressed: () {
//                   Navigator.pop(context);
//                   _mergeConnections(connections, newName);
//                 },
//                 child: const Text('Об\'єднати'),
//               ),
//             ],
//           ),
//     );
//   }

//   Color _generateConnectionColor(String id) {
//     final hash = id.hashCode;
//     return HSLColor.fromAHSL(1.0, (hash % 360).toDouble(), 0.7, 0.6).toColor();
//   }

//   void _mergeConnections(List<Connection> connections, String newName) {
//     setState(() {
//       // Собираем все ID элементов из всех связей
//       final mergedIds = <String>{};
//       for (final conn in connections) {
//         mergedIds.addAll(conn.itemIds);
//       }

//       // Добавляем текущие выбранные элементы
//       for (final item in _linkItems) {
//         mergedIds.add(item.id);
//       }

//       // Создаем новую объединенную связь
//       final mergedConnection = Connection(
//         id: UniqueKey().toString(),
//         name: newName,
//         itemIds: mergedIds.toList(),
//         boardId: widget.board.id,
//       );

//       // Удаляем старые связи
//       widget.board.connections?.removeWhere(
//         (conn) => connections.contains(conn),
//       );

//       // Добавляем новую связь
//       widget.board.connections ??= [];
//       widget.board.connections!.add(mergedConnection);

//       _linkItems.clear();
//       _saveBoard();
//     });
//   }

//   void _createConnection(String name) {
//     final newConnection = Connection(
//       id: UniqueKey().toString(),
//       name: name,
//       itemIds: _linkItems.map((item) => item.id).toList(),
//       boardId: widget.board.id,
//     );

//     setState(() {
//       widget.board.connections ??= [];
//       widget.board.connections!.add(newConnection);
//       _linkItems.clear();
//       _saveBoard();
//     });
//   }

//   // Оновлений метод _handleDoubleTap
//   void _handleDoubleTap(Offset position) {
//     final localPos = _toLocal(position);
//     final item = _hitTestForDoubleClick(localPos);

//     if (item != null) {
//       // Перевіряємо чи затиснута клавіша ALT
//       final isAltPressed = RawKeyboard.instance.keysPressed.any(
//         (key) =>
//             key == LogicalKeyboardKey.altLeft ||
//             key == LogicalKeyboardKey.altRight,
//       );

//       if (isAltPressed) {
//         _showNotesDialog(item); // Показуємо діалог нотатки
//         return;
//       }

//       // Стандартна логіка відкриття файлів
//       if (_selectedItems.contains(item)) {
//         for (var selectedItem in _selectedItems) {
//           _openFile(selectedItem);
//         }
//       } else {
//         setState(() {
//           _selectedItems.clear();
//           _selectedItems.add(item);
//         });
//         _openFile(item);
//       }
//     }
//   }

//   // Оновлений метод _handleTapDown
//   void _handleTapDown(TapDownDetails details) {
//     lastTapPosition = details.globalPosition;
//     final now = DateTime.now();

//     if (lastTapTime != null &&
//         now.difference(lastTapTime!) < Duration(milliseconds: 300)) {
//       tapCount++;
//     } else {
//       tapCount = 1;
//     }

//     lastTapTime = now;

//     if (tapCount == 2) {
//       _handleDoubleTap(details.globalPosition);
//       tapCount = 0;
//       return; // подвійний тап обробили, виходимо
//     }

//     final localPos = _toLocal(details.globalPosition);
//     final item = _hitTestForDrag(localPos);

//     // Якщо натиснуто Shift — працюємо в режимі лінкування
//     if (_isShiftPressed && item != null) {
//       setState(() {
//         if (_linkItems.contains(item)) {
//           _linkItems.remove(item);
//         } else {
//           _linkItems.add(item);
//         }

//         // Підсвічуємо всі конекшни, де є цей item
//         _highlightedConnections = _getConnectionsContainingItem(item);
//       });
//       return;
//     }

//     // Стандартна логіка виділення
//     setState(() {
//       final isMultiSelect = RawKeyboard.instance.keysPressed.any(
//         (key) =>
//             // key == LogicalKeyboardKey.controlLeft ||
//             key == LogicalKeyboardKey.shiftLeft,
//       );

//       if (item == null) {
//         if (!isMultiSelect) {
//           _selectedItems.clear();
//         }
//         selectedItem = null;
//       } else {
//         if (isMultiSelect) {
//           if (_selectedItems.contains(item)) {
//             _selectedItems.remove(item);
//           } else {
//             _selectedItems.add(item);
//           }
//         } else {
//           if (!_selectedItems.contains(item)) {
//             _selectedItems.clear();
//             _selectedItems.add(item);
//           }
//         }
//         selectedItem = item;
//       }
//     });
//   }

//   Set<Connection> _getConnectionsContainingItem(BoardItem item) {
//     return widget.board.connections
//             ?.where((conn) => conn.itemIds.contains(item.id))
//             .toSet() ??
//         {};
//   }

//   // Оновлений метод для відображення діалогу нотатки
//   void _showNotesDialog(BoardItem item) {
//     final TextEditingController controller = TextEditingController(
//       text: item.notes ?? '',
//     );

//     // Функція для відображення діалогу
//     void showNoteDialog(bool isEditing) {
//       showDialog(
//         context: context,
//         barrierDismissible: true, // Дозволяємо закрити кліком поза вікном
//         builder: (context) {
//           return StatefulBuilder(
//             builder: (context, setState) {
//               return AlertDialog(
//                 title: const Text('Нотатки до файлу'),
//                 content:
//                     isEditing
//                         ? TextField(
//                           controller: controller,
//                           maxLines: null,
//                           autofocus: true,
//                           decoration: const InputDecoration(
//                             hintText: 'Введіть опис файлу...',
//                             border: OutlineInputBorder(),
//                           ),
//                         )
//                         : SingleChildScrollView(
//                           child: Text(
//                             item.notes ?? 'Немає нотатки',
//                             style: const TextStyle(fontSize: 16),
//                           ),
//                         ),
//                 actions:
//                     isEditing
//                         ? [
//                           TextButton(
//                             onPressed: () => Navigator.pop(context),
//                             child: const Text('Скасувати'),
//                           ),
//                           TextButton(
//                             onPressed: () {
//                               setState(() {
//                                 item.notes = controller.text;
//                               });
//                               _saveBoard();
//                               Navigator.pop(
//                                 context,
//                               ); // Закриваємо поточний діалог
//                               showNoteDialog(
//                                 false,
//                               ); // Відкриваємо у режимі перегляду
//                             },
//                             child: const Text('Зберегти'),
//                           ),
//                         ]
//                         : [
//                           TextButton(
//                             onPressed: () => Navigator.pop(context),
//                             child: const Text('Закрити'),
//                           ),
//                           TextButton(
//                             onPressed: () {
//                               Navigator.pop(
//                                 context,
//                               ); // Закриваємо поточний діалог
//                               showNoteDialog(
//                                 true,
//                               ); // Відкриваємо у режимі редагування
//                             },
//                             child: const Text('Редагувати'),
//                           ),
//                         ],
//               );
//             },
//           );
//         },
//       );
//     }

//     // Відкриваємо діалог у відповідному режимі
//     showNoteDialog(item.notes?.isEmpty ?? true);
//   }

//   void _startSelection(Offset localPos) {
//     setState(() {
//       _selectionStart = localPos;
//       _selectionEnd = localPos;
//       _selectedItems.clear();
//       selectedItem = null;
//     });
//   }

//   void _updateSelection(Offset localPos) {
//     setState(() {
//       _selectionEnd = localPos;
//       _updateSelectedItems();
//     });
//   }

//   void _endSelection() {
//     setState(() {
//       _selectionStart = null;
//       _selectionEnd = null;
//     });
//   }

//   void _updateSelectedItems() {
//     if (_selectionStart == null || _selectionEnd == null) return;

//     final selectionRect = Rect.fromPoints(_selectionStart!, _selectionEnd!);
//     _selectedItems.clear();

//     const hitAreaWidth = 100.0;
//     const hitAreaHeight = 100.0;

//     for (var item in items) {
//       final itemRect = Rect.fromLTWH(
//         item.position.dx,
//         item.position.dy,
//         hitAreaWidth,
//         hitAreaHeight,
//       );
//       if (selectionRect.overlaps(itemRect)) {
//         _selectedItems.add(item);
//       }
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: Text(widget.board.title ?? 'Canvas Board'),
//         // Modified leading button with back button support
//         leading:
//             widget.onBackPressed != null
//                 ? IconButton(
//                   icon: const Icon(Icons.arrow_back),
//                   onPressed: widget.onBackPressed,
//                 )
//                 : IconButton(
//                   icon: const Icon(Icons.menu),
//                   onPressed: () => setState(() => _isMenuOpen = !_isMenuOpen),
//                 ),
//       ),
//       body: Stack(
//         children: [
//           // Main canvas content
//           LayoutBuilder(
//             builder: (context, constraints) {
//               _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
//               return DropTarget(
//                 onDragDone: (details) {
//                   final localPos = _toLocal(details.localPosition);
//                   _handleFileDrop(details.files, details.localPosition);
//                   setState(() => _dragging = false);
//                 },
//                 onDragEntered: (details) => setState(() => _dragging = true),
//                 onDragExited: (details) => setState(() => _dragging = false),
//                 child: Listener(
//                   onPointerSignal: (event) {
//                     if (event is PointerScrollEvent) {
//                       if (event.scrollDelta.dy != 0 &&
//                           event.kind == PointerDeviceKind.mouse) {
//                         final oldScale = scale;
//                         final focalPoint = event.position;
//                         final delta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
//                         double newScale = scale * delta;
//                         if (newScale < 0.5) newScale = 0.5;
//                         if (newScale > 5.0) newScale = 5.0;

//                         final focalPointScene =
//                             (focalPoint - _canvasCenter() - offset) / oldScale;

//                         setState(() {
//                           scale = newScale;
//                           offset =
//                               focalPoint -
//                               _canvasCenter() -
//                               focalPointScene * newScale;
//                         });
//                       }
//                     }
//                   },
//                   onPointerDown: (event) {
//                     if (event.kind == PointerDeviceKind.mouse &&
//                         event.buttons == kSecondaryMouseButton) {
//                       final localPos = _toLocal(event.position);
//                       final item = _hitTestForContextMenu(localPos);

//                       if (item != null) {
//                         _showContextMenu(event.position, item);
//                       } else {
//                         setState(() {
//                           _selectedItems.clear();
//                           selectedItem = null;
//                         });
//                       }
//                     }
//                   },
//                   child: Focus(
//                     focusNode: _focusNode,
//                     onKey: (node, event) {
//                       if (event is RawKeyDownEvent || event is RawKeyUpEvent) {
//                         final isSpacePressed =
//                             event.logicalKey == LogicalKeyboardKey.space;
//                         if (event is RawKeyDownEvent) {
//                           setState(() => _isSpacePressed = isSpacePressed);
//                           return KeyEventResult.handled;
//                         } else if (event is RawKeyUpEvent) {
//                           setState(() => _isSpacePressed = false);
//                           return KeyEventResult.handled;
//                         }
//                       }
//                       return KeyEventResult.ignored;
//                     },
//                     child: GestureDetector(
//                       behavior: HitTestBehavior.translucent,
//                       onTapDown: (details) {
//                         _focusNode.requestFocus();
//                         _handleTapDown(details);
//                       },
//                       onPanStart: (details) {
//                         final localPos = _toLocal(details.localPosition);

//                         // Зміна: дозволяємо пересування при Ctrl або Space
//                         if (_isSpacePressed || _isCtrlPressed) {
//                           _dragStartGlobalPos = details.localPosition;
//                           return;
//                         }

//                         selectedItem = _hitTestForDrag(localPos);
//                         if (selectedItem == null) {
//                           _startSelection(localPos);
//                         } else {
//                           dragStartLocalPos = localPos - selectedItem!.position;
//                         }
//                       },
//                       onPanUpdate: (details) {
//                         final localPos = _toLocal(details.localPosition);

//                         // Зміна: дозволяємо пересування при Ctrl або Space
//                         if (_isSpacePressed || _isCtrlPressed) {
//                           setState(() {
//                             offset +=
//                                 details.localPosition -
//                                 (_dragStartGlobalPos ?? details.localPosition);
//                             _dragStartGlobalPos = details.localPosition;
//                           });
//                           return;
//                         }

//                         if (_selectionStart != null) {
//                           _updateSelection(localPos);
//                         } else if (selectedItem != null) {
//                           setState(() {
//                             selectedItem!.position =
//                                 localPos - (dragStartLocalPos ?? Offset.zero);
//                           });
//                         }
//                       },
//                       onPanEnd: (details) {
//                         _dragStartGlobalPos = null;
//                         if (_selectionStart != null) {
//                           _endSelection();
//                         } else {
//                           selectedItem = null;
//                           dragStartLocalPos = null;
//                         }
//                         _saveBoard();
//                       },
//                       onPanCancel: () {
//                         _dragStartGlobalPos = null;
//                         if (_selectionStart != null) {
//                           _endSelection();
//                         } else {
//                           selectedItem = null;
//                           dragStartLocalPos = null;
//                         }
//                       },
//                       child: Stack(
//                         children: [
//                           Positioned.fill(
//                             child: CustomPaint(
//                               painter: BoardPainter(
//                                 items: items,
//                                 offset: offset,
//                                 scale: scale,
//                                 selectedItem: selectedItem,
//                                 selectedItems: _selectedItems,
//                                 selectionStart: _selectionStart,
//                                 selectionEnd: _selectionEnd,
//                                 linkItems: _linkItems,
//                                 highlightedConnections: _highlightedConnections,
//                                 connections:
//                                     _isShiftPressed
//                                         ? widget.board.connections
//                                         : null,
//                               ),
//                             ),
//                           ),
//                           if (_dragging)
//                             Positioned.fill(
//                               child: Container(
//                                 color: Colors.blue.withOpacity(0.2),
//                                 child: const Center(
//                                   child: Text(
//                                     'Drop files here',
//                                     style: TextStyle(
//                                       color: Colors.white,
//                                       fontSize: 24,
//                                     ),
//                                   ),
//                                 ),
//                               ),
//                             ),
//                         ],
//                       ),
//                     ),
//                   ),
//                 ),
//               );
//             },
//           ),

//           // Side menu overlay
//           if (_isMenuOpen)
//             Positioned.fill(
//               child: GestureDetector(
//                 onTap: () => setState(() => _isMenuOpen = false),
//                 child: Container(color: Colors.black.withOpacity(0.3)),
//               ),
//             ),

//           // Side menu drawer
//           AnimatedPositioned(
//             duration: const Duration(milliseconds: 200),
//             curve: Curves.easeInOut,
//             left: _isMenuOpen ? 0 : -300,
//             top: 0,
//             bottom: 0,
//             width: 300,
//             child: _buildSideMenu(),
//           ),

//           // Add button
//           if (!_isMenuOpen)
//             Positioned(
//               bottom: 20,
//               right: 20,
//               child: FloatingActionButton(
//                 onPressed: _pickFiles,
//                 child: const Icon(Icons.add),
//               ),
//             ),
//         ],
//       ),
//     );
//   }

//   Widget _buildSideMenu() {
//     return Material(
//       elevation: 8,
//       child: Column(
//         children: [
//           // Заголовок меню
//           Container(
//             color: Theme.of(context).primaryColor,
//             padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
//             child: Row(
//               children: [
//                 IconButton(
//                   icon: const Icon(Icons.close, color: Colors.white),
//                   onPressed: () => setState(() => _isMenuOpen = false),
//                 ),
//                 const SizedBox(width: 16),
//                 const Text(
//                   'Меню дошки',
//                   style: TextStyle(
//                     color: Colors.white,
//                     fontSize: 20,
//                     fontWeight: FontWeight.bold,
//                   ),
//                 ),
//               ],
//             ),
//           ),

//           // Вибір вкладок
//           Container(
//             color: Colors.grey[200],
//             child: TabBar(
//               controller: _tabController,
//               labelColor: Theme.of(context).primaryColor,
//               unselectedLabelColor: Colors.grey,
//               tabs: const [
//                 Tab(icon: Icon(Icons.file_copy), text: 'Файли'),
//                 Tab(icon: Icon(Icons.tag), text: 'Теги'),
//                 Tab(icon: Icon(Icons.link), text: 'Зв\'язки'),
//               ],
//             ),
//           ),

//           // Вміст вкладок
//           Expanded(
//             child: TabBarView(
//               controller: _tabController,
//               children: [
//                 _buildFilesTab(), // Вкладка файлів
//                 _buildTagsTab(),
//                 _buildConnectionsTab(), // Вкладка тегів
//               ],
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   Widget _buildFilesTab() {
//     if (items.isEmpty) {
//       return const Center(child: Text('Немає файлів на дошці'));
//     }

//     return ListView.builder(
//       itemCount: items.length,
//       itemBuilder: (context, index) {
//         final item = items[index];
//         final fileName = item.path.split('/').last;

//         return ListTile(
//           leading: const Icon(Icons.insert_drive_file),
//           title: Text(fileName),
//           subtitle:
//               item.tags.isNotEmpty == true
//                   ? Text(item.tags.map((t) => '#$t').join(', '))
//                   : null,
//           trailing: IconButton(
//             icon: const Icon(Icons.open_in_new),
//             onPressed: () => _openFile(item),
//           ),
//           onTap: () {
//             setState(() {
//               _isMenuOpen = false;
//               _scrollToItem(item);
//             });
//           },
//         );
//       },
//     );
//   }

//   Widget _buildTagsTab() {
//     final tags = _getAllExistingTags();

//     if (tags.isEmpty) {
//       return const Center(child: Text('Немає тегів на дошці'));
//     }

//     return ListView.builder(
//       itemCount: tags.length,
//       itemBuilder: (context, index) {
//         final tag = tags[index];
//         final itemsWithTag =
//             items.where((item) => item.tags.contains(tag) ?? false).toList();

//         return ExpansionTile(
//           leading: const Icon(Icons.tag),
//           title: Text('#$tag'),
//           subtitle: Text('${itemsWithTag.length} файл(ів)'),
//           children:
//               itemsWithTag.map((item) {
//                 final fileName = item.path.split('/').last;

//                 return ListTile(
//                   title: Text(fileName),
//                   trailing: IconButton(
//                     icon: const Icon(Icons.open_in_new),
//                     onPressed: () => _openFile(item),
//                   ),
//                   onTap: () {
//                     setState(() {
//                       _isMenuOpen = false;
//                       _scrollToItem(item);
//                     });
//                   },
//                 );
//               }).toList(),
//         );
//       },
//     );
//   }

//   Widget _buildConnectionsTab() {
//     final connections = widget.board.connections ?? [];

//     if (connections.isEmpty) {
//       return const Center(child: Text('Немає зв\'язків'));
//     }

//     return ListView.builder(
//       itemCount: connections.length,
//       itemBuilder: (context, index) {
//         final connection = connections[index];
//         return ListTile(
//           leading: const Icon(Icons.link),
//           title: Text(connection.name),
//           onTap:
//               () => widget.onOpenConnectionBoard(
//                 connection,
//               ), // Тепер тут все добре
//         );
//       },
//     );
//   }
// }




// import 'package:flutter/material.dart';
// import 'package:noty/buttons/addboard.dart';
// import 'package:noty/models/board_model.dart';
// import 'package:noty/models/connection_model.dart';
// import 'board.dart';
// import 'package:noty/data/board_storage.dart';

// class CanvasTabbedBoard extends StatefulWidget {
//   final BoardModel initialBoard;

//   const CanvasTabbedBoard({super.key, required this.initialBoard});

//   @override
//   _CanvasTabbedBoardState createState() => _CanvasTabbedBoardState();
// }

// class _CanvasTabbedBoardState extends State<CanvasTabbedBoard> {
//   late List<BoardModel> _boards;
//   late int _currentTabIndex;
//   bool _isMenuOpen = false; // доданий стан меню

//   @override
//   void initState() {
//     super.initState();
//     _boards = [widget.initialBoard];
//     _currentTabIndex = 0;
//   }

//   void _addConnectionBoard(Connection connection) {
//     final currentBoard = _boards[_currentTabIndex];

//     setState(() {
//       _boards.add(
//         BoardModel(
//           id: UniqueKey().toString(),
//           title: connection.name,
//           items:
//               currentBoard.items
//                   .where((item) => connection.itemIds.contains(item.id))
//                   .toList(),
//           isConnectionBoard: true,
//           connectionId: connection.id,
//         ),
//       );
//       _currentTabIndex = _boards.length - 1;
//     });
//   }

//   void _closeTab(int index) {
//     if (index == 0) return;

//     setState(() {
//       _boards.removeAt(index);
//       if (_currentTabIndex >= index) {
//         _currentTabIndex = (_currentTabIndex > 0) ? _currentTabIndex - 1 : 0;
//       }
//     });
//   }

//   Future<void> _saveBoard(BoardModel board) async {
//     if (!board.isConnectionBoard) {
//       try {
//         await BoardStorage2.saveBoard(board);
//       } catch (e) {
//         if (mounted) {
//           ScaffoldMessenger.of(
//             context,
//           ).showSnackBar(SnackBar(content: Text("Помилка збереження: $e")));
//         }
//       }
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         leading: Row(
//           children: [
//             IconButton(
//               icon: const Icon(Icons.list),
//               onPressed:
//                   () => Navigator.pushReplacement(
//                     context,
//                     MaterialPageRoute(builder: (context) => Addboard()),
//                   ),
//             ),
//             IconButton(
//               icon: const Icon(Icons.menu),
//               onPressed: () => setState(() => _isMenuOpen = !_isMenuOpen),
//             ),
//           ],
//         ),
//         title: const Text('Noty'),
//         bottom: PreferredSize(
//           preferredSize: const Size.fromHeight(50),
//           child: SingleChildScrollView(
//             scrollDirection: Axis.horizontal,
//             child: Row(
//               children: [
//                 for (int i = 0; i < _boards.length; i++)
//                   _TabLabel(
//                     board: _boards[i],
//                     isActive: i == _currentTabIndex,
//                     onTap: () => setState(() => _currentTabIndex = i),
//                     onClose: () => _closeTab(i),
//                     showCloseButton: i != 0,
//                   ),
//               ],
//             ),
//           ),
//         ),
//       ),
//       body: Stack(
//         children: [
//           _buildCurrentBoard(),
//           if (_isMenuOpen)
//             Positioned(
//               left: 0,
//               top: 0,
//               bottom: 0,
//               width: 300,
//               child: _buildSideMenu(),
//             ),
//         ],
//       ),
//     );
//   }

//   Widget _buildCurrentBoard() {
//     return CanvasBoard(
//       key: ValueKey(_boards[_currentTabIndex].id),
//       board: _boards[_currentTabIndex],
//       onOpenConnectionBoard: _addConnectionBoard,
//       onBoardUpdated: (BoardModel updatedBoard) {
//         setState(() => _boards[_currentTabIndex] = updatedBoard);
//         _saveBoard(updatedBoard);
//       },
//     );
//   }

//   Widget _buildSideMenu() {
//     return Container(
//       color: Colors.white,
//       padding: const EdgeInsets.all(16),
//       child: Column(
//         crossAxisAlignment: CrossAxisAlignment.start,
//         children: [
//           Text('Меню дошки', style: Theme.of(context).textTheme.headlineMedium),
//           const SizedBox(height: 20),
//           TextButton(
//             onPressed: () {
//               setState(() => _isMenuOpen = false);
//               _pickFiles(); // твоє існуюче метод для додавання файлів
//             },
//             child: const Text('Додати файли'),
//           ),
//           // ... можеш додати інші кнопки меню ...
//         ],
//       ),
//     );
//   }

//   void _pickFiles() {
//     // Реалізація вибору файлів, якщо ще немає
//   }
// }

// class _TabLabel extends StatelessWidget {
//   final BoardModel board;
//   final bool isActive;
//   final VoidCallback onTap;
//   final VoidCallback onClose;
//   final bool showCloseButton;

//   const _TabLabel({
//     super.key,
//     required this.board,
//     required this.isActive,
//     required this.onTap,
//     required this.onClose,
//     required this.showCloseButton,
//   });

//   @override
//   Widget build(BuildContext context) {
//     return Container(
//       margin: const EdgeInsets.symmetric(horizontal: 4),
//       decoration: BoxDecoration(
//         color: isActive ? Colors.blue : Colors.grey[300],
//         borderRadius: BorderRadius.circular(8),
//       ),
//       child: Row(
//         children: [
//           InkWell(
//             onTap: onTap,
//             child: Padding(
//               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
//               child: Text(
//                 board.title ?? 'Дошка',
//                 style: TextStyle(
//                   color: isActive ? Colors.white : Colors.black,
//                   fontWeight: FontWeight.bold,
//                 ),
//               ),
//             ),
//           ),
//           if (showCloseButton)
            // IconButton(
//               icon: Icon(
//                 Icons.close,
//                 size: 18,
//                 color: isActive ? Colors.white : Colors.black,
//               ),
//               onPressed: onClose,
//             ),
//         ],
//       ),
//     );
//   }
// }