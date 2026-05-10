import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ShieldVPNApp());
}

class ShieldVPNApp extends StatelessWidget {
  const ShieldVPNApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShieldVPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0a0e2e),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  // VPN state — используем String вместо enum V2RayStatus
  String _vpnStatus = 'disconnected';
  String _selectedServer = 'Авто-оптимальный';
  String _subscriptionUrl = '';
  int _currentIndex = 0;
  List<Map<String, dynamic>> _parsedConfigs = [];
  Map<String, dynamic>? _activeConfig;
  String _uploadSpeed = '0 KB/s';
  String _downloadSpeed = '0 KB/s';

  late FlutterV2ray _flutterV2ray;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Статичные серверы — используются если нет подписки
  final List<Map<String, String>> _staticServers = [
    {'name': 'Авто-оптимальный', 'flag': '⚡', 'ping': 'авто'},
    {'name': 'Finland Helsinki', 'flag': '🇫🇮', 'ping': '32ms'},
    {'name': 'Germany Nürnberg', 'flag': '🇩🇪', 'ping': '45ms'},
    {'name': 'Germany Falkenstein', 'flag': '🇩🇪', 'ping': '48ms'},
    {'name': 'Russia Moscow', 'flag': '🇷🇺', 'ping': '18ms'},
    {'name': 'Russia SPb', 'flag': '🇷🇺', 'ping': '22ms'},
    {'name': 'Sweden LTE', 'flag': '🇸🇪', 'ping': '55ms'},
  ];

  bool get _isConnected => _vpnStatus == 'connected';
  bool get _isConnecting => _vpnStatus == 'connecting';

  String get _statusText {
    switch (_vpnStatus) {
      case 'connected':
        return 'Подключено · $_selectedServer';
      case 'connecting':
        return 'Подключение...';
      case 'disconnecting':
        return 'Отключение...';
      default:
        return 'Не подключено';
    }
  }

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initV2Ray();
    _loadSubscription();
  }

  void _initV2Ray() {
    _flutterV2ray = FlutterV2ray(
      onStatusChanged: (status) {
        setState(() => _vpnStatus = status.state.toString());
      },
    );
    _flutterV2ray.initializeV2Ray(
      notificationIconResourceType: "mipmap",
      notificationIconResourceName: "ic_launcher",
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadSubscription() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('sub_url') ?? '';
    setState(() => _subscriptionUrl = url);
    if (url.isNotEmpty) {
      await _fetchSubscription(url);
    }
  }

  Future<void> _saveSubscription(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sub_url', url);
    setState(() => _subscriptionUrl = url);
    await _fetchSubscription(url);
  }

  /// Скачивает subscription URL и парсит конфиги (base64 -> список ссылок)
  Future<void> _fetchSubscription(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return;

      String body = response.body.trim();

      // Subscription обычно приходит в base64
      List<String> lines;
      try {
        final decoded = utf8.decode(base64.decode(body));
        lines = decoded.split('\n').where((l) => l.trim().isNotEmpty).toList();
      } catch (_) {
        // Не base64 — просто список ссылок
        lines = body.split('\n').where((l) => l.trim().isNotEmpty).toList();
      }

      final configs = <Map<String, dynamic>>[];
      for (final line in lines) {
        final parsed = _parseProxyLink(line.trim());
        if (parsed != null) configs.add(parsed);
      }

      setState(() => _parsedConfigs = configs);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка загрузки подписки: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  /// Парсит одну proxy-ссылку: vless://, vmess://, ss://
  Map<String, dynamic>? _parseProxyLink(String link) {
    if (link.startsWith('vmess://')) {
      try {
        final b64 = link.substring(8);
        final json = utf8.decode(base64.decode(b64));
        final map = jsonDecode(json) as Map<String, dynamic>;
        return {
          'protocol': 'vmess',
          'name': map['ps'] ?? map['add'] ?? 'VMess',
          'raw': link,
          'address': map['add'],
          'port': map['port'],
        };
      } catch (_) {
        return null;
      }
    } else if (link.startsWith('vless://')) {
      final name = _extractRemarkFromUri(link);
      final uri = Uri.tryParse(link);
      return {
        'protocol': 'vless',
        'name': name,
        'raw': link,
        'address': uri?.host,
        'port': uri?.port,
      };
    } else if (link.startsWith('ss://')) {
      final name = _extractRemarkFromUri(link);
      return {
        'protocol': 'ss',
        'name': name,
        'raw': link,
      };
    } else if (link.startsWith('trojan://')) {
      final name = _extractRemarkFromUri(link);
      final uri = Uri.tryParse(link);
      return {
        'protocol': 'trojan',
        'name': name,
        'raw': link,
        'address': uri?.host,
        'port': uri?.port,
      };
    }
    return null;
  }

  String _extractRemarkFromUri(String link) {
    try {
      final uri = Uri.parse(link);
      final frag = uri.fragment;
      if (frag.isNotEmpty) return Uri.decodeComponent(frag);
      return uri.host;
    } catch (_) {
      return link.substring(0, 20);
    }
  }

  Future<void> _toggleConnection() async {
    if (_isConnected || _vpnStatus == 'connecting') {
      await _flutterV2ray.stopV2Ray();
      return;
    }

    // Нет подписки — просим добавить
    if (_subscriptionUrl.isEmpty) {
      _showAddSubscription();
      return;
    }

    // Нет распарсенных конфигов — пробуем загрузить снова
    if (_parsedConfigs.isEmpty) {
      await _fetchSubscription(_subscriptionUrl);
      if (_parsedConfigs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Не удалось загрузить конфиги. Проверь ссылку подписки.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    // Выбираем конфиг: либо активный, либо первый
    final config = _activeConfig ?? _parsedConfigs.first;
    final raw = config['raw'] as String;

    // Запрашиваем разрешение VPN (Android VpnService)
    final permission = await _flutterV2ray.requestPermission();
    if (!permission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Необходимо разрешение VPN'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final v2rayURL = FlutterV2ray.parseFromURL(raw);

    await _flutterV2ray.startV2Ray(
      remark: config['name'] ?? 'ShieldVPN',
      config: v2rayURL.getFullConfiguration(),
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );

    setState(() {
      _selectedServer = config['name'] ?? 'ShieldVPN';
    });
  }

  void _selectConfig(Map<String, dynamic> config) {
    setState(() {
      _activeConfig = config;
      _selectedServer = config['name'] ?? 'Неизвестно';
      _currentIndex = 0;
    });
    // Если уже подключены — переподключаемся
    if (_isConnected) {
      _flutterV2ray.stopV2Ray().then((_) => _toggleConnection());
    }
  }

  void _showAddSubscription() {
    final controller = TextEditingController(text: _subscriptionUrl);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111536),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24, right: 24, top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Добавить конфиг', style: TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 8),
            const Text('Вставь ссылку подписки из @ShieldSpeedVpn_bot',
              style: TextStyle(color: Color(0xFF94a3b8), fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'https://...',
                hintStyle: const TextStyle(color: Color(0xFF475569)),
                filled: true,
                fillColor: const Color(0xFF1e2451),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste, color: Color(0xFF60a5fa)),
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) controller.text = data!.text!;
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563eb),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () async {
                  final url = controller.text.trim();
                  Navigator.pop(ctx);
                  await _saveSubscription(url);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(_parsedConfigs.isEmpty
                          ? '⚠️ Подписка сохранена, но конфиги не загружены'
                          : '✅ Загружено конфигов: ${_parsedConfigs.length}'),
                        backgroundColor: _parsedConfigs.isEmpty
                          ? Colors.orange.shade700
                          : const Color(0xFF16a34a),
                      ),
                    );
                  }
                },
                child: const Text('Сохранить и загрузить', style: TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
                )),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF2563eb)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.telegram, color: Color(0xFF60a5fa)),
                label: const Text('Получить ссылку в боте',
                  style: TextStyle(color: Color(0xFF60a5fa))),
                onPressed: () {
                  Navigator.pop(ctx);
                  launchUrl(Uri.parse('https://t.me/ShieldSpeedVpn_bot'));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── HOME PAGE ────────────────────────────────────────────────────────────

  Widget _buildHomePage() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF1e3a8a),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(
                    color: const Color(0xFF2563eb).withOpacity(0.4),
                    blurRadius: 12, spreadRadius: 2,
                  )],
                ),
                child: const Icon(Icons.shield, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 12),
              const Text('ShieldVPN', style: TextStyle(
                color: Colors.white, fontSize: 26,
                fontWeight: FontWeight.w900, letterSpacing: 1,
              )),
            ],
          ),
          const SizedBox(height: 48),

          // Power button
          ScaleTransition(
            scale: _isConnected ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
            child: GestureDetector(
              onTap: _toggleConnection,
              child: Container(
                width: 180, height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: _isConnected
                      ? [const Color(0xFF16a34a), const Color(0xFF15803d)]
                      : _isConnecting
                        ? [const Color(0xFFca8a04), const Color(0xFFa16207)]
                        : [const Color(0xFF1e3a8a), const Color(0xFF1e40af)],
                  ),
                  boxShadow: [BoxShadow(
                    color: (_isConnected
                      ? const Color(0xFF16a34a)
                      : const Color(0xFF2563eb)).withOpacity(0.5),
                    blurRadius: 40, spreadRadius: 8,
                  )],
                ),
                child: _isConnecting
                  ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                  : const Icon(Icons.power_settings_new, color: Colors.white, size: 80),
              ),
            ),
          ),

          const SizedBox(height: 24),
          Text(_statusText, style: TextStyle(
            color: _isConnected ? const Color(0xFF4ade80) : const Color(0xFF94a3b8),
            fontSize: 16, fontWeight: FontWeight.w600,
          )),
          const SizedBox(height: 8),
          Text(_isConnected ? 'Нажми чтобы отключить' : 'Нажми чтобы подключить',
            style: const TextStyle(color: Color(0xFF475569), fontSize: 13)),

          // Трафик (только при подключении)
          if (_isConnected) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _trafficChip(Icons.arrow_upward, _uploadSpeed, const Color(0xFF60a5fa)),
                const SizedBox(width: 16),
                _trafficChip(Icons.arrow_downward, _downloadSpeed, const Color(0xFF4ade80)),
              ],
            ),
          ],

          const SizedBox(height: 40),

          // Server selector
          GestureDetector(
            onTap: () => setState(() => _currentIndex = 1),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111536),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1e3a8a)),
              ),
              child: Row(
                children: [
                  const Text('🌐', style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Сервер', style: TextStyle(
                          color: Color(0xFF94a3b8), fontSize: 12)),
                        Text(_selectedServer, style: const TextStyle(
                          color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF60a5fa)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Add config button
          GestureDetector(
            onTap: _showAddSubscription,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111536),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1e3a8a)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.add_circle_outline, color: Color(0xFF60a5fa), size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Конфигурация', style: TextStyle(
                          color: Color(0xFF94a3b8), fontSize: 12)),
                        Text(
                          _subscriptionUrl.isEmpty
                            ? 'Добавить ссылку подписки'
                            : _parsedConfigs.isEmpty
                              ? 'Загрузка конфигов...'
                              : 'Загружено серверов: ${_parsedConfigs.length} ✅',
                          style: TextStyle(
                            color: _subscriptionUrl.isEmpty
                              ? const Color(0xFF60a5fa)
                              : const Color(0xFF4ade80),
                            fontSize: 15, fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF60a5fa)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _trafficChip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111536),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1e3a8a)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ─── SERVERS PAGE ─────────────────────────────────────────────────────────

  Widget _buildServersPage() {
    final hasParsed = _parsedConfigs.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 16),
        const Text('Выбор сервера', style: TextStyle(
          color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (hasParsed)
          Text('Серверов из подписки: ${_parsedConfigs.length}',
            style: const TextStyle(color: Color(0xFF64748b), fontSize: 13))
        else
          const Text('Добавь подписку для загрузки реальных серверов',
            style: TextStyle(color: Color(0xFF64748b), fontSize: 13)),
        const SizedBox(height: 16),

        if (hasParsed)
          ..._parsedConfigs.map((config) {
            final name = config['name'] as String? ?? 'Сервер';
            final protocol = config['protocol'] as String? ?? '';
            final isSelected = _activeConfig == config ||
              (_activeConfig == null && config == _parsedConfigs.first && _selectedServer == name);
            return GestureDetector(
              onTap: () => _selectConfig(config),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF1e3a8a) : const Color(0xFF111536),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF2563eb) : const Color(0xFF1e2451),
                  ),
                ),
                child: Row(
                  children: [
                    _protocolIcon(protocol),
                    const SizedBox(width: 14),
                    Expanded(child: Text(name, style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0a0e2e),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(protocol.toUpperCase(), style: const TextStyle(
                        color: Color(0xFF60a5fa), fontSize: 11)),
                    ),
                    if (isSelected)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.check_circle, color: Color(0xFF2563eb), size: 20),
                      ),
                  ],
                ),
              ),
            );
          })
        else
          ..._staticServers.map((server) => GestureDetector(
            onTap: () {
              setState(() {
                _selectedServer = server['name']!;
                _currentIndex = 0;
              });
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _selectedServer == server['name']
                  ? const Color(0xFF1e3a8a)
                  : const Color(0xFF111536),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _selectedServer == server['name']
                    ? const Color(0xFF2563eb)
                    : const Color(0xFF1e2451),
                ),
              ),
              child: Row(
                children: [
                  Text(server['flag']!, style: const TextStyle(fontSize: 28)),
                  const SizedBox(width: 14),
                  Expanded(child: Text(server['name']!, style: const TextStyle(
                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0a0e2e),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(server['ping']!, style: const TextStyle(
                      color: Color(0xFF60a5fa), fontSize: 12)),
                  ),
                  if (_selectedServer == server['name'])
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.check_circle, color: Color(0xFF2563eb), size: 20),
                    ),
                ],
              ),
            ),
          )),
      ],
    );
  }

  Widget _protocolIcon(String protocol) {
    final icons = {
      'vless': '🔷',
      'vmess': '🔶',
      'ss': '🟣',
      'trojan': '🟠',
    };
    return Text(icons[protocol] ?? '🌐', style: const TextStyle(fontSize: 24));
  }

  // ─── BOT PAGE ─────────────────────────────────────────────────────────────

  Widget _buildBotPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100, height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF1e3a8a),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(
                  color: const Color(0xFF2563eb).withOpacity(0.4),
                  blurRadius: 20, spreadRadius: 4,
                )],
              ),
              child: const Icon(Icons.shield, color: Colors.white, size: 56),
            ),
            const SizedBox(height: 24),
            const Text('ShieldVPN Bot', style: TextStyle(
              color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'Получи персональную ссылку подписки в нашем Telegram боте',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF94a3b8), fontSize: 15),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563eb),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.telegram, color: Colors.white, size: 24),
                label: const Text('@ShieldSpeedVpn_bot', style: TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                onPressed: () => launchUrl(Uri.parse('https://t.me/ShieldSpeedVpn_bot')),
              ),
            ),
            const SizedBox(height: 16),
            const Text('• Купи подписку\n• Получи ссылку\n• Вставь в приложение',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748b), fontSize: 14, height: 1.8)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_buildHomePage(), _buildServersPage(), _buildBotPage()];
    return Scaffold(
      body: SafeArea(child: pages[_currentIndex]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF111536),
          border: Border(top: BorderSide(color: Color(0xFF1e2451))),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.transparent,
          selectedItemColor: const Color(0xFF60a5fa),
          unselectedItemColor: const Color(0xFF475569),
          elevation: 0,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Главная'),
            BottomNavigationBarItem(icon: Icon(Icons.dns_rounded), label: 'Серверы'),
            BottomNavigationBarItem(icon: Icon(Icons.telegram), label: 'Бот'),
          ],
        ),
      ),
    );
  }
}
