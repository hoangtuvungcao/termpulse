# Rà soát phát hành Google Play — TermPulse

Ngày rà soát: **2026-11-27**. Phạm vi: mã nguồn và tài liệu chính thức, không phải chứng nhận được Google Play phê duyệt. Các liên kết chính sách bên dưới được kiểm tra trực tiếp bằng HTTP vào ngày rà soát; cần kiểm tra lại ngay trước khi nộp.

**Trạng thái: chưa đủ điều kiện chốt bản phát hành.** Đã bổ sung nội dung quyền riêng tư/quyền Android trong ứng dụng và chặn cấu hình release thiếu thông tin. Những việc dưới đây vẫn cần chủ phát hành hoàn tất; không tự tạo tên đơn vị, email, website hoặc khóa ký thay chủ phát hành.

## 1. Việc còn thiếu trước khi nộp

- [ ] Cung cấp danh tính đơn vị phát hành thật, email hỗ trợ quyền riêng tư đang hoạt động và URL HTTPS công khai của chính sách. Đối chiếu tên ứng dụng/đơn vị với Store listing và nội dung chính sách. Bản offline trong ứng dụng chưa thay thế được chính sách công khai.
- [ ] Chủ phát hành cung cấp upload keystore và cấu hình riêng `android/key.properties`; giữ khóa/mật khẩu ngoài mã nguồn. Không dùng lại AAB cũ đã được ghi nhận ký bằng debug key. Sửa source không thay đổi chữ ký của tệp đã build trước đó.
- [ ] Điền Data Safety theo hành vi thực tế của bản phát hành, bao gồm AI và các đích do người dùng cấu hình. Không chọn mặc định “không thu thập/chia sẻ dữ liệu” chỉ vì không có backend TermPulse.
- [ ] Hoàn tất khai báo foreground service trong Play Console: giải thích tác vụ, trường hợp sử dụng và video thao tác thực tế. Cần quyết định loại dịch vụ phù hợp cho terminal/SSH đang tương tác và cho truyền tệp; `dataSync` không tự chứng minh hợp lệ cho giữ socket SSH nhàn rỗi vô hạn.
- [ ] Đánh giá chính sách bảo vệ dữ liệu khi truyền đối với API AI qua HTTP, Telnet và VNC TCP không mã hóa. Thông báo/cách chọn tham gia không tự chứng minh những đường truyền này đáp ứng chính sách. Không khai “mọi dữ liệu được mã hóa khi truyền” khi chúng còn được phép.
- [ ] Build lại bản release với cấu hình thật, xác minh chứng thư upload, merged manifest/target SDK, phiên bản và mọi thư viện native của artifact cuối; chạy Pre-launch report, kiểm tra 16 KB và vòng đời Android trên thiết bị tương ứng.
- [ ] Hoàn tất Store listing, ảnh chụp đúng bản phát hành, khai báo quảng cáo/đối tượng/nội dung, mục App access nếu cần, thông tin hỗ trợ và các biểu mẫu còn lại trong tài khoản Play Console. Rà soát này không xác nhận các mục đó đã hoàn tất.

## 2. Yêu cầu nền tảng được kiểm tra ngày 2026-11-27

### Target API

[Google Play — Target API level requirements](https://support.google.com/googleplay/android-developer/answer/11926878) hiện yêu cầu ứng dụng điện thoại mới và bản cập nhật nhắm Android 16/API 36 trở lên từ **2026-08-31**. Không dùng mốc API 35 năm 2025 cho lần nộp mới hiện tại. Source `android/app/build.gradle.kts` đã đặt `compileSdk = 36`, `targetSdk = 36`, giữ NDK `27.0.12077973`; vẫn cần kiểm tra merged manifest của artifact mới, không suy ra từ source rằng AAB cũ đã đạt.

### Chính sách quyền riêng tư và thông báo dữ liệu

[Google Play — User Data](https://support.google.com/googleplay/android-developer/answer/10144311) yêu cầu liên kết chính sách trong Play Console và chính sách/liên kết trong ứng dụng, kể cả ứng dụng không truy cập dữ liệu nhạy cảm. Chính sách phải công khai, hoạt động, không bị giới hạn địa lý, không là PDF, và nêu bên phát hành/liên hệ, dữ liệu, mục đích, bên nhận, bảo vệ/lưu giữ/xóa dữ liệu. Khi cách dùng dữ liệu nhạy cảm nằm ngoài kỳ vọng hợp lý, thông báo nổi bật phải xuất hiện trong luồng tính năng trước đồng ý và trước lời nhắc quyền; chỉ đặt trong Settings không đủ. Source AI đã có thông báo bên nhận và xác nhận trước gửi; đọc chính sách không được coi là đồng ý bắt buộc.

### Data Safety

[Google Play — Data Safety](https://support.google.com/googleplay/android-developer/answer/10787469) định nghĩa việc truyền dữ liệu ra khỏi thiết bị là collection; chỉ xử lý trên thiết bị không cần khai collection. Chia sẻ do người dùng chủ động có thể thuộc ngoại lệ về **sharing** nếu thỏa điều kiện, nhưng không phải miễn trừ mọi collection. Xem xét riêng nội dung prompt AI, file/terminal truyền tới máy chủ/proxy, bên nhận và mục đích. Nội dung người dùng có thể bao gồm nhiều loại dữ liệu; chủ phát hành phải quyết định phân loại dựa trên bản app và hướng dẫn hiện hành. Mọi phiên bản/luồng tùy chọn và SDK thuộc phạm vi biểu mẫu cần được kiểm kê; không cung cấp một biểu mẫu điền sẵn “không dữ liệu” từ audit này.

### Foreground service và giới hạn chạy nền

[Android — Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types#data-sync) liệt kê `dataSync` cho tải lên/tải xuống, đồng bộ, sao lưu/khôi phục, nhập/xuất hoặc xử lý dữ liệu có mục đích cụ thể. Manifest hiện dùng `FOREGROUND_SERVICE_DATA_SYNC` và `foregroundServiceType="dataSync"`. Không tự đổi sang `specialUse`, `connectedDevice` hay loại khác chỉ để tránh giới hạn: cần đối chiếu công việc thực sự, quyền và điều kiện loại tương ứng.

[Android — Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout) quy định với app target Android 15 trở lên: tổng thời gian nền `dataSync` là **6 giờ trong 24 giờ**, dùng chung giữa các service cùng loại; `mediaProcessing` có ngân sách riêng. Người dùng đưa app trở lại foreground đặt lại bộ đếm. Hết hạn gọi `Service.onTimeout(int, int)` và phải dừng nhanh. Source `SshForegroundService.kt` đã có xử lý timeout/dừng, nhưng cần test thực tế; không quảng cáo “giữ SSH nền vĩnh viễn”.

[Google Play — Foreground service declarations](https://support.google.com/googleplay/android-developer/answer/13392821) yêu cầu khai loại FGS từ target Android 14, mô tả tính năng/tác động khi gián đoạn, chọn use case và cung cấp video người dùng kích hoạt. Quyền Android hợp lệ và notification chạy được không thay thế bước Play Console hoặc quyết định xét duyệt. **Khai báo/sự phù hợp của `dataSync` cho các phiên lâu dài vẫn chưa được giải quyết.**

### Thiết bị 16 KB

[Android — Support 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes) hiện nêu yêu cầu hỗ trợ 16 KB cho thiết bị 64-bit với app nhắm Android 15 trở lên và mốc bắt đầu chặn **bản cập nhật từ 2027-02-01**. Đây là nội dung trang chính thức tại ngày rà soát; không sao chép máy móc mốc cũ 2025-11-01, và phải kiểm tra trạng thái/deadline chính xác trong Play Console khi nộp.

App có Rust/Flutter/native libraries nên không được suy ra đạt chỉ từ target SDK hoặc NDK. AGP 8.11.1 đáp ứng khuyến nghị công cụ đóng gói mới, nhưng NDK 27 cần kiểm tra cấu hình liên kết linh hoạt/alignment cho từng `.so`, kể cả thư viện có sẵn. Cần kiểm tra cấu hình bundle/alignment ELF và APK bằng công cụ Android chính thức, rồi chạy trên thiết bị/emulator 16 KB. Không dựa vào chế độ tương thích. Audit nguồn này **chưa xác minh 16 KB của artifact cuối**.

## 3. Kiểm kê dữ liệu thực tế trong source

| Thành phần | Dữ liệu và xử lý đã thấy | Nguồn chính |
| --- | --- | --- |
| Kho thông tin đăng nhập | Mật khẩu, secret/private key/passphrase được mã hóa ChaCha20-Poly1305; khóa dẫn xuất bằng Argon2id. Không phải SQLCipher/mã hóa toàn bộ SQLite. | `rust/crates/core-vault/src/lib.rs`: `derive_key`, `encrypt_bytes`, `upsert_credential` |
| Metadata và lịch sử | Hostname/IP/cổng, nhóm, username/identity metadata, proxy/settings, snippet và lịch sử lệnh lưu trong các cột SQLite thông thường. Một số dòng input kết thúc bằng newline được ghi lịch sử; có thể chứa bí mật người dùng nhập trong lệnh. | Cùng tệp: schema, `record_command_history`; `rust/src/api/session_api.rs`: `send_session_input` |
| Tin cậy SSH và tùy chọn | Host key/fingerprint và metadata endpoint trong known_hosts dạng văn bản; prefs giao diện/macro/index log không tự mã hóa. Khóa Vault không biến dữ liệu này thành ciphertext. | `rust/crates/core-transport/src/host_keys.rs`; `lib/state/settings_provider.dart`; `lib/state/automation_provider.dart` |
| Log và tệp xuất | Ghi log mặc định tắt, yêu cầu xác nhận riêng; chỉ byte terminal nhận từ khi bật, nhưng đầu ra vẫn có thể lộ secret. Log/index và tệp xuất là plaintext; giới hạn 20 MiB mỗi lượt. Dừng ghi khi ngắt/khóa/thoát; reconnect không tự bật lại. | `lib/core/session_log_store.dart`; `lib/state/session_logs_provider.dart`; `lib/features/terminal/session_log_dialog.dart` |
| Export cấu hình | UI JSON gọi `includeSecrets: false` và có xuất SSH config. Metadata vẫn nhạy cảm. Core API có khả năng export kèm secret nếu gọi `include_secrets=true`; không quảng cáo mọi hình thức export đều loại secret. | `lib/features/hosts/import_dialog.dart`; `rust/crates/core-vault/src/lib.rs`: `export_json` |
| AI tùy chọn | Người dùng chọn endpoint/model và xác nhận trước Generate. Gửi prompt, model, OS/shell hints, API key nếu có để xác thực; không tự đính kèm terminal history/Vault. Endpoint/model thay đổi làm mất xác nhận trước đó. HTTP hiện được hỗ trợ kèm cảnh báo, HTTPS được ưu tiên. | `lib/features/ops/bottom_dock.dart`; `rust/src/api/ops_api.rs`; `rust/crates/core-transport/src/lib.rs` |
| Máy chủ/proxy/remote desktop | Dữ liệu kết nối/xác thực, input/output/file đi tới server/proxy người dùng chọn. SSH/SFTP mã hóa; Telnet/VNC TCP cổ điển plaintext; RDP kiểm tra chứng thư theo cấu hình. Chính sách và bản sao phía bên nhận không do thao tác xóa local kiểm soát. | `rust/crates/core-transport`; `rust/src/api/remote_desktop_api.rs`; `README.md` |
| Tài khoản/SDK | Không thấy luồng tài khoản TermPulse, ads SDK, analytics/telemetry SDK hoặc backend tự thu usage trong source/dependency manifest được rà soát. Đây không phải bằng chứng không có data transfer hoặc chứng nhận dependency binary cuối. | `pubspec.yaml`; luồng app trong `lib`; API Rust |
| Backup/xóa | `allowBackup=false` và quy tắc loại root/file/database/sharedpref/external khỏi cloud backup/device transfer. Có xóa log/hồ sơ/host key; xóa dữ liệu Android hoặc gỡ app xóa private app data, nhưng không xóa bản xuất ngoài app hay bản sao máy chủ. Không hứa secure erase ở tầng lưu trữ. | `android/app/src/main/AndroidManifest.xml`; `res/xml/backup_rules.xml`, `data_extraction_rules.xml`; các màn quản lý tương ứng |

Nội dung in-app tại `lib/features/settings/privacy_policy_screen.dart` có VI/EN, đọc offline, tách rõ secret mã hóa với metadata/lịch sử plaintext, bên nhận AI/server, HTTP, log/export và xóa dữ liệu. Khi chưa cấu hình đủ pháp lý, màn hiển thị rõ bản thử nghiệm/dự thảo, không dựng thông tin liên hệ giả. Chủ phát hành cần đăng bản web tương ứng, rà soát pháp lý và duy trì tính nhất quán với app.

## 4. Cấu hình release có chủ ý

1. Chủ khóa sao chép `android/key.properties.example` thành `android/key.properties`, điền `storeFile`, `storePassword`, `keyAlias`, `keyPassword` thật. `storeFile` tương đối được tính từ `android/app`; nên dùng đường dẫn tuyệt đối. Không commit khóa hoặc mật khẩu. `.gitignore` Android đã loại các tệp riêng này.
2. Đặt các biến môi trường bên dưới bằng thông tin thật đã kiểm chứng. Đây là biến của môi trường build, không phải danh tính/giá trị được audit tự tạo.
3. Build bản release mới; kiểm tra upload certificate SHA-256 bằng công cụ ký Android và so với upload certificate trong Play Console. Không ghi mật khẩu lên dòng lệnh/log. Nếu dùng Play App Signing, phân biệt upload key với app-signing key của Google Play.

```sh
flutter build appbundle --release \
  --dart-define="PRIVACY_PUBLISHER_NAME=$PRIVACY_PUBLISHER_NAME" \
  --dart-define="PRIVACY_CONTACT_EMAIL=$PRIVACY_CONTACT_EMAIL" \
  --dart-define="PRIVACY_POLICY_URL=$PRIVACY_POLICY_URL"
```

`validateReleaseConfiguration` chặn task release khi thiếu khóa ký, publisher rỗng, email sai định dạng hoặc URL không phải HTTPS có host. Debug không bị buộc phải có khóa upload hay thông tin chưa được cung cấp. Guard chỉ kiểm tra cấu hình/định dạng, **không chứng minh chủ sở hữu website, nội dung chính sách đầy đủ, email hoạt động hoặc Play đã phê duyệt**. Không đưa bất kỳ giá trị define/credential nào vào thông báo lỗi.

Không có bước deploy, nộp Play Console, xuất bản chính sách web hay xác minh AAB cuối trong rà soát tài liệu này. Kết quả build/device test ở lượt công việc khác cần được ghi riêng với đúng artifact, ngày, thiết bị và phạm vi đã kiểm tra.
