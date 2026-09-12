/// 密信（Mx）核心常量。
///
/// 这些值同时被 Android 端（io.heckel.mx）与桌面端（Wails/Go）使用，
/// 是全平台统一的"线格式"约定 —— 改这里意味着三个端要同步改。
library;

/// 默认服务端。Android 端把地址写在 values.xml 的 app_base_url，
/// 桌面端写死在 client.go 的 defaultServer，这里保持一致。
const String kDefaultServer = 'http://111.229.201.94:48081';

/// 默认认证凭据（与服务端 /etc/ntfy/server.yml 的 auth 配置对应）。
const String kDefaultUser = 'admin';
const String kDefaultPass = 'wangchaojun';

/// 应用显示名（窗口标题前缀、首页 AppBar）。
const String kAppName = '密信';

// ---------------------------------------------------------------------------
// ntfy 事件类型
// ---------------------------------------------------------------------------

/// 正常消息。
const String kEventMessage = 'message';

/// 消息被删除（服务端保留字段，客户端用于移除本地记录）。
const String kEventMessageDelete = 'message_delete';

/// 消息被清空。
const String kEventMessageClear = 'message_clear';

/// 连接建立后的第一个事件，不含业务内容，仅用于标记"连接已就绪"。
const String kEventOpen = 'open';

/// 心跳，用于保活（无业务内容）。
const String kEventKeepalive = 'keepalive';

// ---------------------------------------------------------------------------
// since 参数取值
// ---------------------------------------------------------------------------

/// 拉取服务端缓存的全部历史消息。
const String kSinceAll = 'all';

/// 不拉取任何历史消息，只收订阅之后的新消息。
const String kSinceNone = 'none';

// ---------------------------------------------------------------------------
// 优先级
// ---------------------------------------------------------------------------

/// ntfy 优先级范围 1..5，默认 3（中）。
const int kPriorityMin = 1;
const int kPriorityLow = 2;
const int kPriorityDefault = 3;
const int kPriorityHigh = 4;
const int kPriorityUrgent = 5;

const List<int> kAllPriorities = [
  kPriorityMin,
  kPriorityLow,
  kPriorityDefault,
  kPriorityHigh,
  kPriorityUrgent,
];

/// 优先级 -> 中文标签。
String priorityLabel(int p) => switch (p) {
  kPriorityMin => '最低',
  kPriorityLow => '较低',
  kPriorityDefault => '默认',
  kPriorityHigh => '较高',
  kPriorityUrgent => '紧急',
  _ => '默认',
};

// ---------------------------------------------------------------------------
// 附件与消息体上限（与桌面端 client.go 对齐）
// ---------------------------------------------------------------------------

/// 走内存（base64 / 图片粘贴）通道的附件上限：15MB。
const int kMaxAttachmentSize = 15 << 20;

/// 走磁盘路径（流式拷贝）通道的文件上限：1GB。
const int kMaxFileSize = 1 << 30;

/// 收到附件的下载上限：100MB。
const int kMaxDownloadSize = 100 << 20;

/// 同时下载的附件数量上限，避免一次拉到几十条带附件的消息时打满带宽。
const int kMaxConcurrentDownloads = 3;

// ---------------------------------------------------------------------------
// 主题（群聊 ID）校验
// ---------------------------------------------------------------------------

/// ntfy 服务端对 topic 的限制：`^[-_A-Za-z0-9]{1,64}$`。必须与服务端一致，
/// 否则客户端放行、服务端 400，用户只会看到一句无头无尾的报错。
final RegExp kTopicPattern = RegExp(r'^[-_A-Za-z0-9]{1,64}$');

/// 主题不合法时的统一提示文案。
const String kInvalidTopicMessage = '群聊 ID 只能包含字母、数字、- 和 _，长度 1-64';

/// 校验主题是否合法。
bool isValidTopic(String topic) => kTopicPattern.hasMatch(topic);

/// 群聊 ID 长度：桌面端与安卓端创建群聊时都生成 64 字符随机串。
const int kTopicLength = 64;

/// 群聊 ID 允许的字符集（用 SecureRandom 抽取）。
const String kTopicAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
