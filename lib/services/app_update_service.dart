import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum AppUpdateSource { googlePlay, github }

enum AppUpdateStatus {
  checking,
  unsupported,
  upToDate,
  available,
  downloading,
  readyToInstall,
  completed,
  cancelled,
  failed,
}

class AppUpdateState {
  const AppUpdateState({
    required this.status,
    this.source,
    this.currentVersion,
    this.latestVersion,
    this.availableVersionCode,
    this.flexibleAllowed = false,
    this.immediateAllowed = false,
    this.downloadUrl,
    this.releasePageUrl,
    this.releaseNotes,
    this.message,
  });

  final AppUpdateStatus status;
  final AppUpdateSource? source;
  final String? currentVersion;
  final String? latestVersion;
  final int? availableVersionCode;
  final bool flexibleAllowed;
  final bool immediateAllowed;
  final Uri? downloadUrl;
  final Uri? releasePageUrl;
  final String? releaseNotes;
  final String? message;
}

class AppUpdateService {
  static final Uri _latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/nzfreeman/mobile-pdf-editor/releases/latest',
  );

  AppUpdateInfo? _updateInfo;

  Future<AppUpdateState> check() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    if (!Platform.isAndroid) {
      return AppUpdateState(
        status: AppUpdateStatus.unsupported,
        currentVersion: currentVersion,
        message: '현재 자동 업데이트는 Android에서 지원됩니다.',
      );
    }

    if (packageInfo.installerStore == 'com.android.vending') {
      return _checkGooglePlay(currentVersion);
    }
    return _checkGitHub(packageInfo, currentVersion);
  }

  Future<AppUpdateState> _checkGooglePlay(String currentVersion) async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      _updateInfo = info;
      final available =
          info.updateAvailability == UpdateAvailability.updateAvailable ||
              info.updateAvailability ==
                  UpdateAvailability.developerTriggeredUpdateInProgress;

      return AppUpdateState(
        status: available ? AppUpdateStatus.available : AppUpdateStatus.upToDate,
        source: AppUpdateSource.googlePlay,
        currentVersion: currentVersion,
        availableVersionCode: info.availableVersionCode,
        flexibleAllowed: info.flexibleUpdateAllowed,
        immediateAllowed: info.immediateUpdateAllowed,
        message: available
            ? 'Google Play에 새 업데이트가 있습니다.'
            : 'Google Play 최신 버전입니다.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        currentVersion: currentVersion,
        message: 'Google Play 업데이트 확인 실패: $error',
      );
    }
  }

  Future<AppUpdateState> _checkGitHub(
    PackageInfo packageInfo,
    String currentVersion,
  ) async {
    try {
      final response = await http.get(
        _latestReleaseApi,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('GitHub 응답 코드 ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (json['tag_name'] as String? ?? '').trim();
      final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');
      final releasePage = Uri.tryParse(json['html_url'] as String? ?? '');
      final releaseNotes = (json['body'] as String? ?? '').trim();
      final assets = (json['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final apkAsset = assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) {
              final name = (asset?['name'] as String? ?? '').toLowerCase();
              return name.endsWith('.apk');
            },
            orElse: () => null,
          );
      final downloadUrl = Uri.tryParse(
        apkAsset?['browser_download_url'] as String? ?? '',
      );

      final currentParts = _versionParts(
        '${packageInfo.version}+${packageInfo.buildNumber}',
      );
      final latestParts = _versionParts(latestVersion);
      final available = _compareVersions(latestParts, currentParts) > 0;

      return AppUpdateState(
        status: available ? AppUpdateStatus.available : AppUpdateStatus.upToDate,
        source: AppUpdateSource.github,
        currentVersion: currentVersion,
        latestVersion: latestVersion.isEmpty ? null : latestVersion,
        downloadUrl: downloadUrl,
        releasePageUrl: releasePage,
        releaseNotes: releaseNotes.isEmpty ? null : releaseNotes,
        message: available
            ? 'GitHub에 새 APK 버전이 있습니다.'
            : 'GitHub 최신 버전입니다.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.github,
        currentVersion: currentVersion,
        message: 'GitHub 업데이트 확인 실패: $error',
      );
    }
  }

  List<int> _versionParts(String value) {
    final normalized = value.replaceFirst(RegExp(r'^[vV]'), '');
    final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\+(\d+))?')
        .firstMatch(normalized);
    if (match == null) return const [0, 0, 0, 0];
    return List<int>.generate(
      4,
      (index) => int.tryParse(match.group(index + 1) ?? '') ?? 0,
    );
  }

  int _compareVersions(List<int> left, List<int> right) {
    for (var index = 0; index < 4; index++) {
      if (left[index] != right[index]) return left[index].compareTo(right[index]);
    }
    return 0;
  }

  Future<bool> openGitHubDownload(AppUpdateState state) async {
    final target = state.downloadUrl ?? state.releasePageUrl;
    if (target == null) return false;
    return launchUrl(target, mode: LaunchMode.externalApplication);
  }

  Future<AppUpdateState> startFlexible() async {
    final info = _updateInfo;
    if (info == null || !info.flexibleUpdateAllowed) {
      return const AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        message: '백그라운드 업데이트를 시작할 수 없습니다.',
      );
    }

    try {
      final result = await InAppUpdate.startFlexibleUpdate();
      if (result == AppUpdateResult.userDeniedUpdate) {
        return const AppUpdateState(
          status: AppUpdateStatus.cancelled,
          source: AppUpdateSource.googlePlay,
          message: '업데이트가 취소되었습니다.',
        );
      }
      if (result == AppUpdateResult.inAppUpdateFailed) {
        return const AppUpdateState(
          status: AppUpdateStatus.failed,
          source: AppUpdateSource.googlePlay,
          message: '업데이트 다운로드를 시작하지 못했습니다.',
        );
      }
      return const AppUpdateState(
        status: AppUpdateStatus.readyToInstall,
        source: AppUpdateSource.googlePlay,
        message: '업데이트 다운로드가 완료되었습니다. 설치를 진행하세요.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        message: '업데이트 다운로드 실패: $error',
      );
    }
  }

  Future<AppUpdateState> completeFlexible() async {
    try {
      await InAppUpdate.completeFlexibleUpdate();
      return const AppUpdateState(
        status: AppUpdateStatus.completed,
        source: AppUpdateSource.googlePlay,
        message: '업데이트 설치를 시작했습니다.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        message: '업데이트 설치 실패: $error',
      );
    }
  }

  Future<AppUpdateState> startImmediate() async {
    final info = _updateInfo;
    if (info == null || !info.immediateUpdateAllowed) {
      return const AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        message: '즉시 업데이트를 시작할 수 없습니다.',
      );
    }

    try {
      final result = await InAppUpdate.performImmediateUpdate();
      return switch (result) {
        AppUpdateResult.success => const AppUpdateState(
            status: AppUpdateStatus.completed,
            source: AppUpdateSource.googlePlay,
            message: '업데이트가 완료되었습니다.',
          ),
        AppUpdateResult.userDeniedUpdate => const AppUpdateState(
            status: AppUpdateStatus.cancelled,
            source: AppUpdateSource.googlePlay,
            message: '업데이트가 취소되었습니다.',
          ),
        AppUpdateResult.inAppUpdateFailed => const AppUpdateState(
            status: AppUpdateStatus.failed,
            source: AppUpdateSource.googlePlay,
            message: '업데이트에 실패했습니다.',
          ),
      };
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        source: AppUpdateSource.googlePlay,
        message: '업데이트 실패: $error',
      );
    }
  }
}
