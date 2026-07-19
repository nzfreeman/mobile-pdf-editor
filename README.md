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

## Google Drive 연결

Google Drive 연동은 Google OAuth 설정 없이는 작동하지 않습니다. Google Cloud Console에서 Drive API, OAuth 동의 화면, Android/iOS OAuth 클라이언트를 설정해야 합니다.

## APK 만들기

```bash
flutter build apk --release
```

출력 위치:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## 현재 제한

- 텍스트 크기·색상·폰트 UI는 아직 고정값
- 이미지 크기 조절과 회전 핸들은 아직 없음
- 필기 지우개와 색상 선택은 아직 없음
- 비밀번호로 보호된 PDF는 열리지 않을 수 있음
- 한글 PDF 출력에는 한글 TTF 폰트 연결이 필요할 수 있음
