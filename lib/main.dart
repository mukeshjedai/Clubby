import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:azure_communication_calling/azure_communication_calling.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auth_screens.dart';
import 'backend_api.dart';
import 'trip_notifications.dart';

const _commsApiBaseUrl = String.fromEnvironment(
  'COMMS_API_BASE_URL',
  defaultValue: 'https://zello-func-11159.azurewebsites.net/api',
);
const _locationApiBaseUrl = String.fromEnvironment(
  'LOCATION_API_BASE_URL',
  defaultValue: 'https://zello-func-11159.azurewebsites.net/api',
);
const _bgLocationTask = 'clubby-location-sync';
const _bgLocationTaskUnique = 'clubby-location-sync-unique';
const _prefActiveUsername = 'clubby_active_username';
const _prefAuthToken = 'clubby_auth_token';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != _bgLocationTask) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeUsername = prefs.getString(_prefActiveUsername);
      if (activeUsername == null || activeUsername.isEmpty) return true;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return false;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final uri = Uri.parse('$_locationApiBaseUrl/locations');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': activeUsername,
          'lat': pos.latitude,
          'lng': pos.longitude,
        }),
      );
      return res.statusCode ~/ 100 == 2;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    await Workmanager().registerPeriodicTask(
      _bgLocationTaskUnique,
      _bgLocationTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
  runApp(const TeamRadioApp());
}

class TeamRadioApp extends StatelessWidget {
  const TeamRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clubby',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const AppRoot(),
    );
  }
}

class Channel {
  Channel({
    required this.id,
    required this.name,
    this.isPrivate = false,
    this.createdByUserId,
  });

  factory Channel.fromMap(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Channel',
        isPrivate: json['isPrivate'] == true,
        createdByUserId: json['createdByUserId'] as String?,
      );

  final String id;
  final String name;
  final bool isPrivate;
  final String? createdByUserId;
}

class UserAccount {
  UserAccount({
    required this.id,
    required this.username,
    required this.fullName,
    required this.dateOfBirth,
    required this.suburb,
    required this.stateName,
    this.isActive = true,
    this.isAdmin = false,
    this.avatarColorValue = 0xFF5C6BC0,
    this.createdByUserId,
    this.profileImageUrl,
  });

  final String id;
  String username;
  String fullName;
  String dateOfBirth;
  String suburb;
  String stateName;
  bool isActive;
  final bool isAdmin;
  final int avatarColorValue;
  final String? createdByUserId;
  String? profileImageUrl;
}

enum MessageKind { text, photo, voice }

class SecureMessage {
  SecureMessage({
    required this.id,
    required this.channelId,
    required this.sender,
    required this.kind,
    required this.encryptedPayload,
    required this.createdAt,
  });

  factory SecureMessage.fromMap(Map<String, dynamic> json) {
    final kindRaw = (json['kind'] as String? ?? 'text').toLowerCase();
    final kind = MessageKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () => MessageKind.text,
    );
    return SecureMessage(
      id: json['id'] as String,
      channelId: json['channelId'] as String,
      sender: json['sender'] as String? ?? 'Unknown',
      kind: kind,
      encryptedPayload: json['encryptedPayload'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  final String id;
  final String channelId;
  final String sender;
  final MessageKind kind;
  final String encryptedPayload;
  final DateTime createdAt;
}

class EncryptionService {
  EncryptionService() : _key = SecretKey(_randomBytes(32));
  final SecretKey _key;
  final Cipher _cipher = Chacha20.poly1305Aead();

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<String> encrypt(String plain) async {
    final nonce = _randomBytes(12);
    final secretBox = await _cipher.encrypt(
      utf8.encode(plain),
      secretKey: _key,
      nonce: nonce,
    );
    final payload = jsonEncode({
      'nonce': base64Encode(secretBox.nonce),
      'cipherText': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
    return base64Encode(utf8.encode(payload));
  }

  Future<String> decrypt(String encoded) async {
    final decoded = jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>;
    final box = SecretBox(
      base64Decode(decoded['cipherText'] as String),
      nonce: base64Decode(decoded['nonce'] as String),
      mac: Mac(base64Decode(decoded['mac'] as String)),
    );
    final clear = await _cipher.decrypt(box, secretKey: _key);
    return utf8.decode(clear);
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final BackendApi _api = BackendApi(
    commsBaseUrl: _commsApiBaseUrl,
    locationBaseUrl: _locationApiBaseUrl,
  );
  final EncryptionService _encryption = EncryptionService();
  final List<UserAccount> _users = [];
  List<Channel> _channels = [];
  List<SecureMessage> _messages = [];
  String _currentUserId = '';
  String? _authToken;
  bool _isLoggedIn = false;
  bool _authBootstrapDone = false;
  final Set<String> _joinedChannelIds = <String>{'general'};
  final Map<String, Set<String>> _channelJoinRequests = {};
  final Map<String, Set<String>> _channelLiveUsers = {};
  int _tab = 0;
  String? _activeChannelId;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _bootstrapAuth();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  UserAccount get _currentUser => _users.firstWhere((u) => u.id == _currentUserId);

  Future<void> _bootstrapAuth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_prefAuthToken);
      if (token != null && token.isNotEmpty && mounted) {
        try {
          final v = await _api.verifySession(token);
          if (v['valid'] == true) {
            final username = v['username'] as String? ?? v['userId'] as String?;
            if (username != null && username.isNotEmpty) {
              await _applyPasswordSession(username: username, token: token, persistToken: false);
            }
          } else {
            await prefs.remove(_prefAuthToken);
          }
        } catch (_) {
          await prefs.remove(_prefAuthToken);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _authBootstrapDone = true);
      }
    }
  }

  /// [persistToken] false when token was already read from disk (avoid rewrite).
  Future<void> _applyPasswordSession({
    required String username,
    required String token,
    bool persistToken = true,
  }) async {
    final u = username.trim().toLowerCase();
    UserAccount? matched;
    for (final user in _users) {
      if (user.username.toLowerCase() == u) {
        matched = user;
        break;
      }
    }
    matched ??= UserAccount(
      id: u,
      username: u,
      fullName: u,
      dateOfBirth: '',
      suburb: '',
      stateName: '',
      avatarColorValue: 0xFF5C6BC0,
      createdByUserId: null,
    );
    if (_users.every((x) => x.id != matched!.id)) {
      _users.add(matched);
    }

    if (!mounted) return;
    setState(() {
      _authToken = token;
      _isLoggedIn = true;
      _currentUserId = u;
    });
    if (persistToken) {
      await _persistActiveUser();
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefActiveUsername, u);
      await prefs.setString('clubby_current_user_id', u);
    }
    if (!mounted) return;
    if (_channels.isEmpty) {
      await _initialLoad();
    }
    _refreshTimer ??= Timer.periodic(const Duration(seconds: 4), (_) => _refreshMessages());
  }

  Future<void> _persistActiveUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (_authToken != null) {
      await prefs.setString(_prefAuthToken, _authToken!);
    }
    await prefs.setString(_prefActiveUsername, _currentUser.username);
    await prefs.setString('clubby_current_user_id', _currentUserId);
  }

  Future<void> _signOut() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefAuthToken);
    await prefs.remove(_prefActiveUsername);
    await prefs.remove('clubby_current_user_id');
    if (!mounted) return;
    setState(() {
      _authToken = null;
      _isLoggedIn = false;
      _currentUserId = '';
      _messages = [];
      _channels = [];
      _error = null;
    });
  }

  UserAccount? _findUserByUsername(String username) {
    for (final user in _users) {
      if (user.username.toLowerCase() == username.toLowerCase()) {
        return user;
      }
    }
    return null;
  }

  String _contentTypeForFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  Future<String?> _uploadMediaXFile({
    required XFile file,
    required String category,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final fileName = file.name.isEmpty ? 'upload.jpg' : file.name;
      final contentType = _contentTypeForFileName(fileName);
      final url = await _api.uploadMedia(
        userId: _currentUser.username,
        fileName: fileName,
        category: category,
        bytes: bytes,
        contentType: contentType,
      );
      return url;
    } catch (_) {
      return null;
    }
  }

  Future<void> _editUserProfile(UserAccount user) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(
          user: user,
          canSave: user.id == _currentUserId,
          onUploadProfilePicture: (file) async {
            final uploadedUrl = await _uploadMediaXFile(
              file: file,
              category: 'profile',
            );
            if (uploadedUrl == null) return null;
            setState(() {
              user.profileImageUrl = uploadedUrl;
            });
            return uploadedUrl;
          },
          onSave: (updated) {
            setState(() {
              user.username =
                  updated.username.trim().isEmpty ? user.username : updated.username.trim();
              user.fullName =
                  updated.fullName.trim().isEmpty ? user.fullName : updated.fullName.trim();
              user.dateOfBirth = updated.dateOfBirth.trim().isEmpty
                  ? user.dateOfBirth
                  : updated.dateOfBirth.trim();
              user.suburb =
                  updated.suburb.trim().isEmpty ? user.suburb : updated.suburb.trim();
              user.stateName = updated.stateName.trim().isEmpty
                  ? user.stateName
                  : updated.stateName.trim();
            });
          },
        ),
      ),
    );
  }

  Future<void> _initialLoad() async {
    try {
      final data = await _api.getChannels();
      final parsed = data.map(Channel.fromMap).toList();
      setState(() {
        _channels = parsed;
        _activeChannelId = parsed.isNotEmpty ? parsed.first.id : null;
        for (final c in parsed) {
          _channelJoinRequests.putIfAbsent(c.id, () => <String>{});
          _channelLiveUsers.putIfAbsent(c.id, () => <String>{});
        }
        _error = null;
      });
      await _refreshMessages();
    } catch (e) {
      setState(() {
        _error = 'Failed to load channels: $e';
      });
    }
  }

  Future<void> _refreshMessages() async {
    final id = _activeChannelId;
    if (id == null) return;
    try {
      final list = await _api.getMessages(id);
      setState(() {
        _messages = list.map(SecureMessage.fromMap).toList();
      });
    } catch (_) {}
  }

  Future<void> _sendSecureMessage({
    required MessageKind kind,
    required String payload,
  }) async {
    final id = _activeChannelId;
    if (id == null) return;
    final encrypted = await _encryption.encrypt(payload);
    await _api.sendMessage(
      channelId: id,
      sender: _currentUser.username,
      kind: kind.name,
      encryptedPayload: encrypted,
    );
    await _refreshMessages();
  }

  Future<void> _createChannel(String name, {bool isPrivate = false}) async {
    final created = await _api.createChannel(
      name: name,
      isPrivate: isPrivate,
      createdByUserId: _currentUserId,
    );
    final parsed = Channel.fromMap(created);
    final channel = Channel(
      id: parsed.id,
      name: parsed.name,
      isPrivate: parsed.isPrivate,
      createdByUserId: _currentUserId,
    );
    setState(() {
      _channels = [channel, ..._channels];
      _activeChannelId ??= channel.id;
      _joinedChannelIds.add(channel.id);
      _channelJoinRequests.putIfAbsent(channel.id, () => <String>{});
      _channelLiveUsers.putIfAbsent(channel.id, () => <String>{});
    });
  }

  Future<void> _requestJoinPublicChannel(Channel channel) async {
    if (channel.isPrivate) return;
    setState(() {
      _joinedChannelIds.add(channel.id);
      _activeChannelId = channel.id;
      _tab = 0;
    });
    await _refreshMessages();
  }

  Future<void> _openGroupFromExplore(Channel channel) async {
    if (!channel.isPrivate || _joinedChannelIds.contains(channel.id)) {
      if (!_joinedChannelIds.contains(channel.id) && !channel.isPrivate) {
        _joinedChannelIds.add(channel.id);
      }
      setState(() {
        _activeChannelId = channel.id;
        _tab = 0;
      });
      await _refreshMessages();
      return;
    }
    // Private and not joined yet: create join request.
    _requestJoinPrivateChannel(channel);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Join request sent to group admin')),
    );
  }

  void _requestJoinPrivateChannel(Channel channel) {
    if (!channel.isPrivate) return;
    setState(() {
      _channelJoinRequests.putIfAbsent(channel.id, () => <String>{}).add(_currentUserId);
    });
  }

  void _approvePrivateJoinRequest({
    required String channelId,
    required String requestUserId,
  }) {
    setState(() {
      _channelJoinRequests[channelId]?.remove(requestUserId);
      _joinedChannelIds.add(channelId);
    });
  }

  void _deleteChannel(Channel channel) {
    if (channel.createdByUserId != _currentUserId) return;
    setState(() {
      _channels = _channels.where((c) => c.id != channel.id).toList();
      _messages = _messages.where((m) => m.channelId != channel.id).toList();
      _joinedChannelIds.remove(channel.id);
      _channelJoinRequests.remove(channel.id);
      _channelLiveUsers.remove(channel.id);
      if (_activeChannelId == channel.id) {
        _activeChannelId = _channels.isNotEmpty ? _channels.first.id : null;
      }
    });
  }

  void _goLiveStart() {
    final channelId = _activeChannelId;
    if (channelId == null) return;
    setState(() {
      _channelLiveUsers.putIfAbsent(channelId, () => <String>{}).add(_currentUserId);
    });
  }

  void _goLiveEnd() {
    final channelId = _activeChannelId;
    if (channelId == null) return;
    setState(() {
      _channelLiveUsers[channelId]?.remove(_currentUserId);
    });
  }

  List<UserAccount> _liveUsersForActiveChannel() {
    final channelId = _activeChannelId;
    if (channelId == null) return const <UserAccount>[];
    final ids = _channelLiveUsers[channelId] ?? const <String>{};
    return _users.where((u) => ids.contains(u.id)).toList();
  }

  void _toggleUser(UserAccount user) {
    setState(() => user.isActive = !user.isActive);
  }

  @override
  Widget build(BuildContext context) {
    if (!_authBootstrapDone) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_isLoggedIn) {
      return LoginScreen(
        api: _api,
        onLoggedIn: (username, token) => _applyPasswordSession(username: username, token: token),
      );
    }

    final matching = _activeChannelId == null
        ? const <Channel>[]
        : _channels.where((c) => c.id == _activeChannelId).toList();
    final active = matching.isEmpty ? null : matching.first;

    final pages = <Widget>[
      CommsScreen(
        currentUser: _currentUser,
        activeChannel: active,
        channels: _channels.where((c) => _joinedChannelIds.contains(c.id)).toList(),
        messages: _messages,
        decrypt: _encryption.decrypt,
        onChannelChange: (id) async {
          setState(() => _activeChannelId = id);
          await _refreshMessages();
        },
        onSendText: (text) => _sendSecureMessage(kind: MessageKind.text, payload: text),
        onSendPhotoPath: (path) => _sendSecureMessage(kind: MessageKind.photo, payload: path),
        onUploadPhoto: (file) => _uploadMediaXFile(file: file, category: 'chat'),
        onSendVoicePath: (path) => _sendSecureMessage(kind: MessageKind.voice, payload: path),
        onGoLiveStart: _goLiveStart,
        onGoLiveEnd: _goLiveEnd,
        activeLiveUsers: _liveUsersForActiveChannel(),
        onOpenProfile: (username) async {
          final user = _findUserByUsername(username);
          if (user != null) {
            await _editUserProfile(user);
          }
        },
      ),
      LocationScreen(identity: _currentUser.username, api: _api),
      AdminScreen(
        channels: _channels,
        onCreateChannel: _createChannel,
        onDeleteChannel: _deleteChannel,
        currentUserId: _currentUserId,
        users: _users,
        channelJoinRequests: _channelJoinRequests,
        onApproveJoinRequest: _approvePrivateJoinRequest,
      ),
      ExploreScreen(
        channels: _channels,
        users: _users,
        joinedChannelIds: _joinedChannelIds,
        onRequestJoinPublicGroup: _requestJoinPublicChannel,
        onRequestJoinPrivateGroup: _requestJoinPrivateChannel,
        onOpenGroup: _openGroupFromExplore,
        channelJoinRequests: _channelJoinRequests,
        currentUserId: _currentUserId,
        onOpenProfile: _editUserProfile,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Clubby'),
            Text(
              'Logged in as ${_currentUser.fullName.isNotEmpty ? _currentUser.fullName : _currentUser.username}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
          IconButton(
            tooltip: 'Edit current profile',
            onPressed: () => _editUserProfile(_currentUser),
            icon: const Icon(Icons.edit),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : (_channels.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.forum), label: 'Comms'),
          NavigationDestination(icon: Icon(Icons.map), label: 'Location'),
          NavigationDestination(icon: Icon(Icons.admin_panel_settings), label: 'Admin'),
          NavigationDestination(icon: Icon(Icons.explore), label: 'Explore'),
        ],
      ),
    );
  }
}

class CommsScreen extends StatefulWidget {
  const CommsScreen({
    super.key,
    required this.currentUser,
    required this.activeChannel,
    required this.channels,
    required this.messages,
    required this.decrypt,
    required this.onChannelChange,
    required this.onSendText,
    required this.onSendPhotoPath,
    required this.onUploadPhoto,
    required this.onSendVoicePath,
    required this.onGoLiveStart,
    required this.onGoLiveEnd,
    required this.activeLiveUsers,
    required this.onOpenProfile,
  });
  final UserAccount currentUser;
  final Channel? activeChannel;
  final List<Channel> channels;
  final List<SecureMessage> messages;
  final Future<String> Function(String) decrypt;
  final ValueChanged<String> onChannelChange;
  final ValueChanged<String> onSendText;
  final ValueChanged<String> onSendPhotoPath;
  final Future<String?> Function(XFile file) onUploadPhoto;
  final ValueChanged<String> onSendVoicePath;
  final VoidCallback onGoLiveStart;
  final VoidCallback onGoLiveEnd;
  final List<UserAccount> activeLiveUsers;
  final ValueChanged<String> onOpenProfile;

  @override
  State<CommsScreen> createState() => _CommsScreenState();
}

class _CommsScreenState extends State<CommsScreen> {
  final TextEditingController _textController = TextEditingController();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final ImagePicker _picker = ImagePicker();
  final AzureCommunicationCalling _acsCalling = AzureCommunicationCalling();
  bool _recording = false;
  bool _isLiveJoined = false;
  bool _isJoiningLive = false;
  String? _recordPath;

  @override
  void dispose() {
    _textController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<String> _nextVoicePath() async {
    final dir = await getTemporaryDirectory();
    return p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
  }

  Future<void> _startVoice() async {
    if (!await _recorder.hasPermission()) return;
    final path = await _nextVoicePath();
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _recording = true;
      _recordPath = path;
    });
  }

  Future<void> _stopVoice() async {
    if (!_recording) return;
    final out = await _recorder.stop() ?? _recordPath;
    setState(() => _recording = false);
    if (out != null) widget.onSendVoicePath(out);
  }

  Future<void> _pickPhoto() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final uploadedUrl = await widget.onUploadPhoto(file);
    if (uploadedUrl != null) {
      widget.onSendPhotoPath(uploadedUrl);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to upload image to Azure storage')),
      );
    }
  }

  Future<void> _play(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<Widget> _messageBody(SecureMessage m) async {
    try {
      final text = await widget.decrypt(m.encryptedPayload);
      if (m.kind == MessageKind.text) return Text(text);
      if (m.kind == MessageKind.photo) {
        if (text.startsWith('http://') || text.startsWith('https://')) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              text,
              height: 140,
              width: 140,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Text('Unable to load image'),
            ),
          );
        }
        return Text('Photo: $text');
      }
      return const Text('Voice message');
    } catch (_) {
      // Older messages may be encrypted with a different session key.
      return const Text('Unable to decrypt this older message');
    }
  }

  Future<void> _playVoiceMessageIfAny(SecureMessage m) async {
    if (m.kind != MessageKind.voice) return;
    try {
      String path;
      try {
        path = await widget.decrypt(m.encryptedPayload);
      } catch (_) {
        // Fallback for older payloads that were plain base64-encoded path strings.
        path = utf8.decode(base64Decode(m.encryptedPayload));
      }
      await _play(path);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to play this voice message')),
      );
    }
  }

  Future<void> _toggleLiveCall() async {
    if (_isJoiningLive) return;
    if (_isLiveJoined) {
      setState(() {
        _isLiveJoined = false;
      });
      widget.onGoLiveEnd();
      return;
    }

    setState(() {
      _isJoiningLive = true;
    });
    try {
      if (kIsWeb) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Live ACS calling is currently supported on Android/iOS only.'),
          ),
        );
        return;
      }
      final channel = widget.activeChannel;
      if (channel == null) return;
      final tokenData = await BackendApi(
        commsBaseUrl: _commsApiBaseUrl,
        locationBaseUrl: _locationApiBaseUrl,
      ).getAcsToken(
        displayName: widget.currentUser.username,
        channelId: channel.id,
      );
      final token = tokenData['token'] as String?;
      final roomId = tokenData['roomId'] as String?;
      if (token == null || roomId == null) {
        throw Exception('Missing ACS token or roomId');
      }

      final String? error = await _acsCalling.startCall(
        token: token,
        roomId: roomId,
        displayName: widget.currentUser.username,
      );
      if (error != null) {
        throw Exception(error);
      }
      if (!mounted) return;
      setState(() {
        _isLiveJoined = true;
      });
      widget.onGoLiveStart();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to join live call: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isJoiningLive = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeChannel;
    if (active == null) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Group chat: ${active.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                const Chip(
                  avatar: Icon(Icons.wifi_tethering, size: 16),
                  label: Text('Live now'),
                ),
                ...widget.activeLiveUsers.map(
                  (u) => Chip(label: Text('@${u.username}')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: widget.messages.isEmpty
                      ? const Center(child: Text('No messages yet'))
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 78),
                          itemCount: widget.messages.length,
                          itemBuilder: (context, i) {
                            final m = widget.messages[i];
                            final color = Colors
                                .primaries[m.sender.hashCode.abs() % Colors.primaries.length];
                            final isMine = m.sender.toLowerCase() ==
                                widget.currentUser.username.toLowerCase();
                            return Card(
                              color: isMine ? Colors.blue.shade100 : Colors.green.shade100,
                              child: ListTile(
                                onTap: () => _playVoiceMessageIfAny(m),
                                leading: GestureDetector(
                                  onTap: () => widget.onOpenProfile(m.sender),
                                  child: CircleAvatar(
                                    backgroundColor: color,
                                    child: const Icon(Icons.account_circle, color: Colors.white),
                                  ),
                                ),
                                title: Text('${m.sender} • ${m.kind.name}'),
                                subtitle: FutureBuilder<Widget>(
                                  future: _messageBody(m),
                                  builder: (context, snap) {
                                    if (snap.connectionState == ConnectionState.waiting) {
                                      return const Text('Decrypting...');
                                    }
                                    if (snap.hasError) {
                                      return const Text('Unable to decrypt this older message');
                                    }
                                    return snap.data ?? const SizedBox.shrink();
                                  },
                                ),
                                trailing: m.kind == MessageKind.voice
                                    ? IconButton(
                                        tooltip: 'Play voice',
                                        onPressed: () => _playVoiceMessageIfAny(m),
                                        icon: const Icon(Icons.play_arrow),
                                      )
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.extended(
                    onPressed: _toggleLiveCall,
                    backgroundColor: _isLiveJoined ? Colors.red : Colors.indigo,
                    icon: _isJoiningLive
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(_isLiveJoined ? Icons.call_end : Icons.wifi_tethering),
                    label: Text(
                      _isJoiningLive
                          ? 'Connecting...'
                          : (_isLiveJoined ? 'Leave Live' : 'Go Live'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: const InputDecoration(
                    hintText: 'Encrypted text',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  final text = _textController.text.trim();
                  if (text.isEmpty) return;
                  widget.onSendText(text);
                  _textController.clear();
                },
                icon: const Icon(Icons.send),
              ),
              IconButton(onPressed: _pickPhoto, icon: const Icon(Icons.photo)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Movement from leaving a stop until the next sustained stop (GPS-based).
class TripSegment {
  TripSegment({
    this.id,
    required this.start,
    required this.end,
    required this.startedAt,
    required this.endedAt,
    required this.points,
  });

  factory TripSegment.fromServerMap(Map<String, dynamic> j) {
    final plist = j['points'] as List<dynamic>? ?? [];
    final points = plist.map((e) {
      final m = e as Map<String, dynamic>;
      return LatLng(
        (m['lat'] as num).toDouble(),
        (m['lng'] as num).toDouble(),
      );
    }).toList();
    final slat = (j['startLat'] as num).toDouble();
    final slng = (j['startLng'] as num).toDouble();
    final elat = (j['endLat'] as num).toDouble();
    final elng = (j['endLng'] as num).toDouble();
    return TripSegment(
      id: j['id'] as String?,
      start: LatLng(slat, slng),
      end: LatLng(elat, elng),
      startedAt: DateTime.parse(j['startedAt'] as String).toLocal(),
      endedAt: DateTime.parse(j['endedAt'] as String).toLocal(),
      points: points.length >= 2
          ? points
          : <LatLng>[
              LatLng(slat, slng),
              LatLng(elat, elng),
            ],
    );
  }

  final String? id;
  final LatLng start;
  final LatLng end;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<LatLng> points;

  Map<String, dynamic> toBackendPayload() {
    return {
      'startLat': start.latitude,
      'startLng': start.longitude,
      'endLat': end.latitude,
      'endLng': end.longitude,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'endedAt': endedAt.toUtc().toIso8601String(),
      'distanceKm': distanceKm(),
      'points': points
          .map((p) => <String, double>{'lat': p.latitude, 'lng': p.longitude})
          .toList(),
    };
  }

  Duration get duration => endedAt.difference(startedAt);

  String get summary {
    final sh = startedAt.hour.toString().padLeft(2, '0');
    final sm = startedAt.minute.toString().padLeft(2, '0');
    final eh = endedAt.hour.toString().padLeft(2, '0');
    final em = endedAt.minute.toString().padLeft(2, '0');
    final d = duration;
    String dur;
    if (d.inMinutes < 1) {
      dur = '${d.inSeconds}s';
    } else if (d.inHours < 1) {
      dur = '${d.inMinutes}m';
    } else {
      dur = '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '$sh:$sm → $eh:$em · $dur';
  }

  /// Path length along recorded GPS points (meters).
  double pathLengthMeters() {
    if (points.length < 2) return 0;
    var m = 0.0;
    for (var i = 1; i < points.length; i++) {
      m += Geolocator.distanceBetween(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    return m;
  }

  double distanceKm() => pathLengthMeters() / 1000.0;
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key, required this.identity, required this.api});
  final String identity;
  final BackendApi api;

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  static const double _minMetersToStartTrip = 3;
  static const double _minMetersBetweenPathPoints = 8;
  static const double _stationaryRadiusM = 22;
  static const int _stationarySeconds = 75;
  static const int _maxStoredTrips = 25;

  final Completer<GoogleMapController> _mapController = Completer();
  StreamSubscription<Position>? _positionSub;
  Timer? _pollTimer;
  final Map<String, Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  String _status = 'Starting live location...';

  LatLng? _anchorAfterStop;
  DateTime? _maybeStationarySince;
  LatLng? _lastPointForStationaryCheck;
  LatLng? _tripStartPoint;
  DateTime? _tripStartTime;
  List<LatLng> _tripPoints = [];
  final List<TripSegment> _trips = [];
  int? _highlightTripIndex;
  LatLng? _lastGps;

  @override
  void initState() {
    super.initState();
    _startTracking();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadPeers());
    _loadTripsFromServer();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTripsFromServer() async {
    try {
      final rows = await widget.api.getTrips(userId: widget.identity);
      if (!mounted) return;
      setState(() {
        _highlightTripIndex = null;
        _trips
          ..clear()
          ..addAll(rows.map(TripSegment.fromServerMap));
        _rebuildPolylines();
        _syncTripMarkers();
      });
    } catch (_) {}
  }

  Future<void> _persistTripToBackend(TripSegment segment) async {
    try {
      final res = await widget.api.saveTrip(
        userId: widget.identity,
        payload: segment.toBackendPayload(),
      );
      if (!mounted) return;
      setState(() {
        final i = _trips.indexWhere(
          (t) =>
              t.id == null &&
              t.startedAt == segment.startedAt &&
              t.endedAt == segment.endedAt,
        );
        if (i >= 0) {
          _trips[i] = TripSegment.fromServerMap(res);
          _rebuildPolylines();
        }
      });
    } catch (_) {}
  }

  Future<void> _loadPeers() async {
    try {
      final rows = await widget.api.getLocations();
      final next = <String, Marker>{};
      for (final row in rows) {
        final id = row['userId'] as String? ?? 'unknown';
        final lat = (row['lat'] as num?)?.toDouble();
        final lng = (row['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        next[id] = Marker(
          markerId: MarkerId(id),
          position: LatLng(lat, lng),
          infoWindow: InfoWindow(title: id),
        );
      }
      final preserveMe = _markers[widget.identity];
      final preserveTripStart = _markers['__trip_start'];
      final preserveTripEnd = _markers['__trip_end'];
      setState(() {
        _markers
          ..clear()
          ..addAll(next);
        if (preserveMe != null) _markers[widget.identity] = preserveMe;
        if (preserveTripStart != null) _markers['__trip_start'] = preserveTripStart;
        if (preserveTripEnd != null) _markers['__trip_end'] = preserveTripEnd;
      });
    } catch (_) {}
  }

  void _rebuildPolylines() {
    final next = <Polyline>{};
    for (var i = 0; i < _trips.length; i++) {
      final t = _trips[i];
      if (t.points.length < 2) continue;
      final highlight = _highlightTripIndex == i;
      next.add(
        Polyline(
          polylineId: PolylineId('trip-done-$i'),
          points: t.points,
          color: highlight ? Colors.deepOrange : Colors.grey.withOpacity(0.7),
          width: highlight ? 6 : 3,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
    }
    final activePts = _activePolylinePoints();
    if (activePts.length >= 2) {
      next.add(
        Polyline(
          polylineId: const PolylineId('trip-active'),
          points: activePts,
          color: Colors.blue.shade600,
          width: 5,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
    }
    _polylines
      ..clear()
      ..addAll(next);
  }

  List<LatLng> _activePolylinePoints() {
    if (_tripPoints.isEmpty || _tripStartPoint == null) return [];
    final out = List<LatLng>.of(_tripPoints);
    final g = _lastGps;
    if (g != null) {
      final d = Geolocator.distanceBetween(
        out.last.latitude,
        out.last.longitude,
        g.latitude,
        g.longitude,
      );
      if (d >= 5) {
        out.add(g);
      } else {
        out[out.length - 1] = g;
      }
    }
    return out;
  }

  void _syncTripMarkers() {
    _markers.remove('__trip_start');
    _markers.remove('__trip_end');
    final activeEnd = _lastGps ?? (_tripPoints.isNotEmpty ? _tripPoints.last : null);
    if (_tripStartPoint != null && activeEnd != null && _tripPoints.isNotEmpty) {
      _markers['__trip_start'] = Marker(
        markerId: const MarkerId('__trip_start'),
        position: _tripStartPoint!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Trip start'),
      );
      _markers['__trip_end'] = Marker(
        markerId: const MarkerId('__trip_end'),
        position: activeEnd,
        infoWindow: const InfoWindow(title: 'Trip (in progress)'),
      );
    } else if (_highlightTripIndex != null &&
        _highlightTripIndex! >= 0 &&
        _highlightTripIndex! < _trips.length) {
      final t = _trips[_highlightTripIndex!];
      _markers['__trip_start'] = Marker(
        markerId: const MarkerId('__trip_start'),
        position: t.start,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Start'),
      );
      _markers['__trip_end'] = Marker(
        markerId: const MarkerId('__trip_end'),
        position: t.end,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'End'),
      );
    }
  }

  void _handleTripTracking(LatLng p, DateTime now) {
    if (_tripStartPoint == null) {
      if (_anchorAfterStop == null) {
        _anchorAfterStop = p;
        return;
      }
      final moved = Geolocator.distanceBetween(
        _anchorAfterStop!.latitude,
        _anchorAfterStop!.longitude,
        p.latitude,
        p.longitude,
      );
      if (moved >= _minMetersToStartTrip) {
        _tripStartPoint = _anchorAfterStop;
        _tripStartTime = now;
        _tripPoints = [_tripStartPoint!, p];
        _maybeStationarySince = null;
        _lastPointForStationaryCheck = p;
      } else {
        _anchorAfterStop = p;
      }
      return;
    }

    final last = _tripPoints.last;
    final step = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      p.latitude,
      p.longitude,
    );
    if (step > _minMetersBetweenPathPoints) {
      _tripPoints.add(p);
    }

    final ref = _lastPointForStationaryCheck ?? p;
    final distFromRef = Geolocator.distanceBetween(
      ref.latitude,
      ref.longitude,
      p.latitude,
      p.longitude,
    );
    if (distFromRef < _stationaryRadiusM) {
      _maybeStationarySince ??= now;
      if (now.difference(_maybeStationarySince!).inSeconds >= _stationarySeconds) {
        final endedAt = now;
        final route = List<LatLng>.of(_tripPoints);
        if (route.length < 2) {
          route.add(p);
        } else {
          route[route.length - 1] = p;
        }
        final completed = TripSegment(
          start: _tripStartPoint!,
          end: p,
          startedAt: _tripStartTime!,
          endedAt: endedAt,
          points: route,
        );
        _trips.insert(0, completed);
        Future.microtask(() async {
          await TripNotifications.showTripEnded(distanceKm: completed.distanceKm());
          await _persistTripToBackend(completed);
        });
        while (_trips.length > _maxStoredTrips) {
          _trips.removeLast();
        }
        if (_highlightTripIndex != null) {
          _highlightTripIndex = _highlightTripIndex! + 1;
          if (_highlightTripIndex! >= _trips.length) {
            _highlightTripIndex = null;
          }
        }
        _tripStartPoint = null;
        _tripStartTime = null;
        _tripPoints = [];
        _anchorAfterStop = p;
        _maybeStationarySince = null;
        _lastPointForStationaryCheck = null;
      }
    } else {
      _maybeStationarySince = null;
      _lastPointForStationaryCheck = p;
    }
  }

  Future<void> _fitTripBounds(List<LatLng> pts) async {
    if (!_mapController.isCompleted || pts.isEmpty) return;
    var minLat = pts.first.latitude;
    var maxLat = pts.first.latitude;
    var minLng = pts.first.longitude;
    var maxLng = pts.first.longitude;
    for (final x in pts) {
      minLat = min(minLat, x.latitude);
      maxLat = max(maxLat, x.latitude);
      minLng = min(minLng, x.longitude);
      maxLng = max(maxLng, x.longitude);
    }
    if ((maxLat - minLat).abs() < 1e-5 && (maxLng - minLng).abs() < 1e-5) {
      final c = await _mapController.future;
      await c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(minLat, minLng), 15));
      return;
    }
    final c = await _mapController.future;
    await c.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        56,
      ),
    );
  }

  Future<void> _selectTrip(int index) async {
    setState(() {
      _highlightTripIndex = _highlightTripIndex == index ? null : index;
      _rebuildPolylines();
      _syncTripMarkers();
    });
    if (_highlightTripIndex != null) {
      await _fitTripBounds(_trips[_highlightTripIndex!].points);
    }
  }

  Future<void> _focusActiveTrip() async {
    setState(() {
      _highlightTripIndex = null;
      _rebuildPolylines();
      _syncTripMarkers();
    });
    final pts = _activePolylinePoints();
    if (pts.length >= 2) {
      await _fitTripBounds(pts);
    }
  }

  double _polylineLengthMeters(List<LatLng> pts) {
    if (pts.length < 2) return 0;
    var m = 0.0;
    for (var i = 1; i < pts.length; i++) {
      m += Geolocator.distanceBetween(
        pts[i - 1].latitude,
        pts[i - 1].longitude,
        pts[i].latitude,
        pts[i].longitude,
      );
    }
    return m;
  }

  double _activeTripDistanceKm() =>
      _polylineLengthMeters(_activePolylinePoints()) / 1000.0;

  double _totalDistanceKm() {
    var m = 0.0;
    for (final t in _trips) {
      m += t.pathLengthMeters();
    }
    if (_tripStartPoint != null && _tripPoints.isNotEmpty) {
      m += _polylineLengthMeters(_activePolylinePoints());
    }
    return m / 1000.0;
  }

  String _formatKm(double km) => '${km.toStringAsFixed(2)} km';

  Future<void> _startTracking() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission denied');
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Location services disabled');
      return;
    }
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      ),
    ).listen((pos) async {
      final here = LatLng(pos.latitude, pos.longitude);
      _lastGps = here;
      final me = Marker(
        markerId: MarkerId(widget.identity),
        position: here,
        infoWindow: const InfoWindow(title: 'Me'),
      );
      setState(() {
        _markers[widget.identity] = me;
        _handleTripTracking(here, DateTime.now());
        _rebuildPolylines();
        _syncTripMarkers();
        if (_tripStartPoint != null && _tripPoints.isNotEmpty) {
          _status =
              'Trip in progress — stay within ~${_stationaryRadiusM.toInt()}m for ${_stationarySeconds}s to finish';
        } else if (_trips.isEmpty) {
          _status =
              'Live tracking — move ~${_minMetersToStartTrip.toInt()}m from a stop to start a trip';
        } else {
          _status = 'Live tracking · ${_trips.length} trip${_trips.length == 1 ? '' : 's'} recorded';
        }
      });
      try {
        await widget.api.upsertLocation(
          userId: widget.identity,
          lat: pos.latitude,
          lng: pos.longitude,
        );
      } catch (_) {}
      if (_mapController.isCompleted) {
        final c = await _mapController.future;
        await c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        GoogleMap(
          initialCameraPosition: const CameraPosition(
            target: LatLng(-25.2744, 133.7751),
            zoom: 3.7,
          ),
          myLocationEnabled: true,
          markers: _markers.values.toSet(),
          polylines: _polylines,
          onMapCreated: (c) {
            if (!_mapController.isCompleted) _mapController.complete(c);
          },
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.16,
          minChildSize: 0.12,
          maxChildSize: 0.78,
          builder: (context, scrollController) {
            final hasListContent =
                _trips.isNotEmpty || (_tripStartPoint != null && _tripPoints.isNotEmpty);
            final totalKm = _totalDistanceKm();
            return Material(
              elevation: 10,
              shadowColor: Colors.black45,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              clipBehavior: Clip.antiAlias,
              color: Theme.of(context).colorScheme.surface,
              child: ListView(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: 12 + bottomSafe),
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (!hasListContent)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Swipe up for trips and per-trip distance (km).',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  if (hasListContent) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text(
                        'Trips (start → stop)',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    if (_tripStartPoint != null && _tripPoints.isNotEmpty)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        leading: Icon(Icons.near_me, color: Colors.blue.shade600),
                        title: const Text('In progress'),
                        subtitle: _tripStartTime != null
                            ? Text(
                                'Started ${_tripStartTime!.hour.toString().padLeft(2, '0')}:${_tripStartTime!.minute.toString().padLeft(2, '0')}',
                              )
                            : null,
                        trailing: Text(
                          _formatKm(_activeTripDistanceKm()),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        onTap: _focusActiveTrip,
                      ),
                    for (var i = 0; i < _trips.length; i++)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        leading: const Icon(Icons.route_outlined),
                        title: Text(_trips[i].summary),
                        trailing: Text(
                          _formatKm(_trips[i].distanceKm()),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        selected: _highlightTripIndex == i,
                        onTap: () => _selectTrip(i),
                      ),
                  ],
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    title: Text(
                      'Total distance',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    trailing: Text(
                      _formatKm(totalKm),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.channels,
    required this.onCreateChannel,
    required this.onDeleteChannel,
    required this.currentUserId,
    required this.users,
    required this.channelJoinRequests,
    required this.onApproveJoinRequest,
  });
  final List<Channel> channels;
  final Future<void> Function(String name, {bool isPrivate}) onCreateChannel;
  final void Function(Channel channel) onDeleteChannel;
  final String currentUserId;
  final List<UserAccount> users;
  final Map<String, Set<String>> channelJoinRequests;
  final void Function({
    required String channelId,
    required String requestUserId,
  }) onApproveJoinRequest;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final TextEditingController _channelController = TextEditingController();
  bool _isPrivate = false;

  @override
  void dispose() {
    _channelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String usernameById(String id) {
      final user = widget.users.where((u) => u.id == id).toList();
      return user.isEmpty ? id : user.first.username;
    }

    final ownedChannels = widget.channels
        .where((c) => c.createdByUserId == widget.currentUserId)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          const Text('Manage Channels', style: TextStyle(fontSize: 18)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _channelController,
                  decoration: const InputDecoration(hintText: 'Create channel'),
                ),
              ),
              FilterChip(
                label: const Text('Private'),
                selected: _isPrivate,
                onSelected: (v) => setState(() => _isPrivate = v),
              ),
              ElevatedButton(
                onPressed: () async {
                  await widget.onCreateChannel(
                    _channelController.text,
                    isPrivate: _isPrivate,
                  );
                  _channelController.clear();
                },
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...widget.channels.map(
            (c) => Card(
              child: ListTile(
                title: Text(c.name),
                subtitle: Text(
                  c.createdByUserId == null
                      ? 'Channel ID: ${c.id}'
                      : 'Owner: ${usernameById(c.createdByUserId!)}',
                ),
                trailing: c.createdByUserId == widget.currentUserId
                    ? IconButton(
                        tooltip: 'Delete channel',
                        onPressed: () => widget.onDeleteChannel(c),
                        icon: const Icon(Icons.delete, color: Colors.red),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Private Join Requests', style: TextStyle(fontSize: 18)),
          ...ownedChannels
              .where((c) => c.isPrivate)
              .map((channel) {
                final requests =
                    widget.channelJoinRequests[channel.id] ?? const <String>{};
                if (requests.isEmpty) {
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.lock_clock),
                      title: Text(channel.name),
                      subtitle: const Text('No pending requests'),
                    ),
                  );
                }
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        ...requests.map(
                          (userId) => ListTile(
                            dense: true,
                            title: Text('@${usernameById(userId)}'),
                            trailing: TextButton(
                              onPressed: () => widget.onApproveJoinRequest(
                                channelId: channel.id,
                                requestUserId: userId,
                              ),
                              child: const Text('Approve'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              })
              .toList(),
        ],
      ),
    );
  }
}

class UserProfileDraft {
  UserProfileDraft({
    required this.username,
    required this.fullName,
    required this.dateOfBirth,
    required this.suburb,
    required this.stateName,
  });

  String username;
  String fullName;
  String dateOfBirth;
  String suburb;
  String stateName;
}

class UserProfilePage extends StatefulWidget {
  const UserProfilePage({
    super.key,
    required this.user,
    required this.canSave,
    required this.onUploadProfilePicture,
    required this.onSave,
  });

  final UserAccount user;
  final bool canSave;
  final Future<String?> Function(XFile file) onUploadProfilePicture;
  final ValueChanged<UserProfileDraft> onSave;

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _fullNameCtrl;
  late final TextEditingController _dobCtrl;
  late final TextEditingController _suburbCtrl;
  late final TextEditingController _stateCtrl;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: widget.user.username);
    _fullNameCtrl = TextEditingController(text: widget.user.fullName);
    _dobCtrl = TextEditingController(text: widget.user.dateOfBirth);
    _suburbCtrl = TextEditingController(text: widget.user.suburb);
    _stateCtrl = TextEditingController(text: widget.user.stateName);
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _fullNameCtrl.dispose();
    _dobCtrl.dispose();
    _suburbCtrl.dispose();
    _stateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('@${widget.user.username} profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Center(
              child: CircleAvatar(
                radius: 34,
                backgroundColor: Color(widget.user.avatarColorValue),
                backgroundImage: widget.user.profileImageUrl != null
                    ? NetworkImage(widget.user.profileImageUrl!)
                    : null,
                child: widget.user.profileImageUrl == null
                    ? const Icon(Icons.account_circle, size: 38, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            if (widget.canSave)
              Align(
                alignment: Alignment.center,
                child: TextButton.icon(
                  onPressed: _uploadingPhoto
                      ? null
                      : () async {
                          final picker = ImagePicker();
                          final file =
                              await picker.pickImage(source: ImageSource.gallery);
                          if (file == null) return;
                          setState(() => _uploadingPhoto = true);
                          final url =
                              await widget.onUploadProfilePicture(file);
                          if (mounted) {
                            setState(() => _uploadingPhoto = false);
                          }
                          if (!mounted) return;
                          if (url == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Profile picture upload failed',
                                ),
                              ),
                            );
                          }
                        },
                  icon: _uploadingPhoto
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_camera),
                  label: const Text('Upload Profile Picture'),
                ),
              ),
            const SizedBox(height: 16),
            TextField(controller: _usernameCtrl, decoration: const InputDecoration(labelText: 'Username')),
            TextField(controller: _fullNameCtrl, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: _dobCtrl, decoration: const InputDecoration(labelText: 'Date of Birth')),
            TextField(controller: _suburbCtrl, decoration: const InputDecoration(labelText: 'Suburb')),
            TextField(controller: _stateCtrl, decoration: const InputDecoration(labelText: 'State')),
            const SizedBox(height: 14),
            if (widget.canSave)
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () {
                    widget.onSave(
                      UserProfileDraft(
                        username: _usernameCtrl.text,
                        fullName: _fullNameCtrl.text,
                        dateOfBirth: _dobCtrl.text,
                        suburb: _suburbCtrl.text,
                        stateName: _stateCtrl.text,
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save Profile'),
                ),
              )
            else
              const Text('Read-only profile'),
          ],
        ),
      ),
    );
  }
}

class ExploreScreen extends StatelessWidget {
  const ExploreScreen({
    super.key,
    required this.channels,
    required this.users,
    required this.joinedChannelIds,
    required this.onRequestJoinPublicGroup,
    required this.onRequestJoinPrivateGroup,
    required this.onOpenGroup,
    required this.channelJoinRequests,
    required this.currentUserId,
    required this.onOpenProfile,
  });

  final List<Channel> channels;
  final List<UserAccount> users;
  final Set<String> joinedChannelIds;
  final Future<void> Function(Channel channel) onRequestJoinPublicGroup;
  final void Function(Channel channel) onRequestJoinPrivateGroup;
  final Future<void> Function(Channel channel) onOpenGroup;
  final Map<String, Set<String>> channelJoinRequests;
  final String currentUserId;
  final Future<void> Function(UserAccount user) onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final publicGroups = channels.where((c) => !c.isPrivate).toList();
    final privateGroups = channels.where((c) => c.isPrivate).toList();
    final activePeople = users.where((u) => u.isActive).toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          const Text('Explore Groups', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          const Text('Public Active Groups', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...publicGroups.map(
            (group) => Card(
              child: ListTile(
                leading: const Icon(Icons.groups),
                title: Text(group.name),
                subtitle: Text(joinedChannelIds.contains(group.id) ? 'Joined' : 'Public group'),
                onTap: () => onOpenGroup(group),
                trailing: joinedChannelIds.contains(group.id)
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : TextButton(
                        onPressed: () => onRequestJoinPublicGroup(group),
                        child: const Text('Join Now'),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Private Active Groups', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...privateGroups.map(
            (group) => Card(
              child: ListTile(
                leading: const Icon(Icons.lock),
                title: Text(group.name),
                onTap: () => onOpenGroup(group),
                subtitle: Text(() {
                  if (joinedChannelIds.contains(group.id)) return 'Joined private group';
                  final pending = channelJoinRequests[group.id]?.contains(currentUserId) == true;
                  return pending ? 'Request pending approval' : 'Private group (approval required)';
                }()),
                trailing: joinedChannelIds.contains(group.id)
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : TextButton(
                        onPressed: () => onRequestJoinPrivateGroup(group),
                        child: const Text('Request Approval'),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Active People', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...activePeople.map(
            (person) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(person.avatarColorValue),
                  child: const Icon(Icons.account_circle, color: Colors.white),
                ),
                title: Text(person.username),
                subtitle: Text('${person.fullName} • ${person.suburb}, ${person.stateName}'),
                onTap: () => onOpenProfile(person),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
