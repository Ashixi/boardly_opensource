import 'package:flutter/material.dart';
import 'package:boardly/services/localization.dart';

class HowToUseScreen extends StatelessWidget {
  const HowToUseScreen({super.key});

  final Color _themeColor = const Color(0xFF009688);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text(
          S.t('how_to_use_title'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildHeader(),
          const SizedBox(height: 24),

          // --- СЕКЦІЯ 1: Дії на стартовому екрані ---
          _buildSectionTitle(S.t('section_start_screen')),
          _buildUiGuideCard(
            icon: Icons.add,
            title: S.t('card_create_host_title'),
            description: S.t('card_create_host_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.add_link,
            title: S.t('card_join_title'),
            description: S.t('card_join_desc'),
          ),

          // --- СЕКЦІЯ 2: Дії всередині дошки ---
          _buildSectionTitle(S.t('section_network')),
          _buildUiGuideCard(
            icon: Icons.cloud_off,
            title: S.t('card_network_status_title'),
            description: S.t('card_network_status_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.share,
            title: S.t('card_share_id_title'),
            description: S.t('card_share_id_desc'),
          ),
          const SizedBox(height: 8),
          _buildWarningCard(
            S.t('windows_lock_title'),
            S.t('windows_lock_desc'),
          ),

          // --- СЕКЦІЯ 3: Інструменти ---
          _buildSectionTitle(S.t('section_sidebar')),
          _buildUiGuideCard(
            icon: Icons.folder_copy_outlined,
            title: S.t('card_explorer_title'),
            description: S.t('card_explorer_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.tag,
            title: S.t('card_tags_title'),
            description: S.t('card_tags_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.people_outline,
            title: S.t('card_participants_title'),
            description: S.t('card_participants_desc'),
          ),

          // --- СЕКЦІЯ 4: Файли ---
          _buildSectionTitle(S.t('section_files')),
          _buildUiGuideCard(
            icon: Icons.arrow_right_alt,
            title: S.t('card_arrows_title'),
            description: S.t('card_arrows_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.create_new_folder_outlined,
            title: S.t('card_new_file_title'),
            description: S.t('card_new_file_desc'),
          ),
          _buildUiGuideCard(
            icon: Icons.upload_file,
            title: S.t('card_upload_title'),
            description: S.t('card_upload_desc'),
          ),

          // --- СЕКЦІЯ 5: Фішки ---
          _buildSectionTitle(S.t('section_secrets')),
          _buildInfoTextCard(S.t('magic_f_key_title'), S.t('magic_f_key_desc')),

          // --- СЕКЦІЯ 6: Гарячі клавіші ---
          _buildSectionTitle(S.t('section_hotkeys')),
          _buildShortcutTable(),

          const SizedBox(height: 40),
          Center(
            child: Text(
              S.t('footer_slogan'),
              style: TextStyle(
                color: Colors.grey[400],
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _themeColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.school, size: 48, color: _themeColor),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              S.t('how_to_use_welcome'),
              style: const TextStyle(fontSize: 16, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _buildUiGuideCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Icon(icon, color: _themeColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[700],
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTextCard(String title, String content) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 22),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningCard(String title, String content) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutTable() {
    final shortcuts = [
      {"key": "Ctrl + Drag", "desc": S.t('hotkey_pan')},
      {"key": "Wheel", "desc": S.t('hotkey_zoom')},
      {"key": "F (Hold)", "desc": S.t('hotkey_folder')},
      // {"key": "M", "desc": S.t('hotkey_minimap')},
      {"key": "Alt + Click", "desc": S.t('hotkey_note')},
      {"key": "Right Click", "desc": S.t('hotkey_context')},
      {"key": "Double Click", "desc": S.t('hotkey_open')},
    ];

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children:
              shortcuts.map((s) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      Container(
                        width: 120,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Text(
                          s["key"]!,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          s["desc"]!,
                          style: TextStyle(
                            color: Colors.grey[800],
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
        ),
      ),
    );
  }
}
