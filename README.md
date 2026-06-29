# http

`http`는 engine2와 함께 쓰기 위한 Zig 0.16 기반 HTTP 서버 / 클라이언트 / 웹소켓 패키지다.

## 제공 기능

- **서버** — 멀티스레드 TCP acceptor + connection pool 기반 비동기 HTTP/1.1 서버
  (`std.http.Server` 위에 `utils.ThreadPool` 기반)
- **클라이언트** — 네이티브(`std.http.Client`) / 웹(fetch) 양쪽 백엔드 제공
- **웹소켓** — RFC 6455 codec + 클라이언트/서버 (네이티브 전용)
- **쿠키** — RFC 6265 `CookieJar` (`utils.SpinLock` 기반 동시성 보호)
- **템플릿** — `{{ name }}` 변수 치환 + `{% if %}` / `{% for %}` 블록
- **정적 파일 서빙** — MIME 타입 자동 추정 + 경로 traversal 방어
- **압축** — gzip/deflate 압축 협상
- **업로드** — multipart/form-data 파서
- **미들웨어** — composable 요청 처리 파이프라인

## 플랫폼

- 네이티브 (`builtin.os.tag != .freestanding`): 풀 서버 + 클라이언트 + 웹소켓
- `wasm32-freestanding`: 클라이언트는 fetch 스텁, 서버는 빈 스텁

## 의존성

- [`utils`](https://github.com/SpaceTravelCompany/utils) — `SpinLock`, `ThreadPool`, `noOpWorker`
