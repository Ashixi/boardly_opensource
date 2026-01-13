// import 'package:flutter/material.dart';
// import 'package:flutter/gestures.dart';
// import 'package:noty/models/board_model.dart';
// import 'package:noty/screens/board.dart';

// class RightClickExample extends StatefulWidget {
//   @override
//   RightClickExampleState createState() => RightClickExampleState();
// }

// class RightClickExampleState extends State<RightClickExample> {
//   OverlayEntry? _contextMenu;

//   void showContextMenu(BuildContext context, Offset position) {
//     hideContextMenu();
//     List<BoardModel>;

//     _contextMenu = OverlayEntry(
//       builder:
//           (context) => Positioned(
//             left: position.dx,
//             top: position.dy,
//             child: Material(
//               elevation: 4,
//               child: Container(
//                 width: 120,
//                 color: Colors.white,
//                 child: Column(
//                   children: [TextButton(onPressed: , child: Text('delete'))],
//                 ),
//               ),
//             ),
//           ),
//     );

//     Overlay.of(context).insert(_contextMenu!);
//   }

//   void hideContextMenu() {
//     _contextMenu?.remove();
//     _contextMenu = null;
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Listener(
//       onPointerDown: (PointerDownEvent event) {
//         if (event.kind == PointerDeviceKind.mouse &&
//             event.buttons == kSecondaryMouseButton) {
//           showContextMenu(context, event.position);
//         } else {
//           hideContextMenu();
//         }
//       },
//       child: Center(child: Text("Правий клік відкриває меню")),
//     );
//   }
// }
