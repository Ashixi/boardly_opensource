import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:boardly/widgets/policy_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class AboutAppDialog extends StatelessWidget {
  const AboutAppDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final primaryColor = const Color(0xFF009688);
    final size = MediaQuery.of(context).size;

    final dialogWidth = (size.width * 0.4) < 350.0 ? 350.0 : (size.width * 0.4);
    final dialogHeight = size.height * 0.789;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 0,
      backgroundColor: Theme.of(context).dialogBackgroundColor,
      child: Container(
        width: dialogWidth,
        height: dialogHeight,
        child: Stack(
          children: [
            Column(
              children: [
                // 1. HEADER (Logo & Version)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
                  child: Column(
                    children: [
                      Container(
                        height: 130,
                        width: double.maxFinite,
                        alignment: Alignment.center,
                        child: Image.asset(
                          'assets/icons/boardly_logo_horizontal.png',
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return Icon(
                              Icons.layers,
                              size: 70,
                              color: primaryColor,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "v1.0.0 (Build 1)",
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                      ),
                    ],
                  ),
                ),

                const Divider(),

                // 2. SCROLLABLE CONTENT
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "Secure. Synchronized. Simple.",
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          "Boardly allows you to capture ideas and sketch in real-time. \n\n"
                          "All your data is protected with end-to-end encryption.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.6,
                            color: Colors.grey[800],
                          ),
                        ),

                        const SizedBox(height: 48),

                        // --- CORE TEAM SECTION ---
                        _buildCreditItem(
                          role: "Created & Developed by",
                          name: "Andrii Shumko",
                          linkUrl: "https://www.instagram.com/andrii_shumko/",
                          linkIcon: FontAwesomeIcons.instagram,
                          primaryColor: primaryColor,
                        ),

                        // Grouping QA together
                        Text(
                          "QA & SUPPORT TEAM",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            letterSpacing: 2.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Mykhailo
                        _buildCompactMember(
                          name: "Mykhailo Klymenko",
                          note: "QA & Testing",
                          primaryColor: primaryColor,
                        ),
                        const SizedBox(height: 16),

                        // Illia (Added)
                        _buildCompactMember(
                          name: "Andreluka Illia",
                          note: "QA & Testing",
                          linkUrl: "https://www.linkedin.com/in/illiaandreluka",
                          linkIcon: FontAwesomeIcons.linkedin,
                          primaryColor: primaryColor,
                        ),

                        const SizedBox(height: 32),

                        // --- SEPARATOR FOR DESIGNER ---
                        Row(
                          children: [
                            Expanded(child: Divider(color: Colors.grey[300])),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Icon(
                                Icons.brush,
                                size: 16,
                                color: Colors.grey[400],
                              ),
                            ),
                            Expanded(child: Divider(color: Colors.grey[300])),
                          ],
                        ),
                        const SizedBox(height: 32),

                        // --- DESIGNER (Separate Block) ---
                        _buildCreditItem(
                          role: "Visual Identity",
                          name: "Natalia Kolomiichuk",
                          note: "Logo & Icon Design", // Added context
                          linkUrl:
                              "https://www.instagram.com/design_by_kolomiichuk/",
                          linkIcon: FontAwesomeIcons.instagram,
                          primaryColor:
                              primaryColor, // Or maybe a slightly different shade to distinguish?
                        ),

                        const SizedBox(height: 32),

                        // Resources
                        Text(
                          "Resources & Assets",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 16,
                          children: [
                            _buildSmallLink("Freepik", "https://freepik.com"),
                            _buildSmallLink(
                              "Pocike (Flaticon)",
                              "https://flaticon.com/authors/pocike",
                            ),
                            _buildSmallLink(
                              "Kliwir Art",
                              "https://www.flaticon.com/authors/kliwir-art",
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 1),

                // 3. FOOTER
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 20.0,
                    horizontal: 24.0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildFooterButton(
                        context,
                        label: "Website",
                        icon: Icons.language,
                        onTap: () => _launchURL("https://boardly.studio"),
                      ),
                      const SizedBox(width: 32),
                      _buildFooterButton(
                        context,
                        label: "Privacy",
                        icon: Icons.shield_outlined,
                        onTap: () {
                          Navigator.pop(context);
                          PolicyService.showPolicy(context);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),

            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 28, color: Colors.grey),
                tooltip: 'Close',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Updated to support generic Links and Icons
  Widget _buildCreditItem({
    required String role,
    required String name,
    String? linkUrl,
    IconData? linkIcon,
    String? note,
    required Color primaryColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        children: [
          Text(
            role.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
              letterSpacing: 2.0,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: linkUrl != null ? () => _launchURL(linkUrl) : null,
                borderRadius: BorderRadius.circular(4),
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
              ),
              if (linkUrl != null && linkIcon != null) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => _launchURL(linkUrl),
                  child: FaIcon(
                    linkIcon,
                    size: 22,
                    color: primaryColor.withOpacity(0.8),
                  ),
                ),
              ],
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note,
              style: const TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: Colors.grey,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // New compact builder for the Team/QA members to keep them closer together
  Widget _buildCompactMember({
    required String name,
    required String note,
    required Color primaryColor,
    String? linkUrl,
    IconData? linkIcon,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: linkUrl != null ? () => _launchURL(linkUrl) : null,
              borderRadius: BorderRadius.circular(4),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 18, // Slightly smaller than the Lead/Designer
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
            if (linkUrl != null && linkIcon != null) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _launchURL(linkUrl),
                child: FaIcon(
                  linkIcon,
                  size: 18,
                  color: primaryColor.withOpacity(0.8),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(note, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      ],
    );
  }

  Widget _buildSmallLink(String text, String url) {
    return InkWell(
      onTap: () => _launchURL(url),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.grey,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _buildFooterButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Column(
          children: [
            Icon(icon, size: 24, color: Colors.black54),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }
}
