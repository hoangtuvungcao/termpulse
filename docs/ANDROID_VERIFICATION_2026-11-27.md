# Kiểm chứng Android — 2026-11-27

Phạm vi: sửa lỗi khóa tệp SSH trên Android, quản lý Host, kết nối nhanh SSH/Telnet, thông báo dễ hiểu, bố cục mobile/PC, bảng công cụ kéo/cuộn và kiểm tra RDP trên điện thoại thật; đồng thời giữ nội dung chính sách/quyền đã bổ sung để chuẩn bị phát hành. Đây là ghi nhận kiểm thử phát triển, không phải xác nhận Google Play đã phê duyệt hoặc mọi cấu hình Android đều được hỗ trợ.

## Mốc mới — touchpad RDP, thu phóng và hiệu năng

Touchscreen RDP/VNC mặc định hoạt động như touchpad: chạm rồi nhấc một ngón gửi đúng một lần nhấn/nhả chuột trái tại con trỏ; chạm đồng thời hai ngón gửi chuột phải, không phát chuột trái trước đó; vuốt một ngón di chuyển con trỏ tương đối, không bấm tại vị trí ngón tay. Giữ một ngón 500 ms rồi vuốt để kéo bằng chuột trái; nhấc/hủy luôn nhả nút. Pinch hai ngón thu phóng mà không gửi click. Chuột vật lý vẫn định vị tuyệt đối theo ảnh đã biến đổi. Có con trỏ tương phản, kích thước hiển thị cố định và vùng nhìn tự đi theo con trỏ khi tới mép.

Điện thoại mở desktop ở 100% để đọc được, kể cả khi bắt đầu ở hướng ngang. Thanh công cụ có vừa màn hình, giảm/tăng tỷ lệ, phần trăm thực, toàn màn hình và menu 100%. Đã sửa lỗi lấy tỷ lệ cả trục Z khiến mức dưới 100% bị đọc thành 100%, làm nút phóng to nhảy lên 130% và sai độ dịch chuột. Bốn matrix dùng scale XYZ đồng nhất để chế độ pan của InteractiveViewer cũng xử lý đúng. RDP/VNC không còn giữ bảng Files/Snippets/Health của terminal. Toàn màn hình ẩn thanh shell, giữ cùng State/controller/phiên; Android Back thoát toàn màn hình trước.

Giảm công việc thừa ở cả Dart và Rust: chỉ gộp các vị trí chuột liên tiếp chưa gửi, giữ nguyên thứ tự nhấn/nhả/cuộn/phím/văn bản; bỏ bản sao RGBA dư; chỉ cập nhật ảnh thay vì dựng lại cả pane mỗi frame; bỏ nhịp render quá hạn để không chạy bù dồn. Rust vẫn giới hạn phát framebuffer đầy đủ ở 20 Hz, không tuyên bố nâng FPS tối đa. Logger starter của FRB đã được xác nhận bật TRACE cả release; thay bằng WARN/ERROR, giữ backtrace. Không phát framebuffer đen chưa nhận graphics từ máy chủ. Reconnect/đóng stream xóa input đang chờ và hủy timer giữ chuột của phiên cũ.

| Kiểm tra tại mốc touchpad cuối | Kết quả và phạm vi |
| --- | --- |
| Flutter toàn bộ suite sau thay đổi cuối | **383/383 PASS**, khoảng **83 giây**. Log: `build/qa_host_actions/rdp-final-flutter-tests.log`. |
| Phân tích tĩnh toàn project | **No issues found**, **29,5 giây**. Log: `build/qa_host_actions/rdp-final-flutter-analyze.log`. |
| Rust RDP/VNC | **20/20 PASS**, **1,74 giây**, `--offline --locked`; gồm input burst giữ đúng click/phím, animation liên tục và giữ graphics đầu để xác nhận không phát frame đen. Log: `build/qa_host_actions/rdp-initial-graphics-tests.log`. |
| Native Android, Rust/RDP thật tới fixture kiểm soát | **1/1 scenario PASS**, khoảng **16 giây**. Nhận **61 frame trong cửa sổ 3 giây** sau khi marker ảnh thật đã xuất hiện; từ chạm trái đến frame phản hồi đã được máy chủ xác nhận là **185 ms**. |
| Thao tác native trong scenario trên | Một ngón trái, hai ngón phải và không thừa click trái, vuốt đổi tọa độ không click, pinch không click, nút +/- từ tỷ lệ fit tăng/giảm đúng 1,3, nhãn tỷ lệ khớp matrix, toàn màn hình tăng viewport, dọc → ngang → dọc giữ cùng session ID; cleanup thành công. |
| APK app thường cuối | Target **`lib/main.dart`**, `--profile --target-platform android-arm64`: **PASS**, **42,4 giây**; `apksigner verify` và `zipalign -c -P 16 4`: **PASS**. |
| Cài đè và mở app thường | `adb install -r --no-incremental`: **Success**; hash APK cài trên máy khớp artifact. Cold launch **Status: ok**, **TotalTime 2539 ms / WaitTime 2584 ms**. Đã xem màn mở khóa Vault bình thường; không chạy lại diagnostic. |

Native diagnostic nằm tại `integration_test/android_remote_desktop_touchpad_test.dart`; máy chủ là `rust/examples/qa_rdp_server.rs`, chỉ lắng nghe loopback và dùng desktop/tài khoản giả. TLS pin được lấy độc lập từ fixture rồi đối chiếu qua probe trước kết nối. Test dùng Vault tạm riêng và kiểm tra số nút chuột tại máy chủ; phản hồi hình được xác nhận bằng marker pixel theo input sequence, không chỉ dựa vào lời gọi input thành công. Log cuối: `build/qa_host_actions/rdp-touchpad-scale-final-native.log`, marker `TERMPULSE_RDP_TOUCHPAD_PASSED` và `All tests passed!`. Số `+2` của runner bao gồm teardown, không tính thành hai scenario.

Lượt debug đầu thất bại ở điều kiện cập nhật liên tục (**1 frame/3 giây**); log được giữ tại `build/qa_host_actions/rdp-touchpad-native.log`. Điều tra thấy decode RemoteFX debug chưa tối ưu, TRACE từng tile và readiness có thể nhận frame đen ban đầu. Không hạ ngưỡng ≥15 frame/3 giây để vượt test: đã sửa logger/frame đầu, chờ marker ảnh thật và chạy lại bằng profile/AOT tương ứng app thường. Các lần profile trước sửa tỷ lệ đạt 51 rồi 61 frame; số **61 frame / 185 ms** trong bảng thuộc lượt cuối sau sửa tỷ lệ, không cộng các lần thử thành nhiều bài độc lập.

Đã kéo và xem ảnh native cuối tại `build/qa_host_actions/rdp-touchpad-final-device/`: portrait 100%, portrait fit **31%**, toàn màn hình dọc, toàn màn hình ngang fit **37%** và tăng lên **48%**. Thanh công cụ, hướng dẫn touchpad và con trỏ nằm trong vùng nhìn. Ảnh đều là desktop giả; không chụp hoặc thao tác desktop VPS thật trong lượt này. Những con số frame/độ trễ qua ADB loopback không chứng minh tốc độ mạng, codec hoặc độ trễ của VPS thực; mốc VPS cũ bên dưới chỉ xác nhận đăng nhập và ảnh đầu tiên.

Artifact cuối: `build/app/outputs/flutter-apk/app-profile.apk`, **67.905.638 byte**, SHA-256 **`dd096743ed068d1132bc0656bc3dc86c3633bc0fac3821d719703053511011e6`**. Signer SHA-256 **`775bd25b7bf4e8de69c1de66b581105ce746b0837c43ed7a575956c26e2efd8d`**, khớp bản đã cài. Đây là profile ký debug để thử trên thiết bị, không phải release/AAB nộp Play. Cảnh báo NDK của integration_test vẫn còn; zipalign không thay thế kiểm thử runtime 16 KB.

Đối chiếu SHA-256 bốn tệp Vault/sidecar/WAL/prefs sau QA và sau cài đè, trước mở app thường: **không đổi**. Không mở khóa/reset Vault thật. Đã đóng fixture, xóa Vault và ảnh thử riêng trên điện thoại sau khi giữ ảnh trên host; không còn thư mục `qa_rdp_touchpad*`, không còn hai ADB reverse thử nghiệm. Cài đặt giữ màn hình sáng khi cắm sạc đã trả về **0**. App thường cuối được để tại màn mở khóa Vault đã có, ngôn ngữ/theme của người dùng được giữ nguyên.

## Mốc trước — thao tác mobile/PC, kết nối nhanh và thông báo

Ô kết nối nhanh dùng chung trên hai giao diện, hỗ trợ `ssh user@host`, `ssh -p 2222 user@host`, `user@host:port`, địa chỉ IPv6 và `telnet host [port]`. Đầu vào được phân tích theo cú pháp giới hạn, không chuyển cho shell; lệnh từ xa, tuỳ chọn không hỗ trợ và mật khẩu trong địa chỉ bị từ chối bằng hướng dẫn nhập. SSH hỏi mật khẩu ở ô riêng; Telnet đi vào transport Telnet thật và giải thích kết nối không mã hóa. RDP/VNC dùng biểu mẫu Host với cấu hình tương ứng.

Thông báo lỗi của ứng dụng hiển thị lời giải thích trước, giới hạn chiều rộng và căn giữa. Mã lỗi, exception và chẩn đoán native nằm trong nút **Xem chi tiết**, mở hộp thoại giữa màn hình có thể cuộn/chọn văn bản. Lỗi từ chối xác thực khác với lỗi mạng/quá hạn; quá hạn xác thực không khẳng định sai mật khẩu. Luồng này áp dụng cho terminal, desktop từ xa, lưu Host, Serial, proxy, nhóm kết nối, tunnel và command palette. Nội dung terminal thực sự do máy chủ gửi vẫn giữ nguyên. RDP chặn lưu mật khẩu khi thiếu tên đăng nhập; VNC vẫn hỗ trợ chỉ dùng mật khẩu.

Bảng **Files · Snippets · Health** trên mobile có tay kéo, thu gọn/mở lại và phóng to/khôi phục. Bảng cuộn được khi thiếu chiều cao, đổi hướng màn hình hoặc mở bàn phím; giữ bản nháp, tab và phiên terminal. Đổi tab chỉ đặt lại scroll sau frame để tránh lỗi `AppBar setState during build`. Regression tại kích thước ngang thực tế **872,7 × 392,7** đã được đối chứng: tạm khôi phục đoạn `jumpTo` cũ làm test thất bại đúng lỗi này; khôi phục bản sửa thì test qua. Native harness kéo từ vùng thật sự nhìn thấy thay vì tâm ListView nằm ngoài phần bị clip, và vẫn buộc phần tử cuối hiển thị trọn trong bảng.

Màn danh sách Host mobile cuộn/lazy; nút và session chip có vùng chạm lớn hơn. Thông báo lỗi, tìm kiếm và kết nối lại vẫn truy cập được khi màn hình thấp và bàn phím mở. Trên PC, kéo sidebar/SFTP không dùng animation trung gian và giữ vùng terminal tối thiểu; đổi focus split giữ nguyên State/controller/scroll. Thanh tìm kiếm trong pane **180 px**, chữ **1,6×**, chuyển bố cục và cho cuộn dãy nút, giữ nguyên ô nhập và terminal. Hộp nhập văn bản RDP/VNC căn giữa, cuộn được khi thiếu chỗ.

| Kiểm tra bổ sung của lượt UX | Kết quả và phạm vi |
| --- | --- |
| Flutter toàn bộ suite sau các bản sửa UX | **364/364 PASS**, **52 giây**, với `CAPTURE_UI=true`; thay thế tổng 314 của mốc Host trước. Log: `build/qa_host_actions/ux-final-flutter-tests.log`. |
| Phân tích tĩnh toàn project | `flutter analyze --no-pub`: **No issues found**, **11 giây**. Log: `build/qa_host_actions/ux-final-flutter-analyze.log`. |
| Chụp kiểm tra bố cục với font thật | Sau thay đổi riêng helper capture: **17/17 PASS**, **9 giây**, phân tích file test sạch (**2,6 giây**). Load Roboto/MaterialIcons/monospace chỉ khi `CAPTURE_UI=true`; không thay font hoặc widget production. |
| Thông báo, Host/RDP/VNC, Serial, library, proxy và command palette | **47/47 PASS** trên 5 suite, gồm shared error-notice; giữ retry, chẩn đoán chỉ xuất hiện khi mở Chi tiết. |
| Bảng công cụ mobile | **6/6 widget tests PASS**, gồm xoay lặp lại theo kích thước thực tế, phần tử cuối, chữ lớn, bản nháp và trạng thái terminal. Phân tích 3 file sạch. |
| Quick SSH và bảng công cụ trên Redmi thật | **1/1 scenario PASS**, khoảng **41 giây**, gồm SSH qua transport native tới fixture kiểm soát, kéo/thu gọn/phóng to/khôi phục, cuộn tới phần tử cuối và xoay dọc → ngang → dọc. Số `+3` trong log gồm setup/teardown. |
| Terminal gọn và desktop từ xa | **19/19 PASS** trên 2 suite sau thay đổi cuối; tìm hai kết quả, Previous/Next/Close và reconnect đều truy cập được. Phân tích 4 file sạch. |
| Rust Telnet/SSH `core-transport` | **54/54 PASS**, gồm timeout Telnet/DNS-TCP 15 giây và real-loopback Telnet, cùng các regression xác thực SSH. |
| Rust RDP/VNC và bộ đọc địa chỉ SSH | **13/13 + 3/3 PASS**; fixture có TLS/pin/NLA, sai mật khẩu, frame/input, đóng phiên/deadline và phân tích/quoting SSH. |
| RDP thật trên Redmi tới VPS người dùng cung cấp | **1/1 PASS**: đúng một lần thử xác thực, chứng thư khớp pin đã xác minh độc lập, native connected, frame **1280 × 720** có RGB khác đen và `RawImage` được render; diagnostic hoàn tất sau **9.589 ms**, cleanup thành công. Không gửi phím/con trỏ và không chụp desktop thật. |
| APK app thường, chế độ profile/AOT | Build target **`lib/main.dart`**, Android arm64: **PASS**, **189,9 giây**; `apksigner verify` và `zipalign -c -P 16 4`: **PASS**. Chữ ký debug khớp bản đã cài, không phải bản release/AAB để nộp Play. |
| Cài đè và mở app thường | `adb install -r --no-incremental`: **Success**; SHA-256 của APK kéo từ thiết bị khớp artifact cuối. Cold launch **Status: ok**, `TotalTime: 2118 ms`, `WaitTime: 2161 ms`; PID **24726** tiếp tục chạy, log đã kiểm tra không có `AndroidRuntime`/`E/flutter` hay marker chạy lại diagnostic. |

Các nhóm Flutter riêng ở trên có thể nằm trong tổng suite toàn bộ; không cộng chúng lần nữa thành tổng kiểm thử. `integration_test/android_remote_desktop_test.dart` nhận cấu hình trong private app-data lúc chạy, xóa ngay sau đọc, dùng Vault tạm tách biệt và xóa khi kết thúc. Pin RDP được đối chiếu qua SSH có host key đã tin cậy trước khi gửi mật khẩu; không tắt xác minh chứng thư. Log kết quả: `build/qa_host_actions/rdp-ux-native.log`, marker `TERMPULSE_REMOTE_DESKTOP_COMPLETED` có `connected=true rendered=true pixels=true probe=verified_pin_match attempts=1 cleanup=true`.

`integration_test/mobile_tools_panel_test.dart` nhập cú pháp Quick Connect thật, xác nhận host key fixture đã biết và quan sát SSH `session_opened` cùng phản hồi chào; phiên thử bảng công cụ dùng Host riêng. Các thao tác tunnel/input ngoài luồng SSH thử bị chặn và được kiểm tra bằng số lần gọi bằng 0. Log cuối: `build/qa_host_actions/mobile-tools-final-native.log`, có `TERMPULSE_MOBILE_TOOLS_QUICK_CONNECTED=true` và `TERMPULSE_MOBILE_TOOLS_PASSED`, không có lỗi framework hoặc cảnh báo kéo ngoài vùng nhìn thấy. Ảnh dữ liệu tổng hợp đã kéo về và kiểm tra ở `build/qa_host_actions/mobile-tools-device/`, gồm dọc khi kéo/thu gọn/cuộn hết và ngang theme sáng. Log đối chứng lỗi cũ: `build/qa_host_actions/mobile-tools-negative-control.log`.

Ảnh host cuối đã thay bản dùng font Ahem bằng font đọc được: `../screenshots/review/{dark,light}_{1280,412}_terminal.png`. Đã xem cả bốn ảnh: chữ, nút, icon Material và bố cục sáng/tối đọc được; emoji mắt xích trước nhãn SFTP Follow còn thiếu glyph trên host. Helper chỉ bổ sung font mặc định cho span render khi chụp. Đây là render widget với dữ liệu tổng hợp, không phải screenshot của binary PC hoặc phép đo hiệu năng native. Log: `build/qa_host_actions/ui-real-font-regression.log` và `build/qa_host_actions/ui-real-font-analyze.log`; nhóm 17 test này đã thuộc tổng suite, không cộng lần nữa.

Artifact cuối của lượt UX: `build/app/outputs/flutter-apk/app-profile.apk`, **49.402.892 byte**, SHA-256 **`023afdf19c2fe2e58044091a64a961d59c31c4f8aaa97d7e9c60707cce056c1b`**. APK kéo từ thiết bị để đối chiếu là `build/qa_host_actions/normal-profile-installed.apk`. Log build: `build/qa_host_actions/ux-profile-build.log`; log cold launch: `build/qa_host_actions/normal-profile-cold-launch.log`. Cảnh báo NDK của plugin integration_test vẫn có nhưng không làm build thất bại. Chế độ profile dùng mã AOT để phát triển/đo đạc; chưa thực hiện phép đo FPS hoặc benchmark so sánh.

Đã đối chiếu cả **4 SHA-256 Vault/prefs gốc không đổi** sau QA và sau cài đè profile, trước khi mở app thường. Không nhập mật khẩu hoặc mở khóa Vault thật. Phiên fixture đã đóng; SSH fixture trên host đã dừng, thư mục tổng hợp chuyển vào thùng rác để có thể khôi phục; ADB reverse 22220 đã gỡ. Cấu hình đăng nhập và thư mục QA riêng trên điện thoại đã dọn sau khi kéo ảnh về host; không còn thư mục `qa_*` trong `files`. Cài đặt giữ màn hình sáng khi sạc được trả về giá trị ban đầu **0**. App thường đã thay APK diagnostic trên điện thoại.

Giới hạn của lượt này: chưa có adapter USB Serial thật để thử; chưa đăng nhập VNC native trên Android vào máy chủ thật. Fixture Rust/Flutter không thay thế hai kiểm tra thiết bị đó. File, tunnel và metrics trong native panel harness là dữ liệu tổng hợp, không chứng minh truyền file hoặc mở tunnel thật. Input của harness đi qua Flutter test text input, chưa thay thế thao tác IME thủ công. Không suy ra số FPS, phần trăm tăng tốc, tương thích runtime 16 KB/Android 16 hay điều kiện phát hành Google Play từ các kiểm tra này.

## Mốc trước — quản lý Host mobile và kiểm tra lại SSH

Mỗi Host đã lưu trên mobile có nút **Sửa** và **Xóa** rõ ràng, vùng chạm 48 px. Sửa mở biểu mẫu điền sẵn; đổi tên hoặc tên đăng nhập không làm mất ID hay mật khẩu đã lưu. Mật khẩu cũng có thể sửa rồi dùng để kết nối lại. Xóa có hộp xác nhận nêu tên Host, có thể hủy và chỉ xóa Host đã chọn. Các thao tác đang chạy được chặn lặp; lỗi xóa hiện ngay tại danh sách. Sau khi backend xác nhận xóa, thẻ Host vẫn biến mất ngay cả khi tải lại danh sách thất bại.

Lỗi SSH phân biệt kết nối TCP/proxy, handshake, từ chối xác thực, quá hạn xác thực, kết nối xác thực bị gián đoạn và lỗi đọc khóa. Khi máy chủ từ chối, UI hướng dẫn kiểm tra tên đăng nhập, mật khẩu hoặc khóa SSH; khi máy chủ chưa phản hồi trước thời hạn, UI nói rõ chưa thể kết luận sai mật khẩu. Không quy mọi lỗi kết nối thành sai mật khẩu. Nội dung được bổ sung cho cả 5 ngôn ngữ.

| Kiểm tra tại mốc này | Kết quả và phạm vi |
| --- | --- |
| Flutter toàn bộ suite | **314/314 PASS**, khoảng **2 phút 8 giây**; thay thế tổng 297 của mốc popup. |
| Phân tích tĩnh | `flutter analyze --no-pub`: **No issues**, khoảng **20,3 giây**. Target chẩn đoán đăng nhập thật cũng qua phân tích riêng. |
| Rust `core-transport` | **53/53 unit tests PASS**, gồm từ chối xác thực, xác thực bị treo, ngắt kết nối và đối chứng đúng mật khẩu. Không cộng conditional AI smoke harness thành một phép thử AI bên ngoài đã chạy. |
| Quản lý Host và sửa mật khẩu trên Redmi | **1/1 scenario PASS**, khoảng **2 phút 18 giây**, với Vault/Rust và SSH fixture thật. Số `+3` gồm setup/teardown. Sai mật khẩu được máy chủ fixture từ chối sau **837 ms**; sửa mật khẩu đã lưu rồi kết nối lại thành công. |
| Đăng nhập máy chủ do người dùng cung cấp từ Redmi | **1/1 diagnostic PASS**; kết nối thành công bằng **ứng viên thứ nhất sau 2.718 ms**, dừng ngay, không thử ứng viên thứ hai. Không gửi lệnh terminal lên máy chủ. |
| APK app bình thường sau mọi lượt QA | Build lại với target `lib/main.dart`: **PASS**, khoảng **19,3 giây**; `zipalign -c -P 16 4`: **PASS**. Đây là APK debug, không phải AAB release. |
| Cài lại bản bình thường | `adb install -r --no-incremental`: **Success**; SHA-256 của APK đã cài khớp artifact cuối. Mở Activity sau force-stop trả `Status: ok`, `WaitTime: 3052 ms`; PID 13039 không có lỗi `AndroidRuntime`/`E/flutter` trong log đã kiểm tra. |

Artifact của mốc Host trước: `build/app/outputs/flutter-apk/app-debug.apk`, SHA-256 **`fa0a80171638222b9524bce6f6ac42ffafab24a258b2b99a61348ad839979c3a`**. Đây là hash lịch sử, không định danh artifact mới hơn. Cảnh báo plugin integration_test đề nghị NDK 28.2 trong khi project dùng NDK 27 vẫn còn; build không thất bại. Không suy ra tương thích runtime 16 KB từ kiểm tra zipalign.

`integration_test/mobile_host_actions_test.dart` dùng Vault native tạm riêng: tạo Host, sửa tên/tên đăng nhập, xác minh lỗi từ chối xác thực hiển thị, sửa mật khẩu rồi kết nối, hủy xóa và xác nhận xóa; Host đối chứng còn nguyên. Test Flutter còn bảo vệ trường hợp refresh lỗi sau khi xóa thành công. Ảnh native sáng/tối, biểu mẫu sửa, xác nhận xóa và lỗi SSH nằm trong `build/qa_host_actions/device/`; đã xem để kiểm tra khả năng đọc và nút thao tác. Log: `build/qa_host_actions/native-test.log`.

`integration_test/android_remote_login_test.dart` nhận thông tin xác thực qua tệp private runtime, không đưa vào source hoặc APK. Tệp cấu hình bị xóa ngay sau khi đọc; Vault thử tách biệt. Khóa ED25519 được đối chiếu với khóa đã tin cậy trên máy tính rồi xác nhận qua UI kiểm tra host key thật; không chấp thuận khóa thay đổi hoặc fingerprint không khớp. Quan sát `session_opened` của luồng SSH native xác nhận đăng nhập thành công. Không chụp màn shell thành công để tránh lưu dữ liệu tài khoản. Log chỉ ghi thứ tự ứng viên, mã kết quả và thời gian: `build/qa_host_actions/remote-test.log`; báo cáo không ghi địa chỉ máy chủ hoặc mật khẩu.

Đã đối chiếu SHA-256 của cả 4 tệp Vault/prefs gốc sau QA và sau cài đè, trước khi mở app bình thường: **không đổi**. Không mở khóa, reset hay tạo lại Vault thật. Các phiên thử đã đóng, cấu hình đăng nhập/Vault/thư mục ảnh tạm trên thiết bị đã xóa; SSH fixture trên host đã dừng, thư mục fixture đã dọn và ADB reverse 22220 không còn. Cài đặt giữ màn hình sáng khi cắm sạc đã trả về giá trị ban đầu **0**.

Lần mở bản bình thường cuối trả trạng thái thành công nhưng thiết bị đang ở màn khóa, nên không ghi nhận ảnh màn app bình thường sau lần cài này; ảnh UI nêu trên thuộc lượt QA native đã hoàn thành. Không nhập hoặc bỏ qua mã khóa thiết bị. Các giới hạn về IME, cấp quyền notification thật, Android 16, runtime 16 KB và phát hành Google Play ở cuối báo cáo vẫn áp dụng.

## Mốc popup Vault trước quản lý Host/SSH

Đã thêm popup **Vault đã sẵn sàng** ngay sau khi tạo Vault mới thành công. Popup có các nút bắt đầu sử dụng, mở màn quyền/thông báo (Android) và xem chính sách quyền riêng tư. Mở khóa Vault đã tồn tại không hiện lại popup. Đây là khởi tạo kho cục bộ, không phải đăng ký tài khoản trực tuyến.

Giao diện popup chào mừng và hộp giải thích quyền thông báo dùng màu sáng/tối hiện có, nội dung cuộn được và có nút thao tác rõ ràng. Không tự gọi xin quyền Android sau khi tạo Vault; lời giải thích vẫn cho phép chọn **Để sau**. Bản chào mừng nói rõ bí mật kết nối được mã hóa, còn thông tin máy chủ/lịch sử lệnh không được mã hóa.

| Kiểm tra cập nhật giao diện | Kết quả |
| --- | --- |
| Flutter toàn bộ suite | **297/297 PASS**, khoảng 30 giây. Thay thế tổng 274 ở mốc SSH bên dưới. |
| Test chào mừng / chính sách-quyền | **19 / 17 PASS**, đã nằm trong tổng 297; gồm không hiện lại khi mở khóa, lỗi tạo Vault, điều hướng chính sách/quyền, không tự xin quyền, 5 ngôn ngữ và 2 theme. |
| Màn nhỏ / chữ lớn | Welcome: 360×640, text scale 1.6, cả 5 ngôn ngữ × 2 theme; rationale: cùng kích thước/text scale, VI/EN × 2 theme. |
| Phân tích tĩnh | `flutter analyze --no-pub`: **No issues** sau sửa cuối của script QA. |
| APK app bình thường cuối | `flutter build apk --debug --target-platform android-arm64 --no-pub`: **PASS**, khoảng 18,2 giây; target mặc định `lib/main.dart`, build lại sau lượt QA native. |
| Alignment APK mới | `zipalign -c -P 16 4`: **PASS**. Không bổ sung kết luận runtime 16 KB. |
| Retest popup trên Redmi | **1/1 PASS**, khoảng **17 giây**, với Rust/Vault tạm thật. Số `+3` trong log gồm setup/teardown, không tính thành 3 bài test. |
| Cài lại / mở app bình thường sau QA | **PASS** — `adb install -r --no-incremental` thành công; cold launch **4,649 giây**, `Status: ok`. SHA-256 của APK đã cài khớp artifact cuối. |
| Thao tác bản bình thường | **PASS** — chạm ADB mở màn quyền, mở popup giải thích rồi chọn **Để sau**; popup đóng, quyền Android vẫn `granted=false`. |

APK của mốc popup nằm ở `build/app/outputs/flutter-apk/app-debug.apk`, SHA-256 **`e735dca188de580b4afb562cb037ae828a774cae9c7fc3cd4e2a55c1cafaeff9`** tại thời điểm đó; đã được thay thế bằng artifact ở mốc mới phía trên. Artifact này từng thay thế `30eb7f04…` của lượt build trước khi điện thoại kết nối lại. Đây vẫn là APK debug, không phải AAB phát hành. Cảnh báo NDK của plugin integration_test ở mốc trước vẫn còn, không làm build thất bại.

Đã tạo và xem ảnh host bằng dữ liệu giả trong `build/qa_onboarding/`: welcome/rationale ở theme sáng và tối, cùng rationale chữ lớn trên màn nhỏ. Capture tùy chọn dùng SDK Roboto/MaterialIcons để thay fallback Ahem của Flutter test; không sửa font production. Đây là ảnh render kiểm tra trên host, **không phải ảnh chụp bản mới trên Redmi**.

Sau khi người dùng kết nối lại USB, đã chạy `integration_test/vault_onboarding_test.dart` trên Redmi bằng cách build target QA, cài đè `-r` và mở Activity trực tiếp. Không dùng integration driver gỡ ứng dụng. Test dùng Rust thật với thư mục Vault tạm riêng, kiểm tra popup mới ở cả sáng/tối, chính sách → quay lại cùng popup, mở màn quyền → giải thích → hủy, đối chiếu 6 trường trạng thái quyền native không đổi, rồi khóa/mở lại Vault tạm không hiện welcome. Log ghi `TERMPULSE_VAULT_WELCOME_PASS` và `All tests passed!` sau cleanup.

Đã kéo và xem ảnh native trong `build/qa_onboarding/device/`: `welcome-dark.png`, `welcome-light.png`, `permission-rationale.png`. Các ảnh này được render trên Redmi ở kích thước thật 1080×2400, khác các ảnh host nói trên. Đã chụp thêm `normal-vault.png` và `normal-permission-rationale.png` sau khi cài lại target `lib/main.dart`; chữ/nút đọc được, không bị cắt. App bình thường khôi phục Vault đã có và theme sáng của người dùng; không tạo/reset Vault thật để ép welcome xuất hiện.

Đã đối chiếu SHA-256 của 4 tệp Vault/prefs gốc trước test và sau test/cài đè, trước khi mở lại app bình thường: **không đổi**. Theme của fixture chỉ thay trong bộ nhớ. Thư mục Vault tạm đã được xóa, ảnh QA riêng trên thiết bị được dọn sau khi kéo về host. App bình thường cuối được để ở màn **Quyền và thông báo**, PID tại lúc xác nhận là 32670, không có lỗi `AndroidRuntime` của tiến trình này. Quyền thông báo vẫn chưa cấp; lượt này không thử nút xác nhận của hộp thoại quyền hệ thống hoặc IME thật. Các script PC/mobile/Android SSH đã được cập nhật để đóng popup mới nhưng không chạy lại trong lượt kiểm tra welcome này; kết quả SSH bên dưới vẫn thuộc mốc cũ.

## Mốc kiểm chứng SSH trước cập nhật popup

| Hạng mục | Kết quả và phạm vi |
| --- | --- |
| Rust `core-transport` | **50/50 PASS**, do nhánh sửa SSH kiểm tra; gồm regression về khóa tệp. Không cộng kết quả này vào tổng Flutter. |
| Integration trên điện thoại thật | **1/1 PASS**, khoảng **23 giây**, cho test Android với SSH fixture được kiểm soát. Chi tiết bên dưới. |
| Flutter toàn bộ suite sau thay đổi cuối | **274/274 PASS**, bao gồm 3 test pause mới. Thay thế kết quả 271 test tại mốc trước. |
| `ForegroundBridge` sau thay đổi cuối | **20/20 PASS** trong toàn bộ suite cuối; không cộng thêm lần nữa vào tổng 274 test. |
| Phân tích tĩnh cuối | `flutter analyze --no-pub`: **No issues**. |
| Build APK app bình thường cuối | `flutter build apk --debug --target-platform android-arm64 --no-pub`: **PASS**, khoảng **16,8 giây**. Đây là APK debug app bình thường, không phải AAB release. |
| Merged manifest APK bình thường cuối | Đã kiểm tra: **target SDK 36**, **min SDK 24**, `allowBackup=false`, service loại **dataSync**. |
| Cài lại/mở app bình thường sau integration | **PASS** — `adb install -r --no-incremental` thành công; cold launch `Status: ok`, khoảng **5,5 giây**; màn khởi tạo Vault hiển thị hai đường dẫn chính sách/quyền. |
| Alignment tĩnh của APK debug cuối | **PASS** — `zipalign -c -P 16 4` exit 0; mọi segment `PT_LOAD` ELF64 có alignment tối thiểu 16 KB và offset/địa chỉ tương thích 16 KB. Không thay thế test runtime 16 KB hoặc kiểm tra AAB release. |

Đã cài lại app bình thường sau khi integration runner kết thúc và kiểm tra hình ảnh màn Vault, chính sách và quyền/thông báo trên điện thoại. Điều hướng bản app bình thường được kiểm tra bằng phím TAB/ENTER/BACK qua ADB. Quyền notification vẫn `granted=false`, không tự hiện yêu cầu hệ thống lúc khởi động. Log `AndroidRuntime` của tiến trình app cuối không có lỗi.

## Thiết bị và quan sát nền tảng

- Điện thoại Redmi, model **23021RAAEG**.
- Android **15 / API 35**, ABI **arm64**.
- Page size thực tế **4096 byte (4 KB)**.
- App integration nhắm **target SDK 36**. Trong lúc app ở nền, `dumpsys` ghi nhận service có `isForeground=true`, `targetSdkVersion=36`, `foregroundServiceType=1` (`dataSync`). Đây là quan sát service thật trên API 35, không phải test runtime Android 16.

## APK app bình thường của mốc SSH đầu tiên

- Artifact: `build/app/outputs/flutter-apk/app-debug.apk`, Android arm64.
- SHA-256: `6459e312ba5f1625002ed3ce920730c243e67143e310d32f881c61f8bc8d8bc1`.
- Build ghi nhận cảnh báo không gây thất bại: plugin `integration_test` đề nghị NDK 28.2 trong khi project cấu hình NDK `27.0.12077973`. Không tuyên bố đã nâng NDK hoặc đã giải quyết cảnh báo này.
- Kết quả build/merged manifest ở trên thuộc artifact này; trạng thái cài/mở và phạm vi kiểm tra runtime vẫn ghi riêng.
- ELF64 Rust arm64/x86_64 có `PT_LOAD` alignment `0x4000` (16 KB); Flutter và Vulkan validation arm64 có alignment `0x10000` (64 KB). Rust armeabi-v7a là ELF32, alignment 4 KB; không gộp ELF32 vào kết luận kiểm tra 64-bit. Đây là APK debug theo lệnh build arm64, không phải artifact phân phối đa ABI đã được xác nhận.

## Luồng đã kiểm chứng trên điện thoại thật

Test nằm tại `integration_test/integration_android_smoke_test.dart`; việc chấp thuận host fixture đi qua UI first-use thật trong `integration_test/qa_host_trust.dart` và chỉ cho phép fingerprint fixture đã đối chiếu độc lập. Không chấp thuận tùy tiện host thật hoặc thay thế khóa SSH đã đổi.

1. Mở màn chính sách và màn quyền **trước khi tạo/mở khóa Vault**. Nội dung chính sách đọc được offline và chuyển sang tiếng Anh được.
2. Mở giải thích xin quyền thông báo của app rồi chọn hủy. Luồng hủy không mở yêu cầu quyền hệ thống.
3. Tạo/mở khóa Vault tạm cho fixture, kết nối SSH native lần đầu, kiểm tra và chấp thuận host key fixture qua UI. Nhập vào terminal nhận được phản hồi từ máy chủ kiểm soát.
4. Host test đưa app về HOME rồi mở lại Activity thật. Test quan sát được chuyển nền/resume, giữ cùng SSH session ID, cùng tab và cùng đối tượng terminal; phiên tiếp tục nhận input sau resume.
5. Gọi `pauseBackgroundSupport()` qua bridge để thực hiện `stopService` native thật. Trạng thái hỗ trợ nền dừng, refresh count không tự bật lại, nhưng kết nối SSH hiện có vẫn nhận input. Sau đó explicit resume bật lại hỗ trợ nền.
6. Đóng kết nối SSH native thật, đợi terminal nhận trạng thái đóng, dùng nút reconnect đang hiển thị. Kết nối mới có session ID mới nhưng giữ cùng tab/terminal; không hỏi tin cậy lại host key fixture đã lưu và tiếp tục nhận input.

Luồng pause ở bước 5 xác nhận việc tắt **dịch vụ hỗ trợ nền** không đồng nghĩa ngắt SSH. Bước này gọi phương thức app/MethodChannel thật; không dùng ADB để gọi trực tiếp action của service không exported, và không được ghi nhận là đã nhấn nút trên notification.

## Bản sửa và khả năng đã có trong source

- Android dùng `libc::flock(LOCK_EX | LOCK_NB)` cho sidecar lock của kho host key, thay cho `File::try_lock()` không được hỗ trợ trong runtime Android đang dùng. Xử lý lại khi bị ngắt, phân biệt contention và lỗi I/O, giữ quyền sở hữu file descriptor đến khi đóng; nền tảng khác tiếp tục dùng nhánh chuẩn tương ứng.
- API notification trả riêng trạng thái quyền runtime, bật/tắt thông báo toàn app và bật/tắt kênh. Chỉ xin quyền sau thao tác rõ ràng; có đường mở Android Settings. Các trạng thái và lỗi bridge được kiểm tra bằng mock trong test Flutter; điều đó không thay thế thử hộp thoại quyền hệ thống trên thiết bị.
- Service dùng `START_NOT_STICKY`, không khôi phục notification phiên ảo khi thiếu count hợp lệ; có cleanup `onTimeout(int, int)` cho giới hạn `dataSync` Android 15 và xử lý trường hợp hệ điều hành từ chối promotion foreground.
- Callback dừng dịch vụ và các nút pause/resume của app giữ trạng thái hỗ trợ nền riêng với phiên SSH. Test có bảo vệ các trường hợp phản hồi native đến muộn hoặc count/ngôn ngữ đổi trong lúc chờ.
- Android automatic backup bị vô hiệu hóa bằng `allowBackup=false` và quy tắc loại trừ cloud backup/device transfer. Ba XML manifest/backup đã qua kiểm tra cú pháp `xmllint`; không coi đó là test backup/restore thực tế.
- Màn chính sách/quyền và cấu hình chặn release thiếu thông tin đã được bổ sung. Các nghĩa vụ phát hành còn lại được ghi riêng tại [rà soát Google Play](GOOGLE_PLAY_RELEASE_REVIEW.md).

## Giới hạn kiểm thử

- Trong lượt integration, quyền notification trên điện thoại giữ trạng thái **bị từ chối**. Chỉ kiểm tra hủy màn giải thích của app; **chưa thử cấp/từ chối qua hộp thoại quyền Android thật**, chưa nhấn action trên notification.
- Input terminal được đưa qua cơ chế Flutter integration (`testTextInput`) vào luồng terminal thật. **Chưa xác minh bàn phím mềm/IME vật lý**, bố cục hoặc thao tác gõ thủ công bằng bàn phím thiết bị.
- Chuyển HOME/resume được kiểm tra trong một lượt ngắn. Chưa thử chạy nền lâu, Doze, tiến trình bị hệ điều hành/OEM kill, chuyển mạng hoặc giới hạn **6 giờ `dataSync`**. `onTimeout` đã có trong source nhưng chưa kích hoạt bằng runtime trong lượt này.
- **Chưa test runtime 16 KB**, chưa test thiết bị/emulator **Android 16**, và chưa xác nhận alignment/native libraries của artifact release cuối. Kết quả trên máy 4 KB không chứng minh tương thích 16 KB.
- Không phải phép kiểm thử toàn bộ giao thức/tính năng khác, mọi dòng máy hoặc bản release/AAB đã ký upload. Không có bước nộp hay xuất bản Google Play trong kiểm chứng này.

## Dữ liệu thử và cleanup — lượt SSH đầu tiên

Baseline quan sát được là màn Vault **chưa khởi tạo**; trong lượt kiểm chứng này không khởi tạo một Vault người dùng thật. Fixture tạo cơ sở dữ liệu Vault tạm riêng dưới đường dẫn private app-data thật, rồi đóng/xóa thư mục fixture khi cleanup.

Flutter integration runner **gỡ ứng dụng test khi cleanup**. Vì vậy không tuyên bố chung rằng mọi dữ liệu ứng dụng có sẵn đều được giữ nguyên; app bình thường đã được cài/mở lại như ghi ở bảng trên. SSH fixture đã dừng và ADB reverse cổng 22220 đã được gỡ. Báo cáo không ghi mật khẩu thử, private key, nội dung Vault hoặc dữ liệu host người dùng.
