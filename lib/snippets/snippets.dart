// ===============================
// 🖱️ Right-click Listener
// ===============================
// Listener(
//   onPointerDown: (PointerDownEvent event) {
//     if (event.kind == PointerDeviceKind.mouse &&
//         event.buttons == kSecondaryMouseButton) {
//       print('Right-click detected!');
//     }
//   },
//   child: Container(
//     width: 200,
//     height: 200,
//     color: Colors.blue,
//     child: Center(child: Text('Right-click me')),
//   ),
// );


// ===============================
// 👆 GestureDetector (Tap, DoubleTap, LongPress)
// ===============================
// GestureDetector(
//   onTap: () => print('Tapped'),
//   onDoubleTap: () => print('Double tapped'),
//   onLongPress: () => print('Long pressed'),
//   child: Container(
//     padding: EdgeInsets.all(16),
//     color: Colors.amber,
//     child: Text('Tap me'),
//   ),
// );


// ===============================
// 🖱️ Hover Effect (MouseRegion)
// ===============================
// MouseRegion(
//   onEnter: (_) => print('Hover enter'),
//   onExit: (_) => print('Hover exit'),
//   child: Container(
//     width: 100,
//     height: 100,
//     color: Colors.green,
//     child: Center(child: Text('Hover')),
//   ),
// );


// ===============================
// 🧭 Navigation (Push)
// ===============================
// Navigator.push(
//   context,
//   MaterialPageRoute(builder: (context) => SecondPage()),
// );


// ===============================
// 🔙 Navigation (Pop)
// ===============================
// Navigator.pop(context);


// ===============================
// 📦 Show Dialog
// ===============================
// showDialog(
//   context: context,
//   builder: (context) => AlertDialog(
//     title: Text('Title'),
//     content: Text('This is a dialog'),
//     actions: [
//       TextButton(
//         onPressed: () => Navigator.pop(context),
//         child: Text('OK'),
//       ),
//     ],
//   ),
// );


// ===============================
// 🍞 Show SnackBar
// ===============================
// ScaffoldMessenger.of(context).showSnackBar(
//   SnackBar(content: Text('Hello Snackbar')),
// );


// ===============================
// 📅 Format Date
// ===============================
// import 'package:intl/intl.dart';
// String formatted = DateFormat('yyyy-MM-dd').format(DateTime.now());


// ===============================
// 🔁 ListView.builder
// ===============================
// ListView.builder(
//   itemCount: items.length,
//   itemBuilder: (context, index) {
//     return ListTile(
//       title: Text(items[index]),
//     );
//   },
// );


// ===============================
// 🎨 Custom Button
// ===============================
// ElevatedButton(
//   onPressed: () => print('Pressed'),
//   style: ElevatedButton.styleFrom(
//     backgroundColor: Colors.deepPurple,
//     padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
//   ),
//   child: Text('Click me'),
// );