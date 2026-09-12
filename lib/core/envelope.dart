/// 消息信封（envelope）—— 全平台互通的"谁是发送者"判据。
///
/// ## 为什么需要它
///
/// ntfy 是个纯广播协议：服务端把消息原样推给所有订阅者，**不带发送者身份**。
/// 于是"这条消息是不是我自己发的"（决定气泡靠左还是靠右）就没法从协议层直接判断。
///
/// 早期实现靠启发式猜测：同主题 + 同标题 + 同正文 + 30 秒时间窗。这套逻辑在
/// "连发两条一样的话"或"服务器时钟偏差"时会误判。
///
/// 现在的做法：发送时把正文外面套一层 JSON 信封
///
/// ```json
/// {"s":"aabbccddeeff0011","m":"用户真正输入的正文"}
/// ```
///
/// `s` 是发送方 16 位十六进制标识（每份安装首次运行生成一次并持久化），
/// `m` 是用户原文。接收端比对 `s` 与自己的标识即可**权威判定**归属，
/// 不猜、不依赖时钟。信封只存在于传输层：落库与上屏前都会被剥掉。
///
/// ## 兼容性
///
/// - 无信封（服务器历史消息、或对方还在用旧版客户端）→ 退回启发式判定。
/// - 信封必须是"JSON 对象且含 m 键且 s 形态合法"，否则当普通正文原样显示，
///   避免把用户手写的 JSON 正文误吞。
///
/// Android 端见 NotificationParser.unwrapEnvelope()，
/// 桌面端见 sender.go 的 packMessage / unpackMessage。
library;

import 'dart:convert';

/// 发送方标识长度：8 字节随机数 -> 16 个十六进制字符。
///
/// 这个长度同时用作"这条消息是否为信封"的形状判据 —— 够严格才不会把
/// 用户手写的 JSON 正文误判成信封。
const int kSenderIdHexLen = 16;

/// 判断字符串是否是合法的发送方标识（16 位小写十六进制）。
bool isSenderId(String s) {
  if (s.length != kSenderIdHexLen) return false;
  for (final code in s.codeUnits) {
    final isDigit = code >= 0x30 && code <= 0x39; // 0-9
    final isLowerHex = code >= 0x61 && code <= 0x66; // a-f
    if (!isDigit && !isLowerHex) return false;
  }
  return true;
}

/// 打包线格式：把正文套进信封。
///
/// [senderId] 为空时原样返回正文（退化为旧格式）—— 标识取不到不该阻断发送。
String packMessage(String senderId, String message) {
  if (senderId.isEmpty) return message;
  return jsonEncode({'s': senderId, 'm': message});
}

/// 解包结果。三态：
/// - [isEnvelope] == true  → 解包成功，[senderId] / [message] 有效
/// - [isEnvelope] == false → 这条不是信封，[message] 是原始正文，按旧格式处理
class UnpackResult {
  const UnpackResult({
    required this.isEnvelope,
    required this.senderId,
    required this.message,
  });

  final bool isEnvelope;
  final String senderId;
  final String message;

  /// 非信封：原文照旧。
  const UnpackResult.plain(this.message)
    : isEnvelope = false,
      senderId = '';
}

/// 尝试解出信封。
///
/// 判定条件是三重严格校验，任一条不满足就当作普通正文：
/// 1. 首尾必须是 `{` / `}`（快速预筛，避免对每条普通消息都跑 JSON 解析）
/// 2. 必须能解析成 JSON **对象**，且含 `m` 键
/// 3. `s` 必须是合法的 16 位十六进制标识
UnpackResult unpackMessage(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return UnpackResult.plain(raw);
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return UnpackResult.plain(raw);
    if (!decoded.containsKey('m')) return UnpackResult.plain(raw);
    final sender = decoded['s'];
    final body = decoded['m'];
    if (sender is! String || !isSenderId(sender)) {
      return UnpackResult.plain(raw);
    }
    // m 允许为 null（老客户端可能发 {"s":..,"m":null}），归一化成空串
    return UnpackResult(
      isEnvelope: true,
      senderId: sender,
      message: body is String ? body : '',
    );
  } on FormatException {
    // 不是合法 JSON：用户手写的 `{...}` 正文会走到这里，原样保留
    return UnpackResult.plain(raw);
  }
}

/// 剥离信封，只取正文。发送/落库/上屏的统一入口。
String stripEnvelope(String raw) => unpackMessage(raw).message;

/// 判定一条回流消息是否为本端所发。
///
/// 带信封 → 以标识为准（权威，不存在假阳性）；
/// 无信封 → 返回 null，调用方应退回启发式判定（历史消息 / 旧版客户端）。
bool? resolveMineByEnvelope(String raw, String mySenderId) {
  final r = unpackMessage(raw);
  if (!r.isEnvelope) return null;
  return mySenderId.isNotEmpty && r.senderId == mySenderId;
}
