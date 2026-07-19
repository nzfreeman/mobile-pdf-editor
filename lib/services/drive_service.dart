import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path_provider/path_provider.dart';

class DrivePdfFile {
  const DrivePdfFile({
    required this.id,
    required this.name,
    this.modifiedTime,
  });

  final String id;
  final String name;
  final DateTime? modifiedTime;
}

class DriveService {
  static const _scopes = <String>[drive.DriveApi.driveFileScope];

  final GoogleSignIn _signIn = GoogleSignIn.instance;
  Future<void>? _initialization;

  Future<void> _ensureInitialized() {
    return _initialization ??= _signIn.initialize();
  }

  Future<drive.DriveApi> _api() async {
    await _ensureInitialized();
    final account = await _signIn.authenticate();
    final authorization = await account.authorizationClient.authorizeScopes(
      _scopes,
    );
    final client = authorization.authClient(scopes: _scopes);
    return drive.DriveApi(client);
  }

  Future<List<DrivePdfFile>> listPdfFiles() async {
    final api = await _api();
    final response = await api.files.list(
      q: "mimeType='application/pdf' and trashed=false",
      spaces: 'drive',
      orderBy: 'modifiedTime desc',
      pageSize: 50,
      $fields: 'files(id,name,modifiedTime)',
    );
    return (response.files ?? [])
        .where((file) => file.id != null && file.name != null)
        .map(
          (file) => DrivePdfFile(
            id: file.id!,
            name: file.name!,
            modifiedTime: file.modifiedTime,
          ),
        )
        .toList();
  }

  Future<File> download(DrivePdfFile file) async {
    final api = await _api();
    final media = await api.files.get(
      file.id,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    final directory = await getTemporaryDirectory();
    final safeName = file.name.replaceAll(
      RegExp(r'[^a-zA-Z0-9가-힣_.-]'),
      '_',
    );
    final output = File('${directory.path}/$safeName');
    return output.writeAsBytes(bytes, flush: true);
  }

  Future<String> upload(File file) async {
    final api = await _api();
    final metadata = drive.File()
      ..name = file.uri.pathSegments.last
      ..mimeType = 'application/pdf';
    final created = await api.files.create(
      metadata,
      uploadMedia: drive.Media(file.openRead(), await file.length()),
      $fields: 'id',
    );
    if (created.id == null) {
      throw StateError('Google Drive 업로드 결과를 확인할 수 없습니다.');
    }
    return created.id!;
  }

  Future<void> signOut() async {
    await _ensureInitialized();
    await _signIn.signOut();
  }
}
