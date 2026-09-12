/// 群聊列表页。
///
/// 宽屏时以侧栏形式常驻，窄屏时占满整屏（手机的主界面）。
library;

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/hub.dart';
import '../core/ntfy_api.dart';
import '../core/store.dart';
import 'home_page.dart' show kAllTopics;
import 'theme.dart';

class GroupListPage extends StatelessWidget {
  const GroupListPage({
    super.key,
    required this.subs,
    required this.aliases,
    required this.states,
    required this.activeTopic,
    required this.displayName,
    required this.onPick,
    required this.onAdd,
    required this.onSettings,
    this.embedded = false,
  });

  final List<SubRec> subs;
  final Map<String, String> aliases;
  final Map<String, SubState> states;
  final String activeTopic;
  final String Function(String) displayName;
  final ValueChanged<String> onPick;
  final VoidCallback onAdd;
  final VoidCallback onSettings;

  /// 侧栏模式（宽屏）：不显示顶部大标题栏的返回按钮等。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F7),
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      kAppName,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '创建或加入群聊',
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  IconButton(
                    tooltip: '设置',
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                // "全部消息"入口：只在有群聊时出现（没群聊时它就是空的）
                if (subs.isNotEmpty)
                  _Tile(
                    icon: '💬',
                    iconColor: const Color(0xFF9E9E9E),
                    title: '全部消息',
                    subtitle: '按时间汇总所有群聊',
                    selected: activeTopic == kAllTopics,
                    onTap: () => onPick(kAllTopics),
                  ),
                if (subs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 48,
                    ),
                    child: Column(
                      children: [
                        const Text('💬', style: TextStyle(fontSize: 44)),
                        const SizedBox(height: 14),
                        const Text(
                          '还没有群聊',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '创建一个群聊，把群聊 ID 分享给同伴即可开始聊天',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: onAdd,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('创建群聊'),
                          style: FilledButton.styleFrom(
                            backgroundColor: kBrandGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final s in subs)
                  _Tile(
                    icon: avatarFor(s.topic).emoji,
                    iconColor: avatarFor(s.topic).color,
                    title: displayName(s.topic),
                    subtitle: _subtitleFor(s),
                    trailing: _StatusDot(
                      state: states[s.id] ?? SubState.stopped,
                    ),
                    selected: activeTopic == s.topic,
                    onTap: () => onPick(s.topic),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _subtitleFor(SubRec s) {
    final st = states[s.id];
    final where = NtfyApi.normalizeBaseUrl(s.server).replaceFirst('http://', '').replaceFirst('https://', '');
    return switch (st) {
      SubState.connected => '已连接 · $where',
      SubState.connecting => '连接中 · $where',
      SubState.reconnecting => '重连中 · $where',
      _ => where,
    };
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? (isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE3E3E3))
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: iconColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(icon, style: const TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 连接状态指示灯：绿=已连接，黄=连接中，红=重连中。
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.state});

  final SubState state;

  @override
  Widget build(BuildContext context) {
    final (color, tip) = switch (state) {
      SubState.connected => (kBrandGreen, '已连接'),
      SubState.connecting => (Colors.orange, '连接中'),
      SubState.reconnecting => (Colors.redAccent, '重连中'),
      SubState.stopped => (Colors.grey, '未连接'),
    };
    return Tooltip(
      message: tip,
      child: Container(
        width: 9,
        height: 9,
        margin: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
