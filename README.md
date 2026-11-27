# TermPulse

Ứng dụng terminal với giao diện Flutter/Riverpod/xterm và lõi Rust, kết nối qua `flutter_rust_bridge` 2.13.0. Dữ liệu host, nhóm, danh tính, credential, proxy, tunnel và snippet được lưu cục bộ trong SQLite.

## Chức năng và giới hạn

- SSH bằng mật khẩu hoặc private key; kết nối nhanh, jump host và cấu hình kế thừa từ nhóm.
- RDP và VNC nhúng trong ứng dụng: hiển thị desktop, chuột, bàn phím, gõ văn bản Unicode, đổi kích thước vùng xem và kết nối lại. RDP hỗ trợ TLS/NLA/CredSSP; xem giới hạn và cách xác minh chứng thư bên dưới.
- SFTP trong phiên SSH: duyệt, sửa văn bản, tạo/đổi tên/xóa, quyền truy cập, upload/download và điều khiển truyền tệp. Server cần bật SFTP subsystem.
- Terminal nhiều tab, kết nối lại, tìm kiếm, snippet, gửi lệnh nhiều phiên và cảnh báo lệnh nguy hiểm. Cảnh báo là lớp hỗ trợ, không phải sandbox thực thi.
- Tunnel SSH local, remote và dynamic SOCKS; theo dõi tài nguyên máy chủ, kiểm tra TCP và Wake-on-LAN.
- Telnet; local shell qua PTY trên desktop và Android (`/system/bin/sh`, quyền của ứng dụng). iOS chưa hỗ trợ local shell. Telnet không mã hóa lưu lượng.
- Serial native trên Linux, Windows và macOS; Android USB Serial qua USB Host/OTG với hộp thoại cấp quyền của hệ điều hành. Có phát hiện cổng, baud rate, data bits, parity, stop bits và flow control; khả năng thực tế phụ thuộc driver/bộ chuyển đổi. iOS chưa hỗ trợ USB Serial. Bài kiểm tra Linux dùng PTY và kiểm tra Android hiện chưa thay thế thử thiết bị USB thật.
- Giao diện năm ngôn ngữ: tiếng Việt, English, 简体中文, 日本語 và 한국어, gồm thư viện kết nối, cấu hình, menu/hộp thoại và điều khiển remote desktop. Ngôn ngữ ứng dụng không tự dịch đầu ra terminal, nội dung server hoặc phản hồi AI.
- Nhập SSH config, CSV, PuTTY `.reg`; nhập/xuất JSON của Vault và xuất SSH config. Kiểm tra cảnh báo sau khi nhập vì không phải mọi directive đều được ánh xạ.
- Soạn bản nháp lệnh qua endpoint Chat Completions hoặc Ollama `/api/chat` do người dùng cấu hình. Cần tự cung cấp endpoint/model; kết quả phải được xem xét trước khi gửi vào terminal.

Mosh, Eternal Terminal và host SFTP độc lập có trong mô hình dữ liệu nhưng chưa có luồng kết nối tương ứng. Giao diện thích ứng desktop/mobile không có nghĩa mọi chức năng đã được kiểm thử trên mọi hệ điều hành. Dự án dùng Rust native và `dart:io`, chưa hỗ trợ Flutter Web.

### Remote desktop

RDP/VNC hiện yêu cầu kết nối trực tiếp; chưa tích hợp SSH jump, proxy hay RD Gateway cho hai giao thức này. Cấu hình kế thừa proxy/jump không được âm thầm bỏ qua: cần tắt rõ ràng cho host remote desktop. RDP dùng tài khoản/mật khẩu trong Vault; smartcard chưa được bật.

RDP xác minh chứng thư bằng CA và hostname, có thể bổ sung CA PEM/tên TLS. Với chứng thư tự ký, phải đối chiếu toàn bộ SHA256 qua kênh tin cậy trước khi lưu pin; probe lấy fingerprint không thực hiện đăng nhập. Khóa/đổi Vault cũng hủy phiên remote desktop native. Chưa thương lượng RDP clipboard, âm thanh, chuyển tiếp ổ đĩa hoặc máy in; dùng “Gõ văn bản” để gửi Unicode. VNC hỗ trợ clipboard chuẩn RFB Latin-1; văn bản ngoài Latin-1 dùng gõ Unicode. VNC TCP chưa có TLS/tunnel SSH tích hợp, nên chỉ dùng qua mạng tin cậy hoặc VPN.

Backend giới hạn framebuffer ở 8.294.400 pixel, tối đa 8192 pixel mỗi chiều. RDP native đã được thử trên điện thoại Android arm64 với server fixture có kiểm soát, gồm touchpad, thu phóng, toàn màn hình và xoay màn hình. Một lượt smoke tới máy chủ RDP bên ngoài chỉ xác nhận đăng nhập và framebuffer đầu tiên; chưa xác minh thao tác trên desktop thật hoặc tương thích rộng với Windows/AD. VNC native trên Android và runtime iOS chưa được kiểm chứng. Xem phạm vi và kết quả theo ngày trong [báo cáo Android](docs/ANDROID_VERIFICATION_2026-11-27.md); kết quả loopback không đại diện hiệu năng mạng thực.

### Proxy

Proxy được gán cho host hoặc kế thừa từ nhóm và dùng cho kết nối SSH:

| Loại | Xác thực và tùy chọn |
| --- | --- |
| SOCKS4 | Không xác thực hoặc USERID; không hỗ trợ mật khẩu |
| SOCKS5 | Không xác thực hoặc username/password từ Credential loại mật khẩu |
| HTTP CONNECT | Không xác thực, Basic, NTLMv2 hoặc Kerberos/Negotiate; tùy chọn TLS tới proxy |

TLS proxy xác minh chứng chỉ và hostname; có thể bổ sung CA PEM và tên máy chủ TLS. Kerberos cần cấu hình tài khoản/domain, SPN phù hợp và URL KDC rõ ràng (`tcp://`, `udp://` hoặc HTTPS KDC Proxy). Credential của proxy tách biệt với credential của máy chủ SSH. Hỗ trợ trong mã nguồn không bảo đảm tương thích với mọi triển khai proxy/KDC thực tế.

## Bảo mật và dữ liệu cục bộ

Lần đầu mở ứng dụng, tạo mật khẩu chính để khởi tạo Vault; những lần sau dùng mật khẩu đó để mở khóa. Secret của credential được mã hóa bằng ChaCha20-Poly1305 với khóa dẫn xuất Argon2. Đây là mã hóa trường secret, không phải mã hóa toàn bộ cơ sở dữ liệu: metadata như hostname, nhãn và ghi chú vẫn đọc được trong SQLite. JSON xuất kèm secrets chứa bí mật dạng rõ; chỉ lưu/chia sẻ bản xuất ở nơi tin cậy.

SSH yêu cầu xác minh tương tác khi gặp host key hoặc CA mới. Đối chiếu dấu vân tay SHA256 qua kênh tin cậy trước khi chọn tin cậy; thay khóa đã lưu yêu cầu nhập lại dấu vân tay mới. Mục quản lý host key cho phép nhập/xóa key và CA đã xác minh. CA chỉ áp dụng cho hostname/cổng cụ thể; chữ ký, thời hạn và principal của chứng chỉ máy chủ được kiểm tra mỗi lần kết nối.

File tin cậy có hậu tố `.ssh_known_hosts` bên cạnh Vault và được tách riêng theo Vault, không tự dùng `~/.ssh/known_hosts`. Cần mở khóa Vault để quản lý trust. Không tắt xác minh SSH/TLS để xử lý lỗi kết nối.

Ứng dụng lưu `termpulse_vault.db`, `termpulse_vault.db.ssh_known_hosts` và `termpulse_prefs.json` trong thư mục dữ liệu ứng dụng:

- Linux: `$XDG_DATA_HOME/termpulse`, mặc định `$HOME/.local/share/termpulse`.
- Windows: `%APPDATA%\TermPulse`.
- macOS: `$HOME/Library/Application Support/TermPulse`.
- Android: thư mục dữ liệu riêng do native bridge cung cấp.

Khi dùng AI, prompt cùng gợi ý OS/shell được gửi đến endpoint đã chọn. Không đưa mật khẩu, private key hoặc dữ liệu nhạy cảm vào prompt.

## Trạng thái nền tảng

| Nền tảng | Trạng thái được ghi nhận |
| --- | --- |
| Linux | Có luồng build desktop và các bài kiểm tra native/fixture. Serial được kiểm tra qua PTY, chưa thay thế thử bộ chuyển đổi vật lý. |
| Android | Đã build, cài và thử trên điện thoại arm64 thật; xem [báo cáo theo ngày](docs/ANDROID_VERIFICATION_2026-11-27.md). APK debug/profile phục vụ phát triển, không phải bản phát hành Google Play. VNC native, USB Serial vật lý, Android 16 và runtime 16 KB còn cần xác minh. |
| Windows | Có mã nền tảng và job build CI; cần chạy và kiểm chứng trên Windows. Chưa xác nhận bộ cài có chữ ký hoặc quy trình phân phối. |
| macOS | Có mã nền tảng và job build CI; cần chạy và kiểm chứng trên macOS. Chưa xác nhận ký ứng dụng/notarization hoặc phân phối. |
| iOS | Có job biên dịch không ký trên macOS; chưa xác nhận runtime thiết bị, ký/phân phối App Store. Local shell và USB Serial chưa được hỗ trợ. |
| Web | Chưa được hỗ trợ do phụ thuộc Rust native và `dart:io`. |

Workflow được cấu hình không có nghĩa mọi job đã chạy thành công hoặc mọi chức năng đã được thử trên nền tảng đó. [QUALITY_REVIEW.md](QUALITY_REVIEW.md) giữ các mốc QA lịch sử; ưu tiên báo cáo có ngày mới nhất khi đánh giá trạng thái hiện tại.

## Môi trường phát triển

CI trong `.github/workflows/platform-checks.yml` dùng Flutter **3.38.9**, Rust **1.93.0** và JDK **17** cho Android. `pubspec.yaml` yêu cầu Dart `^3.10.8`. Cài toolchain native tương ứng với hệ điều hành đích; chạy build Windows trên Windows, macOS/iOS trên macOS.

Trên Ubuntu, CI cài các phụ thuộc sau cho desktop:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev
```

Chạy từ thư mục gốc dự án:

```sh
git clone https://github.com/hoangtuvungcao/termpulse.git
cd termpulse
flutter pub get
flutter run -d linux
```

Dùng `flutter devices` để xem thiết bị; thay `linux` bằng ID thiết bị phù hợp. Flutter build tích hợp biên dịch Rust qua Cargokit trong `rust_builder/`, không cần tự chép thư viện native. Khi thay đổi API Rust, tạo lại bridge bằng đúng phiên bản:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

Cấu hình sinh mã nằm trong `flutter_rust_bridge.yaml`; không sửa trực tiếp các file `frb_generated*`.

## Kiểm tra và build

Các lệnh kiểm tra chính tương ứng với CI; chạy tại thư mục gốc:

```sh
flutter analyze --no-pub
flutter test --no-pub
cargo test --manifest-path rust/Cargo.toml --workspace --locked
cargo check --manifest-path rust/Cargo.toml --workspace --all-targets --locked
flutter build linux --release
```

CI cũng cấu hình build desktop Windows/macOS, iOS không ký (`flutter build ios --release --no-codesign`) và APK debug (`flutter build apk --debug`). Chạy các lệnh desktop trên đúng hệ điều hành đích. Build iOS không ký chỉ phục vụ kiểm tra biên dịch; cần cấu hình Apple signing và phân phối riêng.

Android yêu cầu JDK 17, SDK/target API 36, NDK `27.0.12077973`, minSdk 24 và các Rust target sau:

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
flutter build apk --debug
```

Release Android dùng cấu hình ký riêng từ `android/key.properties`, không tự dùng debug key. Chủ phát hành sao chép `android/key.properties.example` vào tệp riêng này, cung cấp upload keystore đang tồn tại cùng `storeFile`, `storePassword`, `keyAlias`, `keyPassword`; đường dẫn `storeFile` tương đối được tính từ `android/app`. Không đưa khóa hoặc tệp cấu hình thật vào Git.

Mọi task release còn yêu cầu `PRIVACY_PUBLISHER_NAME`, `PRIVACY_CONTACT_EMAIL` và `PRIVACY_POLICY_URL` qua `--dart-define`. Guard kiểm tra trường bắt buộc, định dạng email và URL HTTPS có host; không xác minh nội dung pháp lý, quyền sở hữu website hoặc phê duyệt của Google Play. Xem lệnh build và các việc còn thiếu trong [rà soát Google Play](docs/GOOGLE_PLAY_RELEASE_REVIEW.md). Các APK debug/profile đã thử trên thiết bị vẫn là bản phát triển ký debug.

### Kiểm tra tích hợp có kiểm soát

Fixture SSH/SFTP chỉ lắng nghe loopback `127.0.0.1:22220`, tạo filesystem tạm và in `QA_SSH_SERVER_FINGERPRINT` khi khởi động:

```sh
cargo run --manifest-path rust/Cargo.toml -p core-transport --example qa_ssh_server --locked
```

Giữ fixture đang chạy. Trong terminal khác, gán `QA_SSH_FINGERPRINT` bằng đúng giá trị `SHA256:…` vừa in rồi chạy:

```sh
flutter test integration_test/qa_functionality_test.dart -d linux \
  --dart-define=QA_SSH_FINGERPRINT="$QA_SSH_FINGERPRINT"
```

Để chạy smoke test Android, dùng thiết bị/emulator đã kết nối, chạy `adb reverse tcp:22220 tcp:22220`, rồi chạy `integration_test/integration_android_smoke_test.dart` với ID thiết bị và cùng `--dart-define`. Các bài này chỉ chấp thuận key khớp fixture, không tự thay key đã lưu. Kiểm tra lifecycle Android bổ sung cần `QA_ANDROID_LIFECYCLE=true` qua `--dart-define` và thao tác đưa ứng dụng ra nền/mở lại theo log của bài test.

Serial PTY trên Linux cần `socat` và môi trường desktop:

```sh
flutter test integration_test/integration_serial_test.dart -d linux
```

Test AI với endpoint thật chỉ chạy khi chủ động đặt `TERMPULSE_AI_QA_ENDPOINT` và `TERMPULSE_AI_QA_MODEL` (tùy chọn `TERMPULSE_AI_QA_KEY`). Khi thiếu endpoint, bài test bỏ qua yêu cầu mạng; việc test suite thành công không chứng minh endpoint/model bên ngoài đã được kiểm tra.

Các fixture remote desktop chạy tự động bằng TCP loopback, không cần cài RDP/VNC server ngoài:

```sh
cargo test --manifest-path rust/Cargo.toml --lib remote_desktop_api --locked -- --nocapture
```

Nhóm này kiểm tra framebuffer, Unicode/input, VNC clipboard Latin-1, TLS/NLA/CredSSP, từ chối sai mật khẩu/chứng thư, probe không đăng nhập, timeout, đóng phiên và hủy khi input queue đầy. `cargo check --target aarch64-linux-android --lib --locked` với NDK là kiểm tra biên dịch; bài native RDP trên Android thật được ghi riêng trong [báo cáo Android](docs/ANDROID_VERIFICATION_2026-11-27.md). Không suy ra kết quả của VNC hoặc USB vật lý từ kiểm tra RDP. Ảnh QA desktop được ghi mặc định dưới `build/qa_screenshots/`; không đưa ảnh/log chưa rà soát vào báo lỗi hoặc bản phát hành.

## Bố cục mã nguồn

- `lib/features/`, `lib/ui/`, `lib/state/`: giao diện, điều phối phiên và trạng thái Riverpod.
- `rust/src/api/`: API native được bridge sang Dart.
- `rust/crates/core-model`, `core-vault`, `core-terminal`, `core-import`, `core-transport`: mô hình, lưu trữ, xử lý terminal, nhập cấu hình và kết nối.
- `rust_builder/`: tích hợp build Rust; `rust/vendor/`: các bản vá dependency cục bộ, được khai báo trong `rust/Cargo.toml`.
- Bản vá dependency có ghi chú trong `rust/vendor/sspi/`, `picky/`, `ironrdp-connector/`, `ironrdp-acceptor/` và `vnc-rs/`; các bản vendor giữ giấy phép upstream. Các tệp `TERMPULSE-PATCH.md` của IronRDP/VNC mô tả thay đổi tương thích SSPI và mã hóa clipboard.
- `test/`, `integration_test/`: test Dart/widget và các bài tích hợp native.
- `QUALITY_REVIEW.md`: ghi nhận kết quả kiểm tra và các hạng mục còn cần xác minh.

## Cộng đồng và phát hành mã nguồn

- [Báo lỗi và đề xuất](https://github.com/hoangtuvungcao/termpulse/issues/new/choose); [thảo luận/câu hỏi](https://github.com/hoangtuvungcao/termpulse/discussions).
- [Hướng dẫn đóng góp](CONTRIBUTING.md) và [quy tắc cộng đồng](CODE_OF_CONDUCT.md).
- [Báo lỗ hổng riêng tư](SECURITY.md). Không đăng khóa, mật khẩu, hostname/IP riêng, bản xuất Vault, log hoặc ảnh desktop chưa khử dữ liệu nhạy cảm lên issue/discussion công khai.
- [Danh sách kiểm tra công bố mã nguồn](docs/PUBLIC_RELEASE.md), gồm tệp được phép đưa vào Git, artifact bị loại và giới hạn ký/phân phối.

Dự án chưa chọn giấy phép chung cho mã nguồn TermPulse. Không suy ra quyền sử dụng/phân phối từ việc repository công khai; trao đổi với chủ dự án trước khi sử dụng lại hoặc đóng góp mã. Font và dependency vendored giữ giấy phép riêng đi kèm.
