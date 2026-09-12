/// 首页：群聊列表 / 聊天/ 设置的主容器。
///
/// 布局参照桌面端 App.vue：单一聊天页 + 顶部群聊下拉切换 + 若干弹窗。
/// 手机上就是标准的两页结构（列表 → 聊天），桌面/Web 上同一个页面自适应加宽。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/hub.dart';
import '../core/store.dart';
import 'add_group_sheet.dart';
import 'chat_page.dart';
import 'group_list_page.dart';
import 'settings_page.dart';

/// "全部消息"伪主题的哨兵值。
const String kAllTopics = '__all__';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.hub, required this.store});

  final Hub hub;
  final Store store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<SubRec> _subs = [];
  Map<String, String> _aliases = {};
  Map<String, SubState> _states = {};
  String _activeTopic = kAllTopics;
  bool _loading = true;
  bool _isWide = false;

  StreamSubscription<SubStateEvent>? _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.hub.onState.listen((e) {
      if (!mounted) return;
      setState(() {
        _states[e.subId] = e.state;
      });
    });
    _refresh();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final subs = widget.hub.listSubs();
    final aliases = await widget.store.listAliases();
    final last = await widget.store.getLastTopic();
    final states = <String, SubState>{};
    for (final s in subs) {
      states[s.id] = widget.hub.stateOf(s.server, s.topic);
    }
    if (!mounted) return;
    setState(() {
      _subs = subs;
      _aliases = aliases;
      _states = states;
      _loading = false;
      if (last.isNotEmpty &&
          (last == kAllTopics || subs.any((s) => s.topic == last))) {
        _activeTopic = last;
      } else if (subs.isNotEmpty && _activeTopic == kAllTopics) {
        // 保持"全部消息"，这是信息量最大的默认视图
        _activeTopic = kAllTopics;
      }
    });
  }

  /// 群聊显示名：有别名用别名，否则显示群聊 id 前 8 位（避免露出 64 位长串）。
  String displayName(String topic) {
    if (topic == kAllTopics) return '全部消息';
    final alias = _aliases[topic];
    if (alias != null && alias.isNotEmpty) return alias;
    if (topic.isEmpty) return '未知群聊';
    return topic.length > 10 ? '${topic.substring(0, 10)}…' : topic;
  }

  Future<void> _pickTopic(String topic) async {
    setState(() {
      _activeTopic = topic;
    });
    await widget.store.setLastTopic(topic);
  }

  @override
  Widget build(BuildContext context) {
    _isWide = MediaQuery.of(context).size.width >= 720;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽屏（桌面 / Web / 平板）：左侧群聊列表常驻，右侧聊天
        if (constraints.maxWidth >= 720) {
          return Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 260,
                  child: GroupListPage(
                    subs: _subs,
                    aliases: _aliases,
                    states: _states,
                    activeTopic: _activeTopic,
                    displayName: displayName,
                    onPick: _pickTopic,
                    onAdd: () => _openAddGroup(context),
                    onSettings: () => _openSettings(context),
                    embedded: true,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildChat()),
              ],
            ),
          );
        }

        // 窄屏（手机）：列表页 → 聊天页
        if (_activeTopic == kAllTopics || _subs.isEmpty) {
          return Scaffold(
            body: GroupListPage(
              subs: _subs,
              aliases: _aliases,
              states: _states,
              activeTopic: _activeTopic,
              displayName: displayName,
              onPick: (t) async {
                await _pickTopic(t);
              },
              onAdd: () => _openAddGroup(context),
              onSettings: () => _openSettings(context),
              embedded: false,
            ),
          );
        }
        return _buildChat();
      },
    );
  }

  Widget _buildChat() {
    if (_subs.isEmpty) {
      return Scaffold(
        appBar: _buildAppBar(),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('💬', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              const Text('还没有群聊', style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _openAddGroup(context),
                child: const Text('创建或加入一个群聊'),
              ),
            ],
          ),
        ),
      );
    }
    return ChatPage(
      key: ValueKey('chat-$_activeTopic-${_subs.length}'),
      hub: widget.hub,
      store: widget.store,
      subs: _subs,
      aliases: _aliases,
      activeTopic: _activeTopic,
      displayName: displayName,
      onPickTopic: _pickTopic,
      onSubsChanged: _refresh,
      onOpenSettings: () => _openSettings(context),
      onOpenAddGroup: () => _openAddGroup(context),
      wide: _isWide,
      onBack: _isWide
          ? null
          : () async {
              await _pickTopic(kAllTopics);
            },
      onRefreshAll: _refresh,
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(title: const Text(kAppName));
  }

  Future<void> _openAddGroup(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddGroupSheet(hub: widget.hub, store: widget.store),
    );
    await _refresh();
  }

  Future<void> _openSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SettingsSheet(
        hub: widget.hub,
        store: widget.store,
        displayName: displayName,
        activeTopic: _activeTopic == kAllTopics ? null : _activeTopic,
      ),
    );
    await _refresh();
  }
}
