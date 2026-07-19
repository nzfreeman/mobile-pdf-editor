# Mobile PDF Editor

Flutter 기반 모바일 PDF 편집기 및 PDF 도구 모음입니다.

## Legal

- [Privacy Policy](PRIVACY_POLICY.md)
- [Terms of Use](TERMS_OF_USE.md)

Google Play Console의 Privacy Policy URL에는 아래 공개 GitHub 문서 주소를 사용할 수 있습니다.

```text
https://github.com/nzfreeman/mobile-pdf-editor/blob/main/PRIVACY_POLICY.md
```

## 구현된 기능

- 다중 페이지 PDF 열기 및 페이지 이동
- 페이지별 텍스트와 체크 표시 추가
- 손가락 자유 필기
- 서명 패드에서 서명 생성
- 사진 추가(앨범/카메라)
- 도장 PNG/JPG 추가
- 추가한 요소 이동, 크기 조절 및 회전
- 텍스트 수정, 복제, 삭제
- 실행 취소 및 다시 실행
- 멀티페이지 썸네일
- 원본 모든 페이지와 편집 요소를 합성한 새 PDF 생성
- 기기 저장, 공유 및 인쇄
- 이미지 및 카메라 촬영본을 PDF로 변환
- 페이지 순서 변경, 회전 및 삭제
- 최근 PDF 목록
- 라이트/다크 모드
- Google Play 인앱 업데이트 지원 구조

> 편집은 원본 PDF 내부 문장을 직접 재배치하는 방식이 아니라 페이지 위에 요소를 배치하고 최종 PDF로 평탄화(flatten)하는 방식입니다.

## 실행

```bash
flutter create . --platforms=android,ios
flutter pub get
flutter run
```

프로젝트 폴더에 Android/iOS 기본 폴더가 없다면 첫 번째 명령이 생성합니다.

## Android 권한

`android/app/src/main/AndroidManifest.xml`의 `<manifest>` 아래에 카메라 및 인터넷 권한을 추가합니다.

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
```

최근 Android에서는 사진 선택에 시스템 Photo Picker를 사용하므로 일반적인 사진 선택에는 광범위한 저장소 권한이 필요하지 않습니다.

## iOS 권한

`ios/Runner/Info.plist`의 `<dict>` 안에 추가합니다.

```xml
<key>NSCameraUsageDescription</key>
<string>PDF에 사진을 추가하기 위해 카메라를 사용합니다.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>PDF에 사진이나 도장 이미지를 추가하기 위해 사진 보관함을 사용합니다.</string>
```

## Google Play 인앱 업데이트

인앱 업데이트는 Google Play에서 설치된 앱에서만 실제로 동작합니다.

테스트하려면:

1. 앱을 Google Play Console의 Internal testing 또는 Closed testing 트랙에 업로드합니다.
2. 테스트 계정으로 Play Store에서 앱을 설치합니다.
3. 더 높은 `versionCode`의 새 AAB를 같은 트랙에 업로드합니다.
4. Play Store가 새 버전을 배포한 뒤 앱의 업데이트 버튼을 실행합니다.

GitHub Actions에서 직접 생성한 APK를 수동 설치한 경우 인앱 업데이트는 사용할 수 없으며, 앱에서 이를 안내합니다.

## Google Drive 연결

Google Drive 연동은 Google OAuth 설정 없이는 작동하지 않습니다. 현재 홈 화면의 직접 Drive 연결 기능은 비활성화 상태입니다.

시스템 파일 선택기와 공유 메뉴를 통해 Google Drive 앱을 선택하는 방식은 사용할 수 있습니다.

향후 직접 Google Drive OAuth 기능을 활성화할 때는 다음 설정이 필요합니다.

1. Google Cloud Console에서 프로젝트 생성
2. Google Drive API 활성화
3. OAuth 동의 화면 구성
4. Android OAuth 클라이언트 생성
   - 실제 `applicationId` 등록
   - 개발용 및 배포용 SHA-1 등록
5. iOS OAuth 클라이언트 및 URL Scheme 설정
6. 테스트 사용자 등록

## APK 만들기

```bash
flutter build apk --release
```

출력 위치:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Google Play 제출용 AAB:

```bash
flutter build appbundle --release
```

## 코드 구조

```text
lib/
  models/                     편집 요소와 필기 좌표
  screens/                    홈, PDF 편집기, PDF 도구 및 페이지 관리 화면
  services/pdf_service.dart   PDF 렌더링과 다중 페이지 합성
  services/app_update_service.dart Google Play 인앱 업데이트
  services/app_settings.dart  테마 및 앱 설정
  services/recent_files_service.dart 최근 파일 관리
```

## 현재 제한

- 직접 Google Drive OAuth는 아직 비활성화 상태입니다.
- 암호화 PDF, OCR, 고급 압축 및 자동 문서 테두리 감지는 개발 중입니다.
- 매우 큰 PDF는 페이지 렌더링 과정에서 많은 메모리를 사용할 수 있습니다.
- 입력한 한글을 PDF에 완전히 동일하게 출력하려면 적절한 한글 폰트를 앱 자산으로 포함해야 합니다.
- Privacy Policy와 Terms of Use는 현재 앱 기능을 기준으로 작성됐으며, 광고, 분석, 회원 계정, 결제 또는 클라우드 저장 기능을 추가할 때 갱신해야 합니다.
