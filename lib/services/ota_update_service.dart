import 'package:shorebird_code_push/shorebird_code_push.dart';

enum OtaUiStatus {
  checking,
  unavailable,
  upToDate,
  updateAvailable,
  restartRequired,
  downloading,
  failed,
}

class OtaUpdateState {
  const OtaUpdateState({
    required this.status,
    this.currentPatch,
    this.message,
  });

  final OtaUiStatus status;
  final int? currentPatch;
  final String? message;
}

class OtaUpdateService {
  OtaUpdateService({ShorebirdUpdater? updater})
      : _updater = updater ?? ShorebirdUpdater();

  final ShorebirdUpdater _updater;

  bool get isAvailable => _updater.isAvailable;

  Future<OtaUpdateState> check() async {
    if (!_updater.isAvailable) {
      return const OtaUpdateState(
        status: OtaUiStatus.unavailable,
        message: '이 APK는 일반 Flutter 빌드입니다. Shorebird Release 빌드부터 OTA가 활성화됩니다.',
      );
    }

    try {
      final patch = await _updater.readCurrentPatch();
      final status = await _updater.checkForUpdate();
      return OtaUpdateState(
        status: switch (status) {
          UpdateStatus.upToDate => OtaUiStatus.upToDate,
          UpdateStatus.outdated => OtaUiStatus.updateAvailable,
          UpdateStatus.restartRequired => OtaUiStatus.restartRequired,
          UpdateStatus.unavailable => OtaUiStatus.unavailable,
        },
        currentPatch: patch?.number,
      );
    } catch (error) {
      return OtaUpdateState(
        status: OtaUiStatus.failed,
        message: error.toString(),
      );
    }
  }

  Future<OtaUpdateState> download() async {
    if (!_updater.isAvailable) {
      return const OtaUpdateState(
        status: OtaUiStatus.unavailable,
        message: 'Shorebird OTA가 활성화되지 않은 빌드입니다.',
      );
    }

    try {
      await _updater.update();
      final patch = await _updater.readNextPatch();
      return OtaUpdateState(
        status: OtaUiStatus.restartRequired,
        currentPatch: patch?.number,
        message: '업데이트를 내려받았습니다. 앱을 완전히 종료한 뒤 다시 실행하세요.',
      );
    } on UpdateException catch (error) {
      return OtaUpdateState(
        status: OtaUiStatus.failed,
        message: error.message,
      );
    } catch (error) {
      return OtaUpdateState(
        status: OtaUiStatus.failed,
        message: error.toString(),
      );
    }
  }
}
