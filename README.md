# Mobile PDF Editor v0.2

Flutter 기반 모바일 PDF 편집기 MVP입니다.

## 구현된 기능

- 다중 페이지 PDF 열기 및 페이지 이동
- 페이지별 텍스트와 체크 표시 추가
- 손가락 자유 필기
- 서명 패드에서 서명 생성
- 사진 추가(앨범/카메라)
- 도장 PNG/JPG 추가
- 추가한 요소 드래그 이동
- 실행 취소 및 다시 실행
- 선택 요소 삭제
- 원본 모든 페이지와 편집 요소를 합성한 새 PDF 생성
- 기기 공유 메뉴로 저장·전송
- Google Drive PDF 목록, 다운로드, 편집 결과 업로드

> 편집은 원본 PDF 내부 문장을 재배치하는 방식이 아니라 페이지 위에 요소를 배치하고 최종 PDF로 평탄화(flatten)하는 방식입니다.

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

## Google Drive 연결

Google Drive 연동은 Google OAuth 설정 없이는 작동하지 않습니다.

1. Google Cloud Console에서 프로젝트 생성
2. Google Drive API 활성화
3. OAuth 동의 화면 구성
4. Android OAuth 클라이언트 생성
   - 실제 `applicationId` 등록
   - 개발 PC의 debug SHA-1 및 배포용 SHA-1 등록
5. iOS OAuth 클라이언트 생성
   - Xcode 프로젝트의 Bundle ID 등록
   - Google이 제공한 reversed client ID를 URL Scheme으로 등록
6. 테스트 중이라면 OAuth 테스트 사용자에 로그인 계정 추가
7. 앱을 다시 빌드

이 프로젝트는 `drive.file` 범위를 사용합니다. 사용자가 앱에서 열거나 앱이 생성한 파일 중심으로 접근하도록 제한된 범위입니다.

## Google Drive 없이 테스트

Google 설정 전에도 다음 기능은 모두 사용할 수 있습니다.

- 기기에서 PDF 열기
- 다중 페이지 편집
- 필기, 텍스트, 사진, 도장, 서명
- 실행 취소/다시 실행
- PDF 생성 및 시스템 공유 메뉴 이용

시스템 공유 메뉴에서 Google Drive 앱을 선택해 편집된 PDF를 Drive에 저장하는 것도 가능합니다.

## APK 만들기

```bash
flutter build apk --release
```

출력 위치:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## 코드 구조

```text
lib/
  models/editor_item.dart       페이지별 편집 요소와 필기 좌표
  screens/home_screen.dart      기기/Drive에서 PDF 열기
  screens/pdf_editor_screen.dart 편집 UI, undo/redo, 내보내기
  services/pdf_service.dart     PDF 렌더링과 다중 페이지 합성
  services/drive_service.dart   Drive 목록/다운로드/업로드
```

## 현재 제한

- 텍스트 크기·색상·폰트 UI는 아직 고정값
- 이미지 크기 조절과 회전 핸들은 아직 없음
- 필기 지우개와 색상 선택은 아직 없음
- 비밀번호로 보호된 PDF는 열리지 않을 수 있음
- 매우 큰 PDF는 모든 페이지를 메모리에 렌더링하므로 최적화 필요
- 한글을 새로 입력한 텍스트가 PDF 출력에서 정확히 보이게 하려면 한글 TTF를 앱 자산으로 포함하고 `pdf` 출력 폰트로 연결하는 작업이 필요
- Google Drive OAuth는 각 앱의 패키지명, 서명키, Bundle ID에 맞게 별도로 설정해야 함
