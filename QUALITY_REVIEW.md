# Rà soát chất lượng TermPulse

> Ghi chép QA lịch sử được lưu lại ngày 27/11/2026. Các cụm “hiện tại” và kết quả bên dưới thuộc thời điểm ghi chép gốc, không xác minh commit được gắn tag cùng báo cáo này. Kết quả Android mới hơn, cấu hình ký release và giới hạn công bố mã nguồn được cập nhật trong [báo cáo Android](docs/ANDROID_VERIFICATION_2026-11-27.md), [rà soát phát hành](docs/GOOGLE_PLAY_RELEASE_REVIEW.md) và [phạm vi công bố](docs/PUBLIC_RELEASE.md).

Ngày: 27/11/2026. Phạm vi: ứng dụng Flutter và lõi Rust trong thư mục `termpulse`. Báo cáo tách lượt mở rộng giao thức/ngôn ngữ hiện tại khỏi các lượt QA trước trong cùng ngày. Kết quả Linux release, ảnh và tổng test cũ ở phần lịch sử không chứng minh bản hiện tại đã build hoặc chạy thành công.

## Lượt mở rộng hiện tại: RDP/VNC, ngôn ngữ và Android

- RDP/VNC có backend nhúng và giao diện xem desktop trong ứng dụng: framebuffer RGBA, chuột, bàn phím, gõ Unicode, trạng thái kết nối và kết nối lại. RDP hỗ trợ TLS cùng NLA/CredSSP; VNC giải mã Raw/CopyRect/ZRLE và thay đổi độ phân giải.
- Host RDP/VNC lưu cấu hình và tham chiếu credential trong Vault. Migration, mở lại cơ sở dữ liệu, export/import và JSON cũ đã có regression. JSON options không chấp nhận password hoặc cờ bỏ xác minh chứng thư.
- RDP xác minh CA/hostname, có CA PEM/tên TLS tùy chọn và pin SHA256 được người dùng đối chiếu. Probe chứng thư dừng trước xác thực. Queue input có giới hạn; cancellation riêng đóng được phiên đang handshake hoặc queue đầy. Khóa/đổi Vault đóng mọi phiên remote desktop native.
- Giao diện năm ngôn ngữ tiếng Việt, English, 简体中文, 日本語 và 한국어 được mở rộng cho thư viện kết nối, cấu hình, menu/hộp thoại, terminal và remote desktop. Chuyển ngôn ngữ áp dụng cả dialog/menu. Nội dung server, đầu ra shell và phản hồi model không được tự dịch.
- Android USB Serial có native USB Host bridge, quét driver/cổng, yêu cầu quyền hệ điều hành, cấu hình baud/data/parity/stop/flow control, dữ liệu hai chiều và xử lý đóng/rút thiết bị. Chưa có adapter Android thật để xác minh driver hoặc flow control phần cứng. iOS vẫn chưa hỗ trợ USB Serial.
- Android Local Shell dùng portable-pty và `/system/bin/sh` với quyền ứng dụng; không cấp root hoặc cung cấp môi trường Termux. iOS giữ trạng thái không hỗ trợ. Đóng tab local shell hiện kết thúc child đang chờ input thay vì giữ reader/master PTY sống.
- Vendor IronRDP connector/acceptor được điều chỉnh cho SSPI hiện có; smartcard RDP chưa bật. Bản vendor vnc-rs sửa ClientCutText/ServerCutText sang Latin-1 chuẩn RFB; Unicode ngoài Latin-1 đi qua key events. Giữ giấy phép và ghi chú `TERMPULSE-PATCH.md`.

### Xác minh lượt hiện tại

| Kiểm tra | Kết quả hiện tại |
| --- | --- |
| Rust workspace | 84 mục báo thành công; trong đó smoke AI tùy chọn không gọi endpoint ngoài nếu chưa cấu hình. Không cộng lại test con vào tổng. |
| Fixture remote desktop native | 13 ca qua: framebuffer/bounds, Unicode/input, VNC clipboard, TLS/NLA/CredSSP, sai mật khẩu, chứng thư chưa tin cậy, probe không đăng nhập, timeout, đóng từ server, cancellation và saved options. Sau lượt toàn workspace, test VNC được tăng kiểm tra clipboard `café` hai hướng và chạy riêng thành công. |
| `cargo check --workspace --all-targets --locked` | Qua trên source hiện tại; còn warning cũ ở vendor picky/rsa. |
| Android native aarch64 | `cargo check --target aarch64-linux-android --lib --locked` qua với NDK `27.0.12077973`, gồm RDP/VNC, portable-pty và nạp CA hệ thống Android. Đây là kiểm tra biên dịch. |
| Flutter analyze và toàn bộ Flutter tests | `flutter analyze --no-pub` sạch; `flutter test --no-pub` qua 235/235 ca, gồm 17 ca remote desktop và Android foreground/USB channel. |
| Build Linux/Android hiện tại | `flutter build linux --release` qua; Android Rust aarch64 và Kotlin USB Serial compile qua. Chưa đóng gói APK cuối trong lượt này. |
| Runtime Android/iOS và phần cứng USB | Chưa có thiết bị kết nối; chưa xác minh trên phần cứng thật. |
| RDP/VNC server ngoài | Chưa thử Windows/Active Directory hoặc VNC bên ngoài; fixture loopback không thay thế kiểm thử tương thích triển khai thực tế. |

RDP/VNC hiện direct-only: chưa tích hợp SSH jump, proxy hoặc RD Gateway. RDP chưa thương lượng clipboard, âm thanh, ổ đĩa hay máy in; dùng “Gõ văn bản” cho Unicode. VNC TCP chưa có TLS/tunnel SSH tích hợp, chỉ nên dùng mạng tin cậy hoặc VPN. Framebuffer tối đa 8.294.400 pixel và 8192 pixel mỗi chiều. Pin chứng thư vẫn cần đối chiếu qua kênh độc lập tin cậy.

## Lịch sử QA trước lượt mở rộng hiện tại

Các mục dưới đây được giữ làm lịch sử regression và cách tái hiện. Mọi cụm “cuối”, “mã cuối” hoặc “release cuối” trong phần lịch sử chỉ bản tại lượt QA trước RDP/VNC/ngôn ngữ/Android hiện tại; các đường dẫn `/tmp` và ảnh có thể không còn tồn tại. Bản release mốc 07:39:57 ngày 27/11/2026 không được coi là release của source hiện tại.

### Các thay đổi của lượt QA trước

- Điều chỉnh giao diện tối sang nền navy/slate, làm rõ lớp nền, viền, trạng thái và nút thao tác; tăng khả năng đọc của giao diện sáng. Kiểm thử độ tương phản cho chữ chính/phụ, nút chính và màu ANSI ở giao diện sáng.
- Đóng gói DejaVu Sans Mono và giấy phép cùng ứng dụng để terminal không phụ thuộc font dự phòng của máy.
- Sửa bố cục ở màn hình điện thoại 360px, tablet, desktop hẹp và cửa sổ thấp 360px. Dock chuyển sang bảng nổi khi chiều cao thiếu; các công cụ vẫn truy cập được.
- Cải thiện focus và nhập lệnh trực tiếp trong terminal; giữ Ctrl+A/Ctrl+C cho shell. Thêm sao chép/dán từ menu chuột phải và phím tắt riêng; dán clipboard lọc ký tự điều khiển, áp dụng command guard cho nội dung rủi ro/nhiều dòng và kiểm tra lại tập phiên nhận trước khi gửi.
- Thêm tìm kiếm trong lịch sử terminal với số kết quả, di chuyển trước/sau, phân biệt hoa/thường và highlight đúng vị trí ký tự Unicode/dòng cuộn. Ctrl/Cmd+K mở bảng lệnh khi terminal có focus; bảng lệnh hỗ trợ phím mũi tên và Enter. Phiên đã đóng có nút kết nối lại.
- Thanh chia desktop cho phép kéo đổi độ rộng panel, điều chỉnh bằng bàn phím và đặt lại kích thước; bố cục tự giới hạn theo khoảng trống của cửa sổ.
- Sửa phím Ctrl/Alt một lần trên mobile, thêm phím Enter và xử lý bố cục khi bàn phím che màn hình.
- Ô soạn lệnh giữ bản nháp khi gửi lỗi hoặc hủy xác nhận, chặn gửi trùng, xử lý gợi ý bất đồng bộ cũ và chỉ hiện tiến trình khi thực sự truyền lệnh.
- Lệnh qua command guard giữ snapshot của tab đang chọn, chế độ broadcast và tập phiên đã xác nhận; kiểm tra lại ngay trước khi gửi sau thời gian chờ trong hàng đợi. Dán broadcast chia payload theo bracketed-paste mode từng terminal nhưng đặt chỗ hàng đợi của mọi nhóm cùng lúc, tránh một nhóm gửi trước trong khi nhóm khác còn chờ và giữ thứ tự trên từng phiên.
- Bổ sung thư viện macro lệnh lưu cục bộ, hỗ trợ tạo/sửa/nhân bản/xóa, nhập/xuất và chạy tuần tự các bước có độ trễ. Dữ liệu đầu vào được kiểm tra giới hạn; mỗi bước gửi qua command guard và được xác minh lại trước dispatch. Có thể dừng để ngăn các bước tiếp theo nhưng không hoàn tác lệnh đã gửi. Macro chỉ chứa lệnh không bí mật: tệp JSON lưu dạng rõ và độ trễ không bảo đảm shell đã thực thi xong lệnh trước đó.
- Hiển thị lỗi kết nối/thao tác có thể đọc được, bổ sung thử lại, kiểm tra dữ liệu host/tunnel và tránh truy cập widget/provider đã hủy sau thao tác bất đồng bộ.
- Nút đo `/proc` trên mobile chỉ hoạt động ở phiên SSH đang kết nối; các trạng thái/giao thức khác có giải thích và không còn nút bấm im lặng.
- Cải thiện hộp thoại vault/settings/import và chia nhóm nội dung trong trình sửa Host; bổ sung passphrase cho SSH Private Key, khóa thao tác khi lưu, chuẩn hóa địa chỉ IPv6. Settings có nút tăng/giảm/đặt lại cỡ chữ và bản xem trước cuộn ngang.
- SFTP hiển thị dung lượng dễ đọc và quyền Unix đã bỏ bit loại tệp; trạng thái trống/lỗi có thao tác tạo thư mục hoặc thử lại. Giữ xác nhận xóa/ghi đè và đường dẫn tải xuống. Trình sửa tệp chặn lưu sau khi tải thất bại, hỗ trợ thử lại/Ctrl hoặc Cmd+S, nhận biết nội dung đã hoàn tác và xác nhận bỏ thay đổi chưa lưu.
- Sửa chmod SFTP chỉ gửi trường quyền truy cập. Không gửi lại kích thước/chủ sở hữu/thời gian từ metadata cũ, tránh lỗi đổi quyền thư mục và thay đổi dữ liệu ngoài ý muốn.
- Tunnel có tạo/sửa/xóa được xác nhận, cấu hình địa chỉ Bind và kiểm tra port; phải dừng trước khi sửa hoặc xóa. Trạng thái truyền tệp đã hủy hiển thị trung tính, giữ số byte đã truyền và không bị báo thành công.
- Tách đọc UTF-8 theo luồng, giữ thứ tự gửi, sửa lựa chọn tab khi đóng, kết thúc phiên, race khi lock/refresh và kết quả SFTP cũ ghi đè kết quả mới. Tách `terminalCwd` khỏi thư mục đang duyệt SFTP: tắt Follow giữ nguyên cửa sổ file; bật lại chuyển tới thư mục shell mới nhất.
- Sửa phân mảnh Telnet IAC, escape dữ liệu gửi, marker truyền tệp, thư mục khởi động SSH/local shell, đăng ký phiên và dọn phiên khi mở thất bại.
- Local shell kiểm tra `startupDir` tường minh trước khi cấp PTY: đường dẫn không tồn tại hoặc trỏ đến tệp thường trả lỗi “Thư mục khởi động”, thay vì để portable-pty âm thầm mở shell tại HOME. Hai regression native cho đường dẫn thiếu/tệp thường và thư mục hợp lệ có dấu cách đã qua.
- SSH chờ ACK riêng của yêu cầu PTY và shell, trả lỗi khi bị từ chối/đóng kênh/hết thời gian; giữ dữ liệu xuất hiện sớm để đưa vào terminal sau khi thiết lập thành công. Kênh exec xử lý từ chối, exit status khác 0, tín hiệu dừng, timeout và giới hạn đầu ra; không coi EOF trước exit status là thành công sớm.
- Năm API stream kết nối (SSH đã lưu, SSH nhanh, local shell, Telnet và Serial) gửi lỗi thiết lập qua `sink.add_error`. Bridge đã được tạo lại để lỗi đến Dart stream và kết thúc trạng thái đang kết nối, thay vì bị mất trên setup Future của FRB.
- Sửa vòng đời tunnel local/remote/SOCKS, hủy kết nối đang chạy, giải phóng cổng và race pause/cancel truyền tệp.
- SFTP kiểm tra pause/cancel trước khi tạo hoặc truncate đích và kiểm tra lại sau preflight bất đồng bộ. Ca đã hủy hoặc đang pause từ đầu không được làm mất nội dung đích có sẵn hay tạo tệp đích mới; hủy khi truyền đã bắt đầu vẫn có thể để lại tệp một phần.
- Import vault dùng giao dịch và giữ bí mật hiện có khi nhập bản sao đã lược bỏ secret. Tệp văn bản SFTP không hợp lệ UTF-8 trả lỗi rõ ràng.
- Hộp thoại import hiển thị các warning do backend trả về cho SSH config/CSV/PuTTY, lọc dòng rỗng và xóa warning cũ khi bắt đầu lượt nhập/xuất mới. Kết quả có host đã nhập không che khuất directive hoặc block bị bỏ qua.
- Biến môi trường SSH được gửi dưới dạng yêu cầu SSH với xác nhận và timeout; không nội suy giá trị thành lệnh shell.
- Proxy hỗ trợ SOCKS5 username/password, SOCKS4 User ID và HTTP CONNECT không xác thực/Basic/NTLMv2/Kerberos–Negotiate; HTTP CONNECT có TLS xác minh chứng chỉ/hostname và CA PEM bổ sung. Có trình quản lý tạo/sửa/chọn/xóa Proxy, chặn xóa khi còn tham chiếu và chế độ kế thừa/chỉ định/tắt trong Host. Mật khẩu dùng credential trong Vault, Proxy chỉ giữ tham chiếu; Kerberos cần KDC và SPN phù hợp.
- SSH yêu cầu xác nhận host key hoặc CA mới sau khi đối chiếu dấu vân tay qua kênh tin cậy; không tự tin cậy khóa lần đầu. Khóa thay đổi yêu cầu nhập lại dấu vân tay trước khi thay. Có UI nhập/xóa key và CA; kho `.ssh_known_hosts` riêng theo Vault và hostname/cổng chính xác. Chứng chỉ máy chủ được kiểm tra chữ ký, thời hạn và principal; lock/chuyển Vault hủy các yêu cầu xác minh đang chờ. Không sửa `known_hosts` chung của người dùng.
- Serial ở lượt QA trước có transport native desktop, liệt kê cổng, cấu hình khung truyền, nhập/xuất terminal, đóng và kết nối lại; host Serial lưu được cấu hình trong Vault. Khi đó Android/iOS USB Serial chưa triển khai; Android đã được bổ sung ở lượt hiện tại nêu trên.
- Phản hồi AI từ Ollama và dịch vụ tương thích OpenAI được kiểm tra chặt hơn; lỗi HTTP, nội dung rỗng/sai định dạng không bị báo thành công. Chèn AI chỉ đưa một dòng vào terminal và không tự nhấn Enter.
- Nhánh giảm chuyển động không còn tạo `AnimatedSize` có thời lượng 0.

### Xác minh lịch sử

| Kiểm tra | Kết quả |
| --- | --- |
| Bộ test Flutter toàn bộ | Lượt QA trước khi thêm macro: 123/123 ca qua. Lượt chạy sau tích hợp macro chưa kết thúc; tại lần ghi nhận có 4 lỗi, gồm `test/feature_ui_test.dart:1292` (test SFTP dùng `enterText` trong khi có nhiều trường khớp) và tiến trình vẫn chạy ở `sftp_power_tools_test.dart`. Không tính lượt này là pass toàn bộ. |
| Test automation macro | Sau tích hợp kiểm tra lại ngay trước dispatch: 18/18 ca qua (`test/automation_test.dart`), gồm validation, persistence, runner/cancel, guard và bố cục UI. |
| Bộ test Rust workspace | Lượt chạy lại sau sửa local shell cuối: 69 mục báo thành công, gồm 68 ca thực chất và 1 smoke AI trả về sớm vì chưa cấu hình endpoint |
| Phân tích Flutter/Dart | Lượt QA toàn dự án trước khi thêm macro: `No issues found`, hoàn tất trong 6,6 giây. Phân tích phạm vi macro/guard sau tích hợp: `No issues found` trên 6 tệp. |
| Hai regression native local shell | Đã qua: từ chối đường dẫn thiếu/tệp thường và mở đúng thư mục hợp lệ có dấu cách; đã nằm trong tổng Rust ở trên |
| `cargo check --workspace --all-targets --locked` | Đã qua trên mã của lượt QA trước; crate ứng dụng sạch, còn 16 warning cũ ở `vendor/picky` |
| QA chức năng native Linux | Lượt QA trước: 5/5 kịch bản qua, phần thực thi test khoảng 31 giây |
| Hai ca tích hợp Serial Linux | Lượt QA trước: 2/2 ca qua; gồm lỗi thiết lập của cả 5 API stream và Serial qua PTY thật |
| Build Linux release | `flutter build linux --release` qua, mã thoát 0; binary và thư viện Rust được build lại, mốc file 07:39:57 ngày 27/11/2026 |
| Khởi động bản release cuối | Chạy 8 giây với `XDG_DATA_HOME` tạm riêng, đến khi timeout chủ động dừng (mã 124); không ghi nhận lỗi khởi động ứng dụng |
| QA desktop và bố cục mobile trên Linux | Lượt trước qua, lưu 14 ảnh desktop và 10 ảnh mobile; chưa phải xác minh lại mã cuối |

Các test Flutter bao gồm nhập terminal, phím tắt, tìm kiếm/clipboard, lỗi gửi, đóng phiên khi widget đã hủy, UTF-8 theo gói, race SFTP/Follow, bố cục sáng/tối và cửa sổ thấp. Các nhóm regression còn kiểm tra snapshot command guard bị thay đổi trong khi xếp hàng, nhóm bracketed paste hỗn hợp chờ chung hàng đợi, trust key/CA, cấu hình Proxy/Serial, import warning và lỗi thao tác. Không cộng riêng các nhóm test con vào tổng 123 ca.

Bộ Rust dùng socket thật với fixture cục bộ cho SSH/Proxy/SFTP/Telnet/tunnel, kiểm tra trust tương tác key/CA và hủy xác minh khi khóa Vault, TLS proxy và các nhánh giao thức xác thực, migration/import Vault, AI HTTP và chmod chỉ gửi permissions. Các ca mới tái hiện PTY/shell bị từ chối hoặc không ACK, dữ liệu SSH xuất hiện sớm, exec lỗi/exit status/signal/timeout/giới hạn đầu ra và SFTP pause/cancel trước khi đụng vào tệp đích. Đây là fixture được kiểm soát, không phải xác nhận tương thích với proxy/KDC hoặc máy chủ bên ngoài.

`integration_test/integration_serial_test.dart` đã qua 2/2 ca với bridge native cuối. Ca lỗi xác minh cả năm API kết nối đưa lỗi thiết lập vào Dart stream, tab thất bại chuyển sang trạng thái đã đóng và có thể thử lại. Ca Serial dùng cặp Linux PTY thật để kiểm tra hộp thoại cấu hình, dữ liệu hai chiều, nhập bằng bàn phím, ngắt thiết bị giả lập, kết nối lại cùng tab và từ chối cấu hình khung truyền sai. Kết quả này không thay thế thử nghiệm USB adapter thật.

QA tích hợp dùng kết nối SSH/SFTP và TCP thật tới server thử nghiệm loopback. Cây tệp, phản hồi shell và số liệu `/proc` của server này là dữ liệu fixture được kiểm soát. Test desktop bao gồm lưu host, nhập lệnh, SFTP theo thư mục terminal, Commander, sửa/lưu/đọc lại tệp, cảnh báo PROD, chia terminal, broadcast, bảng lệnh, health, upload, tunnel TCP, export, overview và đổi ngôn ngữ/theme. Test mobile kiểm tra bố cục điện thoại cùng SSH/SFTP, snippets, health, tunnel và cảnh báo lệnh.

`integration_test/qa_functionality_test.dart` đã qua cả năm kịch bản trên mã của lượt QA trước:

1. SFTP tạo/đổi tên/xóa thư mục và file, nội dung UTF-8 đọc lại chính xác kể cả sau chmod; đổi quyền qua backend và đối chiếu quyền hiển thị, đồng thời kiểm tra tìm kiếm terminal và chụp giao diện desktop.
2. Local PTY thật nhận bàn phím, Ctrl+C ngắt `sleep`, thoát shell và kết nối lại trong cùng tab.
3. Telnet loopback thật đàm phán WILL/DO ECHO, truyền nội dung gõ, nhận phản hồi và nhận biết đóng phiên.
4. SFTP được làm chậm có kiểm soát để kiểm tra pause/resume/cancel; file tải xuống khớp từng byte và file remote đã hủy dừng tăng ở kích thước còn dở.
5. Command guard nhiều dòng giữ bản nháp khi hủy, gửi sau xác nhận và chặn gửi nếu tập phiên nhận broadcast thay đổi trong lúc chờ xác nhận.

Kho dữ liệu và cấu hình của các lượt QA native được đặt trong thư mục tạm riêng. Các ảnh có sẵn trong `../screenshots/pc` và `../screenshots/mobile` là bằng chứng của các lượt chạy trước, gồm 14 ảnh desktop, 10 ảnh mobile và ảnh chức năng bổ sung; không khẳng định chúng được tạo lại từ mã cuối. Lượt trước đã xem trực quan workspace desktop tối/sáng, hộp thoại Host, terminal/mobile home tối/sáng và thanh tìm kiếm. Bài chức năng bổ sung đổi thư mục ảnh bằng `TERMPULSE_QA_SCREENSHOT_DIR`.

Lượt functionality lịch sử tạo ảnh tại `/tmp/termpulse-completion-qa.DJZMaI/screenshots/qa_functionality_modern_desktop.png`. Đã xem trực quan bố cục terminal, SFTP và thanh tìm kiếm trong ảnh này; đây là ảnh của mã tại lượt QA trước, tách khỏi bộ ảnh PC/mobile cũ hơn nêu trên. Đường dẫn nằm trong thư mục QA tạm của máy kiểm tra.

Bản Linux release của lượt QA trước đã build thành công tại `build/linux/x64/release/bundle/`; binary và thư viện Rust có mốc file 07:39:57 ngày 27/11/2026 trên máy kiểm tra. Thư mục này có thể được các lượt build hiện tại thay thế; mốc lịch sử không xác minh nội dung bundle hiện có. Cách chạy bundle sau khi build:

```sh
./build/linux/x64/release/bundle/termpulse
```

Giữ thư mục `data` và `lib` đi cùng tệp chạy. Lượt mở thử release lịch sử dùng `XDG_DATA_HOME=/tmp/termpulse-release-qa.CWDa7w` để tách khỏi dữ liệu người dùng, chạy trong 8 giây tới khi `timeout` chủ động dừng (mã 124), không ghi nhận lỗi khởi động ứng dụng. Có cảnh báo module GTK `appmenu-gtk-module` của máy kiểm tra. Lượt đó chỉ xác minh khởi động bản release lúc ấy; các ca chức năng native nêu trên chạy ở integration/debug, không phải một lượt chạy toàn bộ ca chức năng trên release hiện tại.

## Chạy lại kiểm tra

Từ thư mục ứng dụng, với Flutter trong `PATH`:

```sh
flutter analyze --no-pub
flutter test --no-pub
cargo test --manifest-path rust/Cargo.toml --workspace --locked
cargo check --manifest-path rust/Cargo.toml --workspace --all-targets --locked
cargo test --manifest-path rust/Cargo.toml --lib remote_desktop_api --locked -- --nocapture
flutter build linux --release
```

Để chạy QA tích hợp, mở server fixture ở một terminal:

```sh
cargo run --manifest-path rust/Cargo.toml -p core-transport --example qa_ssh_server --locked
```

Fixture mặc định chờ 20ms cho mỗi lần ghi SFTP. Bài kiểm tra pause/resume/cancel yêu cầu ít nhất 10ms; có thể đặt `TERMPULSE_QA_SFTP_WRITE_DELAY_MS` khi mở server nếu cần. Fixture in `QA_SSH_SERVER_FINGERPRINT=SHA256:…` khi khởi động; lấy đúng giá trị đó gán cho `QA_SSH_FINGERPRINT` trong terminal chạy test. Mỗi lần khởi động fixture sinh khóa mới.

Sau đó từ thư mục ứng dụng, chạy các bài tuần tự, sử dụng `XDG_DATA_HOME` trỏ vào một thư mục tạm dành riêng cho QA:

```sh
flutter test --no-pub integration_test/qa_pc_test.dart -d linux --reporter expanded \
  --dart-define=QA_SSH_FINGERPRINT="$QA_SSH_FINGERPRINT"
flutter test --no-pub integration_test/qa_mobile_test.dart -d linux --reporter expanded \
  --dart-define=QA_SSH_FINGERPRINT="$QA_SSH_FINGERPRINT"
flutter test --no-pub integration_test/qa_functionality_test.dart -d linux --reporter expanded \
  --dart-define=QA_SSH_FINGERPRINT="$QA_SSH_FINGERPRINT"
flutter test --no-pub integration_test/integration_serial_test.dart -d linux --reporter expanded
```

Các bài QA PC/mobile hiện sử dụng đường dẫn ảnh mặc định của workspace này; cần kiểm tra đường dẫn khi chạy ở máy khác. Bài functionality hỗ trợ biến môi trường thư mục ảnh nêu trên. Serial test cần `socat` và không cần fixture SSH. Không chạy build Linux release và test Linux native đồng thời vì chúng dùng chung thư mục Flutter ephemeral.

Fixture remote desktop ở lệnh `remote_desktop_api` tự mở TCP loopback và server TLS/RFB tạm; không cần máy Windows/VNC hoặc chứng thư thật. Các bản vá vendor liên quan được mô tả tại `rust/vendor/ironrdp-connector/TERMPULSE-PATCH.md`, `rust/vendor/ironrdp-acceptor/TERMPULSE-PATCH.md` và `rust/vendor/vnc-rs/TERMPULSE-PATCH.md`.

## Giới hạn và việc cần làm tiếp

- Xác nhận host key/CA cần người dùng đối chiếu fingerprint qua kênh độc lập tin cậy. UI xác nhận không tự chứng minh danh tính server; không tắt xác minh SSH/TLS để bỏ qua lỗi.
- Proxy TLS/NTLM/Kerberos đã có triển khai và kiểm thử fixture; chưa xác minh với KDC/Active Directory hoặc proxy doanh nghiệp bên ngoài. SOCKS4 chỉ có USERID, không có mật khẩu.
- Serial desktop và Android USB Serial đã có triển khai nhưng chưa thử bộ chuyển đổi USB thật hoặc đầy đủ driver/flow control phần cứng. Android cần thiết bị có USB Host/OTG, quyền USB và driver phù hợp; iOS USB Serial chưa hỗ trợ.
- RDP/VNC đã có UI/backend nhúng nhưng mới kiểm thử server loopback có kiểm soát. Chưa xác minh máy Windows/Active Directory/VNC bên ngoài, remote desktop trên thiết bị mobile thật, RD Gateway, smartcard hoặc mọi biến thể encoding/server. Giới hạn direct-only và clipboard RDP được nêu ở lượt hiện tại.
- AI mới được kiểm thử giao thức HTTP với fixture cục bộ; chưa gọi endpoint/model bên ngoài trong lượt này. Smoke AI tùy chọn trả về sớm khi không có `TERMPULSE_AI_QA_ENDPOINT`, nên trạng thái pass không có nghĩa đã kiểm tra model thật.
- Không có thiết bị Android/iOS được kết nối trong lượt này. QA mobile là bố cục mobile chạy bằng Flutter Linux, không chứng minh vòng đời nền, IME, file picker hay quyền trên thiết bị di động thật.
- Chưa thực thi ứng dụng native trên Windows/macOS/iOS trong lượt này. Có workflow build đa nền tảng không đồng nghĩa các lượt CI đó đã chạy và thành công. Wake-on-LAN còn phụ thuộc mạng và thiết bị đích.
- Vault mã hóa trường secret bằng ChaCha20-Poly1305 với khóa dẫn xuất Argon2; metadata SQLite như hostname/nhãn/ghi chú vẫn ở dạng rõ. JSON xuất kèm secrets cũng chứa bí mật dạng rõ. Android release hiện dùng debug signing, cần khóa phát hành trước khi phân phối.
- Mosh, Eternal Terminal và host SFTP độc lập chưa có luồng kết nối. Local shell Android đã có triển khai và qua NDK check nhưng chưa chạy trên thiết bị thật; iOS local shell và Flutter Web chưa hỗ trợ.

Các kết quả trên xác nhận những đường chạy đã nêu, không phải cam kết mọi cấu hình máy chủ, giao thức hay nền tảng đều đã được kiểm thử.
