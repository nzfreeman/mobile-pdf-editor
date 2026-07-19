import 'dart:io';

import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

enum AppUpdateStatus {
  checking,
  unsupported,
  notPlayInstalled,
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
    this.currentVersion,
    this.availableVersionCode,
    this.flexibleAllowed = false,
    this.immediateAllowed = false,
    this.message,
  });

  final AppUpdateStatus status;
  final String? currentVersion;
  final int? availableVersionCode;
  final bool flexibleAllowed;
  final bool immediateAllowed;
  final String? message;
}

class AppUpdateService {
  AppUpdateInfo? _updateInfo;

  Future<AppUpdateState> check() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    if (!Platform.isAndroid) {
      return AppUpdateState(
        status: AppUpdateStatus.unsupported,
        currentVersion: currentVersion,
        message: 'Google Play 인앱 업데이트는 Android에서만 지원됩니다.',
      );
    }

    if (packageInfo.installerStore != 'com.android.vending') {
      return AppUpdateState(
        status: AppUpdateStatus.notPlayInstalled,
        currentVersion: currentVersion,
        message: '이 앱은 Google Play에서 설치된 버전이 아닙니다.',
      );
    }

    try {
      final info = await InAppUpdate.checkForUpdate();
      _updateInfo = info;
      final available = info.updateAvailability == UpdateAvailability.updateAvailable ||
          info.updateAvailability ==
              UpdateAvailability.developerTriggeredUpdateInProgress;

      return AppUpdateState(
        status: available ? AppUpdateStatus.available : AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        availableVersionCode: info.availableVersionCode,
        flexibleAllowed: info.flexibleUpdateAllowed,
        immediateAllowed: info.immediateUpdateAllowed,
        message: available ? '새 Google Play 업데이트가 있습니다.' : '최신 버전입니다.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        currentVersion: currentVersion,
        message: '업데이트 확인 실패: $error',
      );
    }
  }

  Future<AppUpdateState> startFlexible() async {
    final info = _updateInfo;
    if (info == null || !info.flexibleUpdateAllowed) {
      return const AppUpdateState(
        status: AppUpdateStatus.failed,
        message: 'Flexible Update를 시작할 수 없습니다.',
      );
    }

    try {
      final result = await InAppUpdate.startFlexibleUpdate();
      if (result == AppUpdateResult.userDeniedUpdate) {
        return const AppUpdateState(
          status: AppUpdateStatus.cancelled,
          message: '업데이트가 취소되었습니다.',
        );
      }
      if (result == AppUpdateResult.inAppUpdateFailed) {
        return const AppUpdateState(
          status: AppUpdateStatus.failed,
          message: '업데이트 다운로드를 시작하지 못했습니다.',
        );
      }
      return const AppUpdateState(
        status: AppUpdateStatus.readyToInstall,
        message: '업데이트 다운로드가 완료되었습니다. 설치를 진행하세요.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        message: '업데이트 다운로드 실패: $error',
      );
    }
  }

  Future<AppUpdateState> completeFlexible() async {
    try {
      await InAppUpdate.completeFlexibleUpdate();
      return const AppUpdateState(
        status: AppUpdateStatus.completed,
        message: '업데이트 설치를 시작했습니다.',
      );
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        message: '업데이트 설치 실패: $error',
      );
    }
  }

  Future<AppUpdateState> startImmediate() async {
    final info = _updateInfo;
    if (info == null || !info.immediateUpdateAllowed) {
      return const AppUpdateState(
        status: AppUpdateStatus.failed,
        message: 'Immediate Update를 시작할 수 없습니다.',
      );
    }

    try {
      final result = await InAppUpdate.performImmediateUpdate();
      return switch (result) {
        AppUpdateResult.success => const AppUpdateState(
            status: AppUpdateStatus.completed,
            message: '업데이트가 완료되었습니다.',
          ),
        AppUpdateResult.userDeniedUpdate => const AppUpdateState(
            status: AppUpdateStatus.cancelled,
            message: '업데이트가 취소되었습니다.',
          ),
        AppUpdateResult.inAppUpdateFailed => const AppUpdateState(
            status: AppUpdateStatus.failed,
            message: '업데이트에 실패했습니다.',
          ),
      };
    } catch (error) {
      return AppUpdateState(
        status: AppUpdateStatus.failed,
        message: '업데이트 실패: $error',
      );
    }
  }
}
