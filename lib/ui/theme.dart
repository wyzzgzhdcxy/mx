/// 视觉风格：贴近微信的群聊观感。
///
/// 颜色与桌面端 App.vue 的调色板保持一致（我方气泡 #95ec69 系、对方白底、
/// 主色 #07c160），让三端看起来是同一个产品。
library;

import 'package:flutter/material.dart';

/// 品牌主色（微信绿）。
const Color kBrandGreen = Color(0xFF07C160);

/// 我方气泡背景。
const Color kBubbleMine = Color(0xFF95EC69);

/// 对方气泡背景（浅色模式）。
const Color kBubbleOther = Color(0xFFFFFFFF);

/// 聊天区背景（浅色模式）。
const Color kChatBg = Color(0xFFEDEDED);

/// 深色模式下的气泡与背景。
const Color kBubbleMineDark = Color(0xFF3EB575);
const Color kBubbleOtherDark = Color(0xFF2C2C2E);
const Color kChatBgDark = Color(0xFF111111);

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrandGreen,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? kChatBgDark : kChatBg,
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F7),
      foregroundColor: isDark ? Colors.white : Colors.black87,
      elevation: 0.5,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : Colors.black87,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF2C2C2E) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      isDense: true,
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? Colors.white12 : Colors.black12,
      space: 1,
      thickness: 0.5,
    ),
  );
}

/// 群聊头像：用主题 id 派生一个稳定的颜色 + emoji，加个辨识度。
class AvatarStyle {
  const AvatarStyle(this.emoji, this.color);

  final String emoji;
  final Color color;
}

const List<String> _avatarEmojis = [
  '🐱', '🐶', '🦊', '🐼', '🐨', '🦁', '🐯', '🐮',
  '🐷', '🐸', '🐵', '🐔', '🦉', '🦄', '🐙', '🦋',
];

const List<Color> _avatarColors = [
  Color(0xFF5B8FF9), Color(0xFF5AD8A6), Color(0xFF5D7092), Color(0xFFF6BD16),
  Color(0xFF6DC8EC), Color(0xFF945FB9), Color(0xFFFF9845), Color(0xFF1E9493),
  Color(0xFFE8684A), Color(0xFF6DC8EC), Color(0xFF9270CA), Color(0xFFFF9D4B),
];

/// 由主题 id 派生稳定头像（同一群聊永远同一图标，多端一致）。
AvatarStyle avatarFor(String topic) {
  if (topic.isEmpty) {
    return const AvatarStyle('💬', Color(0xFF9E9E9E));
  }
  var hash = 0;
  for (final code in topic.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return AvatarStyle(
    _avatarEmojis[hash % _avatarEmojis.length],
    _avatarColors[(hash ~/ 7) % _avatarColors.length],
  );
}

/// 时间格式化：聊天气泡之间插入的分隔标签。
String formatMessageTime(int unixSeconds) {
  if (unixSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  final hm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  final diffDays = today.difference(that).inDays;
  if (diffDays == 0) return hm;
  if (diffDays == 1) return '昨天 $hm';
  if (diffDays == 2) return '前天 $hm';
  if (dt.year == now.year) {
    return '${dt.month}月${dt.day}日 $hm';
  }
  return '${dt.year}年${dt.month}月${dt.day}日 $hm';
}

/// 通用时间（用于列表、设置页）。
String formatDateTime(int unixSeconds) {
  if (unixSeconds <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  return '${dt.year}-${_pad2(dt.month)}-${_pad2(dt.day)} '
      '${_pad2(dt.hour)}:${_pad2(dt.minute)}';
}

/// 两位补零。
String _pad2(int v) => v.toString().padLeft(2, '0');

/// 人类可读的文件大小。
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(decimals)} ${units[i]}';
}
