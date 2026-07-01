# engine2 HTTP 모듈 — FUTURE 작업 목록

## 타임아웃

- ✅ `client.fetch()`에 `timeout_ms` 옵션 추가
- `std.http.Client` 직접 연결 timeout 주입은 stdlib 내부 연결 생성 경계 때문에 별도 추적

## HMAC-SHA256 서명

- 트레이딩 API 인증용
- `std.crypto.auth.hmac.sha2`로 구현 가능
- 2차 추가 예정

## Rate Limit 대응

- 거래소별 정책 다름
- 앱 레벨에서 구현 필요

## HTTP/2

- ALPN 협상 필요
- stdlib 미지원
- `HttpServer.listenHttp2()`는 지원 경계를 `error.UnsupportedHttp2`로 명시

## WebSocket 클라이언트 mTLS

- 클라이언트 인증서 필요 시
- `websocket.client.ConnectOptions.mtls`는 추가됨
- Zig 0.16 stdlib가 client certificate 핸드셰이크를 노출하지 않아 현재는 `error.UnsupportedMtls`

## 쿠키 스레드 안전

- ✅ CookieJar 내부 변경을 `utils.SpinLock`으로 보호

## 스트리밍 업로드

- 현재 메모리 업로드만 지원
- 대용량 파일 대응 필요

## 서버 TLS

- `std.crypto.tls` 서버 사이드 핸드셰이크 미구현
- 현재 HTTP(평문)만
- `HttpServer.listenTls()`는 지원 경계를 `error.UnsupportedServerTls`로 명시

## Service Worker 서버

- WASM에서 가짜 HTTP 서버
- 브라우저 전용, 낮은 우선순위

## 정적 파일 ETag

- ✅ 실제 SHA-256 기반 ETag 구현 완료
- ✅ Last-Modified 헤더 지원 완료
- If-Modified-Since 조건부 요청 지원
- FUTURE: Range 요청 + 206 Partial Content 지원

## 서버 라우터 개선

- 현재 prefix 매칭 (longest prefix wins)
- FUTURE: 파라미터화된 경로 (/users/:id)
- FUTURE: 정규식 기반 라우팅
- FUTURE: 트리 기반 라우터 (radix tree)

## 미들웨어 체인

- 현재 간단한 재귀 체인
- FUTURE: 조기 종료 (abort), 에러 핸들러 분리
- ✅ **WebSocket 업그레이드 시 미들웨어 체인 종료 처리 완료** — `HttpServer.handleConnection`이 `upgradeRequested() == .websocket` 분기에서 WS 라우트 핸들러를 직접 호출 후 `return`하여 HTTP 미들웨어 체인을 우회함. WS 핸들러는 HTTP 미들웨어의 다음/에러 핸들러를 받지 않음.

## WASM JS 연동

- ✅ client_web.zig / websocket_web.zig extern을 `web/webgpu_glue.js`에 연결
- ✅ fetch/WebSocket 모두 handle-based polling 패턴 사용

## 서버 커넥션 풀

- ✅ accept된 connection을 `utils.ThreadPool` task로 처리
- connection keep-alive 고도화는 별도 future

## 압축

- ✅ gzip 응답 압축
- ✅ Accept-Encoding 협상
- brotli 응답 압축은 현재 `deps/brotli`가 decoder-only 빌드라 제외

## WebSocket 서버/클라이언트

- ✅ **2026-06-18 구현 완료**
- RFC 6455 full 구현 (서버/클라이언트)
- 서버: `HttpServer.wsOpts(path, handler, opts)` / `wsSimple(path, handler)` 등록
- 클라이언트: `websocket.client.WsStream.connect(allocator, httpClient, opts)`
- 공용 코덱: fragmentation, masking, ping/pong, close
- 제외: WASM 서버, HTTP/2, 서버 TLS, extensions, auto-reconnect

## WebSocket 고도화 (FUTURE)

- 타임아웃 설정
- ✅ route별 max_message_size 튜닝 (`wsOpts`)
- Auto-reconnect / heartbeat loop
- WebSocket over HTTP/2 (RFC 8441)

## 타임아웃

- ✅ `client.fetch()`에 `timeout_ms` 옵션 추가
- `std.http.Client` 직접 연결 timeout 주입은 stdlib 내부 연결 생성 경계 때문에 별도 추적
