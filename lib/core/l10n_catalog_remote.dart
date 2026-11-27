/// Stable native error codes are presented with a translated explanation.
const remoteDesktopErrorSources = <String, String>{
  'REMOTE_DESKTOP_INVALID_SIZE':
      'Độ phân giải vượt giới hạn 8.294.400 điểm ảnh hoặc 8192 điểm mỗi chiều.',
  'REMOTE_DESKTOP_PROTOCOL': 'Hãy chọn giao thức RDP hoặc VNC.',
  'REMOTE_DESKTOP_ADDRESS': 'Nhập địa chỉ máy chủ và cổng từ 1 đến 65535.',
  'REMOTE_DESKTOP_USERNAME':
      'Nhập tên tài khoản RDP trong thông tin đăng nhập.',
  'REMOTE_DESKTOP_HOST':
      'Không tìm thấy kết nối đã lưu. Hãy mở lại danh sách host.',
  'REMOTE_DESKTOP_VAULT_LOCKED':
      'Vault đã khóa. Hãy mở khóa trước khi kết nối màn hình từ xa.',
  'REMOTE_DESKTOP_CONFIG':
      'Cấu hình màn hình từ xa không hợp lệ. Hãy kiểm tra lại host.',
  'REMOTE_DESKTOP_PROXY':
      'RDP/VNC cần kết nối trực tiếp. Hãy tắt kế thừa proxy và jump host SSH.',
  'REMOTE_DESKTOP_CREDENTIAL': 'RDP/VNC cần thông tin đăng nhập loại Mật khẩu.',
  'REMOTE_DESKTOP_CLOSED': 'Phiên màn hình từ xa đã kết thúc. Hãy kết nối lại.',
  'REMOTE_DESKTOP_BUSY':
      'Hàng đợi nhập liệu đã đầy hoặc phiên đã đóng. Hãy kết nối lại.',
  'REMOTE_DESKTOP_KEY': 'Phím gửi tới máy từ xa không hợp lệ.',
  'REMOTE_DESKTOP_TEXT': 'Mỗi lần chỉ gửi tối đa 16 KiB văn bản.',
  'REMOTE_DESKTOP_CLIPBOARD':
      'Clipboard VNC chỉ hỗ trợ 16 KiB Latin-1. Dùng Gõ văn bản để gửi Unicode.',
  'REMOTE_DESKTOP_CLIPBOARD_UNSUPPORTED':
      'Dùng Gõ văn bản để nhập vào RDP. Phiên này chưa hỗ trợ clipboard.',
  'REMOTE_DESKTOP_CONNECT':
      'Không tới được máy chủ. Hãy kiểm tra địa chỉ, cổng và mạng.',
  'REMOTE_DESKTOP_TIMEOUT':
      'Kết nối quá thời gian chờ. Hãy kiểm tra máy chủ và mạng.',
  'REMOTE_DESKTOP_FRAME': 'Máy chủ gửi dữ liệu hình ảnh không hợp lệ.',
  'RDP_CERTIFICATE_PIN':
      'Dấu vân tay SHA256 phải có đủ 64 ký tự thập lục phân.',
  'RDP_CERTIFICATE_UNTRUSTED':
      'Chứng chỉ RDP chưa được tin cậy hoặc đã thay đổi. Hãy xác minh dấu vân tay trước khi kết nối.',
  'RDP_CERTIFICATE_CA':
      'Chứng chỉ CA không hợp lệ. Hãy kiểm tra nội dung PEM trong cấu hình RDP.',
  'RDP_NEGOTIATION':
      'Máy chủ không chấp nhận thương lượng RDP. Hãy kiểm tra dịch vụ và chế độ bảo mật.',
  'RDP_SERVER_NAME': 'Tên máy chủ TLS không hợp lệ. Hãy kiểm tra cấu hình RDP.',
  'RDP_TLS': 'Không thiết lập được kết nối TLS bảo mật tới máy chủ RDP.',
  'RDP_AUTHENTICATION':
      'Xác thực RDP thất bại. Hãy kiểm tra tài khoản, mật khẩu và tên miền.',
  'RDP_CONNECTION': 'Kết nối RDP bị gián đoạn. Hãy kết nối lại.',
  'RDP_DECODE': 'Không đọc được hình ảnh RDP từ máy chủ.',
  'RDP_WRITE': 'Không gửi được dữ liệu tới máy chủ RDP. Hãy kết nối lại.',
  'RDP_REACTIVATION_TIMEOUT':
      'Máy chủ RDP không hoàn tất đổi chế độ hiển thị. Hãy kết nối lại.',
  'VNC_FRAME': 'Máy chủ gửi dữ liệu hình ảnh không hợp lệ.',
  'VNC_CONFIG':
      'Cấu hình VNC không hợp lệ. Hãy kiểm tra máy chủ và chế độ xác thực.',
  'VNC_AUTHENTICATION':
      'Xác thực VNC thất bại. Hãy kiểm tra mật khẩu và chế độ xác thực của máy chủ.',
  'VNC_CONNECT': 'Không tới được máy chủ. Hãy kiểm tra địa chỉ, cổng và mạng.',
  'VNC_CONNECTION': 'Kết nối VNC bị gián đoạn. Hãy kết nối lại.',
  'VNC_REFRESH':
      'Không yêu cầu được hình ảnh mới từ máy chủ VNC. Hãy kết nối lại.',
};

const remoteTranslations = <String, List<String>>{
  'Thu nhỏ': ['Zoom out', '缩小', '縮小', '축소'],
  'Phóng to': ['Zoom in', '放大', '拡大', '확대'],
  'Toàn màn hình': ['Full screen', '全屏', '全画面', '전체 화면'],
  'Thoát toàn màn hình': ['Exit full screen', '退出全屏', '全画面を終了', '전체 화면 종료'],
  'Kích thước thật (100%)': [
    'Actual size (100%)',
    '实际大小 (100%)',
    '実際のサイズ (100%)',
    '실제 크기 (100%)',
  ],
  'Vuốt để rê chuột · Chạm 1 ngón: trái · 2 ngón: phải': [
    'Swipe to move the pointer · 1-finger tap: left · 2 fingers: right',
    '滑动移动鼠标 · 单指轻点：左键 · 双指轻点：右键',
    'スワイプでマウス移動 · 1本指タップ：左 · 2本指：右',
    '밀어서 포인터 이동 · 한 손가락 탭: 왼쪽 · 두 손가락: 오른쪽',
  ],
  'Độ phân giải vượt giới hạn 8.294.400 điểm ảnh hoặc 8192 điểm mỗi chiều.': [
    'Resolution exceeds 8,294,400 pixels or 8192 pixels per side.',
    '分辨率超过 8,294,400 像素或单边 8192 像素的限制。',
    '解像度が合計 8,294,400 ピクセル、または一辺 8192 ピクセルを超えています。',
    '해상도가 총 8,294,400픽셀 또는 한 변 8192픽셀 한도를 초과합니다.',
  ],
  'Hãy chọn giao thức RDP hoặc VNC.': [
    'Choose the RDP or VNC protocol.',
    '请选择 RDP 或 VNC 协议。',
    'RDP または VNC を選んでください。',
    'RDP 또는 VNC 프로토콜을 선택하세요.',
  ],
  'Nhập địa chỉ máy chủ và cổng từ 1 đến 65535.': [
    'Enter a server address and a port from 1 to 65535.',
    '请输入服务器地址和 1 到 65535 之间的端口。',
    'サーバーのアドレスと 1〜65535 のポートを入力してください。',
    '서버 주소와 1~65535 사이의 포트를 입력하세요.',
  ],
  'Nhập tên tài khoản RDP trong thông tin đăng nhập.': [
    'Enter the RDP account name in your credentials.',
    '请在凭据中输入 RDP 账户名。',
    '認証情報に RDP のアカウント名を入力してください。',
    '자격 증명에 RDP 계정 이름을 입력하세요.',
  ],
  'Không tìm thấy kết nối đã lưu. Hãy mở lại danh sách host.': [
    'Saved connection not found. Reopen the host list.',
    '找不到已保存的连接。请重新打开主机列表。',
    '保存した接続が見つかりません。ホスト一覧を開き直してください。',
    '저장된 연결을 찾을 수 없습니다. 호스트 목록을 다시 여세요.',
  ],
  'Vault đã khóa. Hãy mở khóa trước khi kết nối màn hình từ xa.': [
    'The vault is locked. Unlock it before connecting to a remote desktop.',
    '保险库已锁定。请先解锁再连接远程桌面。',
    'Vault がロックされています。解除してからリモートデスクトップに接続してください。',
    'Vault가 잠겨 있습니다. 잠금을 해제한 후 원격 데스크톱에 연결하세요.',
  ],
  'Cấu hình màn hình từ xa không hợp lệ. Hãy kiểm tra lại host.': [
    'Invalid remote desktop settings. Check the saved host.',
    '远程桌面配置无效。请检查已保存的主机。',
    'リモートデスクトップの設定が無効です。保存したホストを確認してください。',
    '원격 데스크톱 설정이 잘못되었습니다. 저장된 호스트를 확인하세요.',
  ],
  'RDP/VNC cần kết nối trực tiếp. Hãy tắt kế thừa proxy và jump host SSH.': [
    'RDP/VNC need a direct connection. Disable inherited SSH proxy and jump host settings.',
    'RDP/VNC 需要直接连接。请禁用继承的 SSH 代理和跳板机。',
    'RDP/VNC は直接接続が必要です。SSH プロキシと踏み台の継承を無効にしてください。',
    'RDP/VNC는 직접 연결이 필요합니다. 상속된 SSH 프록시와 점프 호스트 설정을 끄세요.',
  ],
  'RDP/VNC cần thông tin đăng nhập loại Mật khẩu.': [
    'RDP/VNC require a Password credential.',
    'RDP/VNC 需要密码类型的凭据。',
    'RDP/VNC にはパスワード形式の認証情報が必要です。',
    'RDP/VNC에는 비밀번호 유형의 자격 증명이 필요합니다.',
  ],
  'Phiên màn hình từ xa đã kết thúc. Hãy kết nối lại.': [
    'The remote desktop session ended. Reconnect to continue.',
    '远程桌面会话已结束。请重新连接。',
    'リモートデスクトップのセッションが終了しました。再接続してください。',
    '원격 데스크톱 세션이 종료되었습니다. 다시 연결하세요.',
  ],
  'Hàng đợi nhập liệu đã đầy hoặc phiên đã đóng. Hãy kết nối lại.': [
    'The input queue is full or the session closed. Reconnect to continue.',
    '输入队列已满或会话已关闭。请重新连接。',
    '入力待ちが上限に達したか、セッションが終了しました。再接続してください。',
    '입력 대기열이 가득 찼거나 세션이 닫혔습니다. 다시 연결하세요.',
  ],
  'Phím gửi tới máy từ xa không hợp lệ.': [
    'Invalid key sent to the remote computer.',
    '发送到远程计算机的按键无效。',
    'リモート端末に送るキーが無効です。',
    '원격 컴퓨터에 보낸 키가 잘못되었습니다.',
  ],
  'Mỗi lần chỉ gửi tối đa 16 KiB văn bản.': [
    'Send at most 16 KiB of text at a time.',
    '每次最多发送 16 KiB 文本。',
    '一度に送れる文字は最大 16 KiB です。',
    '한 번에 최대 16 KiB의 텍스트를 보내세요.',
  ],
  'Clipboard VNC chỉ hỗ trợ 16 KiB Latin-1. Dùng Gõ văn bản để gửi Unicode.': [
    'VNC clipboard supports up to 16 KiB of Latin-1. Use Type text for Unicode.',
    'VNC 剪贴板仅支持最多 16 KiB 的 Latin-1 文本。Unicode 请使用「输入文本」。',
    'VNC クリップボードは Latin-1 の最大 16 KiB です。Unicode は「文字を入力」を使ってください。',
    'VNC 클립보드는 최대 16 KiB의 Latin-1을 지원합니다. 유니코드는 텍스트 입력을 사용하세요.',
  ],
  'Dùng Gõ văn bản để nhập vào RDP. Phiên này chưa hỗ trợ clipboard.': [
    'Use Type text for RDP input. This session does not support clipboard redirection.',
    '请使用「输入文本」向 RDP 输入。此会话不支持剪贴板重定向。',
    'RDP への入力には「文字を入力」を使ってください。このセッションではクリップボード転送は利用できません。',
    'RDP에는 텍스트 입력을 사용하세요. 이 세션은 클립보드 리디렉션을 지원하지 않습니다.',
  ],
  'Không tới được máy chủ. Hãy kiểm tra địa chỉ, cổng và mạng.': [
    'Cannot reach the server. Check the address, port and network.',
    '无法连接服务器。请检查地址、端口和网络。',
    'サーバーに接続できません。アドレス、ポート、ネットワークを確認してください。',
    '서버에 연결할 수 없습니다. 주소, 포트, 네트워크를 확인하세요.',
  ],
  'Kết nối quá thời gian chờ. Hãy kiểm tra máy chủ và mạng.': [
    'The connection timed out. Check the server and network.',
    '连接超时。请检查服务器和网络。',
    '接続がタイムアウトしました。サーバーとネットワークを確認してください。',
    '연결 시간이 초과되었습니다. 서버와 네트워크를 확인하세요.',
  ],
  'Máy chủ gửi dữ liệu hình ảnh không hợp lệ.': [
    'The server sent invalid image data.',
    '服务器发送了无效的图像数据。',
    'サーバーから無効な画像データを受信しました。',
    '서버가 잘못된 이미지 데이터를 보냈습니다.',
  ],
  'Dấu vân tay SHA256 phải có đủ 64 ký tự thập lục phân.': [
    'The SHA256 fingerprint must contain all 64 hexadecimal characters.',
    'SHA256 指纹必须包含完整的 64 个十六进制字符。',
    'SHA256 指紋は 16 進数で 64 桁すべて入力してください。',
    'SHA256 지문은 64자리 16진수를 모두 입력해야 합니다.',
  ],
  'Chứng chỉ RDP chưa được tin cậy hoặc đã thay đổi. Hãy xác minh dấu vân tay trước khi kết nối.': [
    'The RDP certificate is untrusted or has changed. Verify its fingerprint before connecting.',
    'RDP 证书不受信任或已更改。请先核实指纹再连接。',
    'RDP 証明書が未確認、または変更されています。接続前に指紋を確認してください。',
    'RDP 인증서가 신뢰되지 않거나 변경되었습니다. 연결 전에 지문을 확인하세요.',
  ],
  'Chứng chỉ CA không hợp lệ. Hãy kiểm tra nội dung PEM trong cấu hình RDP.': [
    'Invalid CA certificate. Check the PEM data in RDP settings.',
    'CA 证书无效。请检查 RDP 配置中的 PEM 内容。',
    'CA 証明書が無効です。RDP 設定の PEM データを確認してください。',
    'CA 인증서가 잘못되었습니다. RDP 설정의 PEM 내용을 확인하세요.',
  ],
  'Máy chủ không chấp nhận thương lượng RDP. Hãy kiểm tra dịch vụ và chế độ bảo mật.':
      [
        'RDP negotiation failed. Check the server service and security mode.',
        'RDP 协商失败。请检查服务器服务和安全模式。',
        'RDP の接続交渉に失敗しました。サービスとセキュリティ設定を確認してください。',
        'RDP 협상에 실패했습니다. 서버 서비스와 보안 모드를 확인하세요.',
      ],
  'Tên máy chủ TLS không hợp lệ. Hãy kiểm tra cấu hình RDP.': [
    'Invalid TLS server name. Check RDP settings.',
    'TLS 服务器名称无效。请检查 RDP 配置。',
    'TLS サーバー名が無効です。RDP 設定を確認してください。',
    'TLS 서버 이름이 잘못되었습니다. RDP 설정을 확인하세요.',
  ],
  'Không thiết lập được kết nối TLS bảo mật tới máy chủ RDP.': [
    'Could not establish a secure TLS connection to the RDP server.',
    '无法与 RDP 服务器建立安全 TLS 连接。',
    'RDP サーバーへの安全な TLS 接続を確立できませんでした。',
    'RDP 서버에 보안 TLS 연결을 설정할 수 없습니다.',
  ],
  'Xác thực RDP thất bại. Hãy kiểm tra tài khoản, mật khẩu và tên miền.': [
    'RDP authentication failed. Check the account, password and domain.',
    'RDP 身份验证失败。请检查账户、密码和域。',
    'RDP 認証に失敗しました。アカウント、パスワード、ドメインを確認してください。',
    'RDP 인증에 실패했습니다. 계정, 비밀번호, 도메인을 확인하세요.',
  ],
  'Kết nối RDP bị gián đoạn. Hãy kết nối lại.': [
    'The RDP connection was interrupted. Reconnect to continue.',
    'RDP 连接中断。请重新连接。',
    'RDP 接続が切れました。再接続してください。',
    'RDP 연결이 끊어졌습니다. 다시 연결하세요.',
  ],
  'Không đọc được hình ảnh RDP từ máy chủ.': [
    'Could not decode the RDP image from the server.',
    '无法解码服务器的 RDP 图像。',
    'サーバーの RDP 画像を読み取れませんでした。',
    '서버의 RDP 이미지를 읽을 수 없습니다.',
  ],
  'Không gửi được dữ liệu tới máy chủ RDP. Hãy kết nối lại.': [
    'Could not send data to the RDP server. Reconnect to continue.',
    '无法向 RDP 服务器发送数据。请重新连接。',
    'RDP サーバーにデータを送れませんでした。再接続してください。',
    'RDP 서버에 데이터를 보낼 수 없습니다. 다시 연결하세요.',
  ],
  'Máy chủ RDP không hoàn tất đổi chế độ hiển thị. Hãy kết nối lại.': [
    'The RDP server did not complete the display change. Reconnect to continue.',
    'RDP 服务器未完成显示模式切换。请重新连接。',
    'RDP サーバーの画面切り替えが完了しませんでした。再接続してください。',
    'RDP 서버의 화면 모드 변경이 완료되지 않았습니다. 다시 연결하세요.',
  ],
  'Cấu hình VNC không hợp lệ. Hãy kiểm tra máy chủ và chế độ xác thực.': [
    'Invalid VNC settings. Check the server and authentication mode.',
    'VNC 配置无效。请检查服务器和身份验证模式。',
    'VNC 設定が無効です。サーバーと認証方式を確認してください。',
    'VNC 설정이 잘못되었습니다. 서버와 인증 모드를 확인하세요.',
  ],
  'Xác thực VNC thất bại. Hãy kiểm tra mật khẩu và chế độ xác thực của máy chủ.': [
    'VNC authentication failed. Check the password and server authentication mode.',
    'VNC 身份验证失败。请检查密码和服务器的验证模式。',
    'VNC 認証に失敗しました。パスワードとサーバーの認証方式を確認してください。',
    'VNC 인증에 실패했습니다. 비밀번호와 서버 인증 모드를 확인하세요.',
  ],
  'Kết nối VNC bị gián đoạn. Hãy kết nối lại.': [
    'The VNC connection was interrupted. Reconnect to continue.',
    'VNC 连接中断。请重新连接。',
    'VNC 接続が切れました。再接続してください。',
    'VNC 연결이 끊어졌습니다. 다시 연결하세요.',
  ],
  'Không yêu cầu được hình ảnh mới từ máy chủ VNC. Hãy kết nối lại.': [
    'Could not request a new image from the VNC server. Reconnect to continue.',
    '无法向 VNC 服务器请求新图像。请重新连接。',
    'VNC サーバーに新しい画面を要求できませんでした。再接続してください。',
    'VNC 서버에서 새 화면을 요청할 수 없습니다. 다시 연결하세요.',
  ],
};
