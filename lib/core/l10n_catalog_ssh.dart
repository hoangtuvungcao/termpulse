/// Native SSH phases stay distinct so a timeout never implies a bad password.
const sshErrorSources = <String, String>{
  'SSH_CONNECTION':
      'Không tới được máy chủ SSH. Kiểm tra địa chỉ, cổng, mạng và proxy.',
  'SSH_CONNECT_TIMEOUT':
      'Kết nối mạng tới SSH/proxy hết thời gian. Chưa tới bước xác thực.',
  'SSH_HANDSHAKE':
      'Không hoàn tất bắt tay SSH. Kiểm tra dịch vụ SSH và xác minh host key.',
  'SSH_HANDSHAKE_TIMEOUT':
      'Bắt tay SSH hoặc xác minh host key hết thời gian. Chưa tới bước xác thực.',
  'SSH_AUTHENTICATION_REJECTED':
      'Máy chủ từ chối xác thực SSH. Kiểm tra tên đăng nhập, mật khẩu hoặc khóa SSH.',
  'SSH_AUTHENTICATION_REQUIRED':
      'Máy chủ SSH yêu cầu thông tin đăng nhập. Chọn tài khoản và mật khẩu hoặc khóa SSH.',
  'SSH_AUTHENTICATION_ADDITIONAL':
      'Máy chủ yêu cầu thêm bước xác thực SSH. Phương thức nhiều bước này chưa được hỗ trợ.',
  'SSH_AUTHENTICATION_TIMEOUT':
      'Máy chủ chưa trả lời xác thực SSH trước thời hạn. Chưa thể kết luận sai mật khẩu.',
  'SSH_AUTHENTICATION_INTERRUPTED':
      'Kết nối bị ngắt trong lúc xác thực SSH. Chưa thể kết luận sai mật khẩu.',
  'SSH_PRIVATE_KEY':
      'Không đọc hoặc giải mã được khóa SSH. Kiểm tra khóa và mật khẩu bảo vệ khóa.',
};

const sshTranslations = <String, List<String>>{
  'Không tới được máy chủ SSH. Kiểm tra địa chỉ, cổng, mạng và proxy.': [
    'Cannot reach the SSH server. Check the address, port, network and proxy.',
    '无法连接 SSH 服务器。请检查地址、端口、网络和代理。',
    'SSH サーバーに接続できません。アドレス、ポート、ネットワーク、プロキシを確認してください。',
    'SSH 서버에 연결할 수 없습니다. 주소, 포트, 네트워크 및 프록시를 확인하세요.',
  ],
  'Kết nối mạng tới SSH/proxy hết thời gian. Chưa tới bước xác thực.': [
    'The network connection to SSH/proxy timed out before authentication.',
    '连接 SSH/代理的网络请求超时，尚未开始身份验证。',
    'SSH／プロキシへのネットワーク接続がタイムアウトしました。認証はまだ始まっていません。',
    '인증 전에 SSH/프록시에 대한 네트워크 연결 시간이 초과되었습니다.',
  ],
  'Không hoàn tất bắt tay SSH. Kiểm tra dịch vụ SSH và xác minh host key.': [
    'The SSH handshake failed. Check the SSH service and host key verification.',
    'SSH 握手失败。请检查 SSH 服务和主机密钥验证。',
    'SSH ハンドシェイクに失敗しました。SSH サービスとホスト鍵の確認状況を確認してください。',
    'SSH 핸드셰이크에 실패했습니다. SSH 서비스와 호스트 키 확인 상태를 점검하세요.',
  ],
  'Bắt tay SSH hoặc xác minh host key hết thời gian. Chưa tới bước xác thực.': [
    'The SSH handshake or host key verification timed out before authentication.',
    'SSH 握手或主机密钥验证超时，尚未开始身份验证。',
    'SSH ハンドシェイクまたはホスト鍵の確認がタイムアウトしました。認証はまだ始まっていません。',
    '인증 전에 SSH 핸드셰이크 또는 호스트 키 확인 시간이 초과되었습니다.',
  ],
  'Máy chủ từ chối xác thực SSH. Kiểm tra tên đăng nhập, mật khẩu hoặc khóa SSH.': [
    'The server rejected SSH authentication. Check the username, password or SSH key.',
    '服务器拒绝了 SSH 身份验证。请检查用户名、密码或 SSH 密钥。',
    'サーバーが SSH 認証を拒否しました。ユーザー名、パスワード、SSH 鍵を確認してください。',
    '서버가 SSH 인증을 거부했습니다. 사용자 이름, 비밀번호 또는 SSH 키를 확인하세요.',
  ],
  'Máy chủ SSH yêu cầu thông tin đăng nhập. Chọn tài khoản và mật khẩu hoặc khóa SSH.': [
    'The SSH server requires credentials. Select an account and a password or SSH key.',
    'SSH 服务器需要登录凭据。请选择账号及密码或 SSH 密钥。',
    'SSH サーバーには認証情報が必要です。アカウントとパスワードまたは SSH 鍵を選択してください。',
    'SSH 서버에 자격 증명이 필요합니다. 계정과 비밀번호 또는 SSH 키를 선택하세요.',
  ],
  'Máy chủ yêu cầu thêm bước xác thực SSH. Phương thức nhiều bước này chưa được hỗ trợ.': [
    'The server requires another SSH authentication step. This multi-step method is not supported yet.',
    '服务器要求进一步的 SSH 身份验证。目前不支持这种多步骤验证。',
    'サーバーが追加の SSH 認証を要求しています。この多段階認証にはまだ対応していません。',
    '서버가 추가 SSH 인증 단계를 요구합니다. 이 다단계 방식은 아직 지원되지 않습니다.',
  ],
  'Máy chủ chưa trả lời xác thực SSH trước thời hạn. Chưa thể kết luận sai mật khẩu.': [
    'The server did not answer SSH authentication before the deadline. This does not confirm a wrong password.',
    '服务器未在时限内回应 SSH 身份验证，无法据此判断密码错误。',
    '期限内に SSH 認証の応答がありませんでした。パスワードの誤りとは断定できません。',
    '서버가 제한 시간 내에 SSH 인증에 응답하지 않았습니다. 비밀번호 오류로 단정할 수 없습니다.',
  ],
  'Kết nối bị ngắt trong lúc xác thực SSH. Chưa thể kết luận sai mật khẩu.': [
    'The connection ended during SSH authentication. This does not confirm a wrong password.',
    '连接在 SSH 身份验证期间中断，无法据此判断密码错误。',
    'SSH 認証中に接続が切れました。パスワードの誤りとは断定できません。',
    'SSH 인증 중 연결이 끊어졌습니다. 비밀번호 오류로 단정할 수 없습니다.',
  ],
  'Không đọc hoặc giải mã được khóa SSH. Kiểm tra khóa và mật khẩu bảo vệ khóa.':
      [
        'Cannot read or decrypt the SSH key. Check the key and its passphrase.',
        '无法读取或解密 SSH 密钥。请检查密钥及其保护密码。',
        'SSH 鍵を読み取りまたは復号できません。鍵とパスフレーズを確認してください。',
        'SSH 키를 읽거나 복호화할 수 없습니다. 키와 키 암호를 확인하세요.',
      ],
};
