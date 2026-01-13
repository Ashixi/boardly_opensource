// import 'dart:convert';
// import 'package:flutter/material.dart';
// import 'package:url_launcher/url_launcher.dart';
// import 'package:boardly/screens/start_screen.dart';
// import 'package:boardly/services/localization.dart';

// enum PaymentMode { none, single, team, gift }

// class PaymentDialog extends StatefulWidget {
//   const PaymentDialog({super.key});

//   @override
//   State<PaymentDialog> createState() => _PaymentDialogState();
// }

// class _PaymentDialogState extends State<PaymentDialog> {
//   final TextEditingController _friendIdController = TextEditingController();
//   final List<String> _friendIds = [];
//   bool _isLoading = false;
//   PaymentMode _mode = PaymentMode.none;

//   void _addFriend() {
//     final id = _friendIdController.text.trim();
//     if (id.isNotEmpty && !_friendIds.contains(id)) {
//       setState(() {
//         _friendIds.add(id);
//         _friendIdController.clear();
//       });
//     }
//   }

//   void _removeFriend(String id) {
//     setState(() {
//       _friendIds.remove(id);
//     });
//   }

//   void _resetMode() {
//     setState(() {
//       _mode = PaymentMode.none;
//       _friendIds.clear();
//       _friendIdController.clear();
//     });
//   }

//   Future<void> _initiatePayment() async {
//     if ((_mode == PaymentMode.team || _mode == PaymentMode.gift) &&
//         _friendIds.isEmpty) {
//       ScaffoldMessenger.of(
//         context,
//       ).showSnackBar(SnackBar(content: Text(S.t('add_one_friend_error'))));
//       return;
//     }

//     setState(() => _isLoading = true);
//     final client = AuthHttpClient();

//     try {
//       final bool includePayer = _mode != PaymentMode.gift;

//       final response = await client.request(
//         Uri.parse(
//           'https://boardly.studio/api/auth/payment/create-checkout-session',
//         ),
//         method: 'POST',
//         headers: {'Content-Type': 'application/json'},
//         body: jsonEncode({
//           'friend_public_ids': _friendIds,
//           'include_payer': includePayer,
//         }),
//       );

//       if (response.statusCode == 200) {
//         final data = jsonDecode(response.body);
//         final String? checkoutUrl = data['checkout_url'];

//         if (checkoutUrl != null) {
//           final uri = Uri.parse(checkoutUrl);
//           if (await canLaunchUrl(uri)) {
//             await launchUrl(uri, mode: LaunchMode.externalApplication);

//             if (mounted) {
//               Navigator.pop(context);
//               ScaffoldMessenger.of(
//                 context,
//               ).showSnackBar(SnackBar(content: Text(S.t('pro_redirect'))));
//             }
//           } else {
//             throw S.t('link_open_error');
//           }
//         }
//       } else {
//         final error =
//             jsonDecode(response.body)['detail'] ?? S.t('server_error');
//         if (mounted) {
//           ScaffoldMessenger.of(context).showSnackBar(
//             SnackBar(content: Text("${S.t('error_prefix')} $error")),
//           );
//         }
//       }
//     } catch (e) {
//       if (mounted) {
//         ScaffoldMessenger.of(
//           context,
//         ).showSnackBar(SnackBar(content: Text("${S.t('network_error')} $e")));
//       }
//     } finally {
//       client.close();
//       if (mounted) setState(() => _isLoading = false);
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     if (_mode == PaymentMode.none) {
//       return AlertDialog(
//         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//         title: Row(
//           children: [
//             const Icon(Icons.star, color: Colors.amber),
//             const SizedBox(width: 10),
//             Text(S.t('pro_title')),
//           ],
//         ),
//         content: Column(
//           mainAxisSize: MainAxisSize.min,
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             Text(
//               S.t('choose_sub_type'),
//               style: const TextStyle(fontWeight: FontWeight.bold),
//             ),
//             const SizedBox(height: 20),

//             // 1. Одиночна
//             ElevatedButton.icon(
//               icon: const Icon(Icons.person),
//               label: Text(S.t('sub_single')),
//               style: ElevatedButton.styleFrom(
//                 padding: const EdgeInsets.symmetric(vertical: 12),
//               ),
//               onPressed: () {
//                 setState(() {
//                   _mode = PaymentMode.single;
//                 });
//                 _initiatePayment();
//               },
//             ),
//             const SizedBox(height: 10),

//             ElevatedButton.icon(
//               icon: const Icon(Icons.group_add),
//               label: Text(S.t('sub_team')),
//               style: ElevatedButton.styleFrom(
//                 padding: const EdgeInsets.symmetric(vertical: 12),
//               ),
//               onPressed: () {
//                 setState(() {
//                   _mode = PaymentMode.team;
//                 });
//               },
//             ),
//             const SizedBox(height: 10),

//               // 3. Подарункова
//             ElevatedButton.icon(
//               icon: const Icon(Icons.card_giftcard),
//               label: Text(S.t('sub_gift')),
//               style: ElevatedButton.styleFrom(
//                 padding: const EdgeInsets.symmetric(vertical: 12),
//               ),
//               onPressed: () {
//                 setState(() {
//                   _mode = PaymentMode.gift;
//                 });
//               },
//             ),
//           ],
//         ),
//         actions: [
//           TextButton(
//             onPressed: () => Navigator.pop(context),
//             child: Text(S.t('cancel')),
//           ),
//         ],
//       );
//     }

//     // Лоадер для одиночної підписки
//     if (_mode == PaymentMode.single) {
//       return Center(
//         child: AlertDialog(
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.circular(20),
//           ),
//           content: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               const CircularProgressIndicator(),
//               const SizedBox(height: 20),
//               Text(S.t('processing')),
//             ],
//           ),
//         ),
//       );
//     }

//     // Інтерфейс додавання друзів
//     final bool includeSelf = _mode == PaymentMode.team;
//     final totalQuantity = (includeSelf ? 1 : 0) + _friendIds.length;

//     String titleText = "";
//     if (_mode == PaymentMode.team) titleText = S.t('sub_team');
//     if (_mode == PaymentMode.gift) titleText = S.t('gift_friends');

//     return AlertDialog(
//       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//       title: Row(
//         children: [
//           IconButton(
//             icon: const Icon(Icons.arrow_back),
//             padding: EdgeInsets.zero,
//             constraints: const BoxConstraints(),
//             onPressed: _isLoading ? null : _resetMode,
//           ),
//           const SizedBox(width: 10),
//           Text(titleText, style: const TextStyle(fontSize: 18)),
//         ],
//       ),
//       content: SingleChildScrollView(
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             Text(
//               S.t('pro_desc'),
//               style: const TextStyle(fontSize: 14, color: Colors.grey),
//             ),
//             const SizedBox(height: 20),

//             Text(
//               S.t('add_friend_label'),
//               style: const TextStyle(fontWeight: FontWeight.bold),
//             ),
//             Row(
//               children: [
//                 Expanded(
//                   child: TextField(
//                     controller: _friendIdController,
//                     decoration: InputDecoration(
//                       hintText: S.t('enter_id_hint'),
//                       isDense: true,
//                     ),
//                   ),
//                 ),
//                 IconButton(
//                   icon: const Icon(Icons.add_circle, color: Colors.teal),
//                   onPressed: _addFriend,
//                 ),
//               ],
//             ),

//             if (_friendIds.isNotEmpty) ...[
//               const SizedBox(height: 10),
//               Container(
//                 decoration: BoxDecoration(
//                   border: Border.all(color: Colors.grey.shade300),
//                   borderRadius: BorderRadius.circular(8),
//                 ),
//                 child: Column(
//                   children:
//                       _friendIds
//                           .map(
//                             (id) => ListTile(
//                               dense: true,
//                               title: Text(id),
//                               trailing: IconButton(
//                                 icon: const Icon(
//                                   Icons.close,
//                                   size: 16,
//                                   color: Colors.red,
//                                 ),
//                                 onPressed: () => _removeFriend(id),
//                               ),
//                             ),
//                           )
//                           .toList(),
//                 ),
//               ),
//             ],

//             const SizedBox(height: 20),
//             const Divider(),
//             Row(
//               mainAxisAlignment: MainAxisAlignment.spaceBetween,
//               children: [
//                 Text(
//                   S.t('total_accounts'),
//                   style: const TextStyle(fontWeight: FontWeight.bold),
//                 ),
//                 // Логіка підсумку з перекладом
//                 Text(
//                   _mode == PaymentMode.gift
//                       ? "$totalQuantity (${S.t('users')}: ${_friendIds.length})"
//                       : "$totalQuantity (${S.t('username')} + ${_friendIds.length})",
//                 ),
//               ],
//             ),
//           ],
//         ),
//       ),
//       actions: [
//         TextButton(
//           onPressed: _isLoading ? null : () => Navigator.pop(context),
//           child: Text(S.t('cancel')),
//         ),
//         ElevatedButton(
//           style: ElevatedButton.styleFrom(
//             backgroundColor: Colors.amber,
//             foregroundColor: Colors.black,
//           ),
//           onPressed: _isLoading ? null : _initiatePayment,
//           child:
//               _isLoading
//                   ? const SizedBox(
//                     width: 20,
//                     height: 20,
//                     child: CircularProgressIndicator(strokeWidth: 2),
//                   )
//                   : Text(S.t('buy_pro')),
//         ),
//       ],
//     );
//   }
// }
