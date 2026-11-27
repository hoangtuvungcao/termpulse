// Values are [en, zh, ja, ko]; Vietnamese uses the source key.
const aiPrivacyTranslations = <String, List<String>>{
  'Dữ liệu gửi cho AI': [
    'Data sent to AI',
    '发送给 AI 的数据',
    'AI に送信するデータ',
    'AI로 전송되는 데이터',
  ],
  'Nhập endpoint HTTP(S) hợp lệ để xem nơi nhận.': [
    'Enter a valid HTTP(S) endpoint to see the recipient.',
    '输入有效的 HTTP(S) 端点以查看接收方。',
    '有効な HTTP(S) エンドポイントを入力して送信先を確認してください。',
    '수신 대상을 확인하려면 올바른 HTTP(S) 엔드포인트를 입력하세요.',
  ],
  'Nơi nhận: {endpoint}': [
    'Recipient: {endpoint}',
    '接收方：{endpoint}',
    '送信先: {endpoint}',
    '수신 대상: {endpoint}',
  ],
  'Khi nhấn Tạo nháp, yêu cầu bạn nhập, model và gợi ý hệ điều hành/shell được gửi trực tiếp tới endpoint đã chọn. API key, nếu nhập, chỉ được gửi trong phần xác thực tới endpoint đó. Ứng dụng không tự đính kèm lịch sử terminal hoặc dữ liệu Vault.': [
    'When you select Generate draft, your prompt, model and OS/shell hints are sent directly to the selected endpoint. If supplied, the API key is sent only as authentication to that endpoint. The app does not automatically attach terminal history or Vault data.',
    '点击生成草稿后，您输入的请求、模型和操作系统/shell 提示将直接发送到所选端点。如填写 API 密钥，该密钥仅用于向该端点进行身份验证。应用不会自动附加终端历史记录或 Vault 数据。',
    '下書きを生成すると、入力したリクエスト、モデル、OS/shell のヒントが選択したエンドポイントに直接送信されます。API キーを入力した場合、その送信先への認証にのみ使用されます。端末履歴や Vault データは自動で添付されません。',
    '초안 생성을 누르면 입력한 요청, 모델 및 OS/shell 정보가 선택한 엔드포인트로 직접 전송됩니다. API 키를 입력한 경우 해당 엔드포인트 인증에만 전송됩니다. 앱은 터미널 기록이나 Vault 데이터를 자동으로 첨부하지 않습니다.',
  ],
  'Dịch vụ nhận dữ liệu áp dụng chính sách lưu giữ riêng. Không đưa mật khẩu, private key hoặc dữ liệu nhạy cảm vào yêu cầu.': [
    'The receiving service applies its own retention policy. Do not include passwords, private keys or sensitive data in your prompt.',
    '接收服务适用其自身的数据保留政策。请勿在请求中包含密码、私钥或敏感数据。',
    '送信先サービス独自の保存方針が適用されます。パスワード、秘密鍵、機密データをリクエストに含めないでください。',
    '수신 서비스의 자체 보관 정책이 적용됩니다. 요청에 비밀번호, 개인 키 또는 민감한 데이터를 포함하지 마세요.',
  ],
  'Cảnh báo HTTP: yêu cầu và API key được truyền không mã hóa. Chỉ dùng endpoint cục bộ hoặc mạng tin cậy; ưu tiên HTTPS.': [
    'HTTP warning: your request and API key are transmitted without encryption. Use only a local endpoint or trusted network; prefer HTTPS.',
    'HTTP 警告：请求和 API 密钥将以未加密形式传输。仅使用本地端点或可信网络；建议使用 HTTPS。',
    'HTTP の警告: リクエストと API キーは暗号化されずに送信されます。ローカルの送信先または信頼できるネットワークでのみ使用し、HTTPS を優先してください。',
    'HTTP 경고: 요청과 API 키가 암호화되지 않은 상태로 전송됩니다. 로컬 엔드포인트 또는 신뢰할 수 있는 네트워크에서만 사용하고 HTTPS를 권장합니다.',
  ],
  'Tôi đã đọc và đồng ý gửi dữ liệu nêu trên tới endpoint này khi nhấn Tạo nháp.': [
    'I have read this notice and agree to send the data above to this endpoint when I select Generate draft.',
    '我已阅读此说明，并同意在点击生成草稿时将上述数据发送到此端点。',
    '説明を読み、下書き生成時に上記のデータをこの送信先に送ることに同意します。',
    '이 안내를 읽었으며 초안 생성을 누를 때 위 데이터를 이 엔드포인트로 전송하는 데 동의합니다.',
  ],
  'Đọc thông tin dữ liệu và xác nhận trước khi gửi yêu cầu AI.': [
    'Read the data notice and confirm before sending an AI request.',
    '发送 AI 请求前，请阅读数据说明并确认。',
    'AI リクエストを送信する前に、データの説明を読んで同意してください。',
    'AI 요청을 보내기 전에 데이터 안내를 읽고 동의해 주세요.',
  ],
};
