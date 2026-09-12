/// 密信协议层单元测试。
///
/// 重点覆盖"信封"这套跨端互通的核心逻辑 —— 它决定气泡左右，
/// 一旦出错就是"自己发的消息跑到左边"这种肉眼可见的 bug。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mx/core/constants.dart';
import 'package:mx/core/envelope.dart';
import 'package:mx/core/models.dart';
import 'package:mx/core/ntfy_api.dart';
import 'package:mx/ui/add_group_sheet.dart';

void main() {
  group('信封 pack/unpack', () {
    test('打包后能原样解出正文与标识', () {
      const id = 'aabbccddeeff0011';
      const body = '你好，世界';
      final wire = packMessage(id, body);

      final r = unpackMessage(wire);
      expect(r.isEnvelope, isTrue);
      expect(r.senderId, id);
      expect(r.message, body);
    });

    test('多行正文经信封往返后不丢失换行', () {
      // 附件消息的正文走 X-Message 头，历史上多行正文会被压平而匹配不上；
      // 信封里 JSON 把换行转义成 \n，整条恒为单行，从根上绕开了这个问题。
      const body = '第一行\n第二行\n第三行';
      final wire = packMessage('0011223344556677', body);
      expect(wire.contains('\n'), isFalse, reason: '信封必须是单行');
      expect(unpackMessage(wire).message, body);
    });

    test('标识为空时退化为原文（不阻断发送）', () {
      const body = '未取到标识也要能发';
      final wire = packMessage('', body);
      expect(wire, body);
      expect(unpackMessage(wire).isEnvelope, isFalse);
    });

    test('用户手写的 JSON 正文不会被误吞', () {
      // 这是最容易踩的坑：用户真的可能发一段 JSON。
      const userJson = '{"foo":"bar"}';
      final r = unpackMessage(userJson);
      expect(r.isEnvelope, isFalse);
      expect(r.message, userJson);
    });

    test('含 m 键但 s 不合法时不当作信封', () {
      final r = unpackMessage('{"s":"not-hex","m":"hi"}');
      expect(r.isEnvelope, isFalse);
    });

    test('s 长度不对时不当作信封', () {
      final r = unpackMessage('{"s":"abc","m":"hi"}');
      expect(r.isEnvelope, isFalse);
    });

    test('非 JSON 原样返回', () {
      const plain = '这就是一条普通消息';
      expect(unpackMessage(plain).message, plain);
      expect(unpackMessage(plain).isEnvelope, isFalse);
    });

    test('只有 s 没有 m 键时不当作信封', () {
      const noM = '{"s":"aabbccddeeff0011"}';
      expect(unpackMessage(noM).isEnvelope, isFalse);
    });

    test('剥离信封只取正文', () {
      final wire = packMessage('aabbccddeeff0011', '正文内容');
      expect(stripEnvelope(wire), '正文内容');
      expect(stripEnvelope('普通文本'), '普通文本');
    });
  });

  group('发送方标识校验', () {
    test('合法标识', () {
      expect(isSenderId('0123456789abcdef'), isTrue);
      expect(isSenderId('aabbccddeeff0011'), isTrue);
    });

    test('非法标识', () {
      expect(isSenderId(''), isFalse);
      expect(isSenderId('0123456789abcde'), isFalse); // 15 位
      expect(isSenderId('0123456789abcdef0'), isFalse); // 17 位
      expect(isSenderId('AABBCCDDEEFF0011'), isFalse); // 大写
      expect(isSenderId('ggbbccddeeff0011'), isFalse); // 非十六进制
    });
  });

  group('归属判定', () {
    test('标识一致 → 是我发的', () {
      const me = 'aabbccddeeff0011';
      final wire = packMessage(me, 'hi');
      expect(resolveMineByEnvelope(wire, me), isTrue);
    });

    test('标识不同 → 不是我发的', () {
      final wire = packMessage('1111111111111111', 'hi');
      expect(resolveMineByEnvelope(wire, '2222222222222222'), isFalse);
    });

    test('无信封 → 返回 null，交由调用方走启发式', () {
      expect(resolveMineByEnvelope('普通消息', 'aabbccddeeff0011'), isNull);
    });

    test('本机标识为空时不会误判为自己', () {
      final wire = packMessage('aabbccddeeff0011', 'hi');
      expect(resolveMineByEnvelope(wire, ''), isFalse);
    });
  });

  group('topic 校验', () {
    test('合法 topic', () {
      expect(isValidTopic('abc'), isTrue);
      expect(isValidTopic('a-b_c123'), isTrue);
      expect(isValidTopic('A' * 64), isTrue);
    });

    test('非法 topic', () {
      expect(isValidTopic(''), isFalse);
      expect(isValidTopic('A' * 65), isFalse);
      expect(isValidTopic('has space'), isFalse);
      expect(isValidTopic('has/slash'), isFalse);
      expect(isValidTopic('中文'), isFalse);
    });

    test('生成的群聊 ID 一定合法且长度为 64', () {
      for (var i = 0; i < 20; i++) {
        final id = generateTopicId();
        expect(id.length, kTopicLength);
        expect(isValidTopic(id), isTrue);
      }
    });

    test('生成的发送方标识一定合法', () {
      for (var i = 0; i < 20; i++) {
        expect(isSenderId(generateSenderId()), isTrue);
      }
    });
  });

  group('二维码 payload 解析', () {
    test('mx:// 形式', () {
      final p = parseQrPayload('mx://192.168.1.10:48081/mytopic');
      expect(p, isNotNull);
      expect(p!.server, 'http://192.168.1.10:48081');
      expect(p.topic, 'mytopic');
    });

    test('http 形式', () {
      final p = parseQrPayload('http://example.com:8080/topic1');
      expect(p, isNotNull);
      expect(p!.server, 'http://example.com:8080');
      expect(p.topic, 'topic1');
    });

    test('https 形式', () {
      final p = parseQrPayload('https://ntfy.sh/myalerts');
      expect(p, isNotNull);
      expect(p!.server, 'https://ntfy.sh');
      expect(p.topic, 'myalerts');
    });

    test('纯 topic', () {
      final p = parseQrPayload('justatopic');
      expect(p, isNotNull);
      expect(p!.topic, 'justatopic');
    });

    test('无效内容返回 null', () {
      expect(parseQrPayload(''), isNull);
      expect(parseQrPayload('has space'), isNull);
      expect(parseQrPayload('io.heckel.mx://x'), isNull);
    });

    test('生成的 payload 能被自己解析回来', () {
      final payload = buildQrPayload('http://111.229.201.94:48081', 'abc123');
      final parsed = parseQrPayload(payload);
      expect(parsed, isNotNull);
      expect(parsed!.topic, 'abc123');
      expect(parsed.server, 'http://111.229.201.94:48081');
    });
  });

  group('URL 规范化', () {
    test('补 scheme', () {
      expect(NtfyApi.normalizeBaseUrl('example.com'), 'http://example.com');
    });

    test('去尾部斜杠（多个也要去干净）', () {
      expect(
        NtfyApi.normalizeBaseUrl('https://example.com///'),
        'https://example.com',
      );
    });

    test('空串回落默认服务器', () {
      expect(NtfyApi.normalizeBaseUrl(''), kDefaultServer);
    });

    test('各端点 URL 拼接正确', () {
      const base = 'http://example.com:8080';
      expect(NtfyApi.publishUrl(base, 't1'), 'http://example.com:8080/t1');
      expect(
        NtfyApi.subscribeUrl(base, 't1', 'all'),
        'http://example.com:8080/t1/json?since=all',
      );
      expect(
        NtfyApi.pollUrl(base, 't1', 'none'),
        'http://example.com:8080/t1/json?poll=1&since=none',
      );
    });
  });

  group('HTTP 头安全化', () {
    test('压掉换行与回车', () {
      expect(NtfyApi.headerSafe('a\nb'), 'a b');
      expect(NtfyApi.headerSafe('a\r\nb'), 'a b');
      expect(NtfyApi.headerSafe('a\rb'), 'a b');
    });

    test('压掉 NUL', () {
      expect(NtfyApi.headerSafe('a\x00b'), 'ab');
    });

    test('正常字符串原样返回', () {
      expect(NtfyApi.headerSafe('普通标题'), '普通标题');
    });
  });

  group('消息模型', () {
    test('解析服务端 JSON', () {
      final m = NtfyMessage.fromJson({
        'id': 'abc',
        'time': 1789191281,
        'event': 'message',
        'topic': 't1',
        'title': '标题',
        'message': '正文',
        'priority': 4,
        'tags': ['tag1', 'tag2'],
      });
      expect(m.id, 'abc');
      expect(m.event, kEventMessage);
      expect(m.priority, 4);
      expect(m.tags, ['tag1', 'tag2']);
    });

    test('缺字段时使用安全默认值', () {
      final m = NtfyMessage.fromJson(<String, dynamic>{});
      expect(m.id, '');
      expect(m.time, 0);
      expect(m.attachment, isNull);
    });

    test('带附件的消息能解析出来', () {
      final m = NtfyMessage.fromJson({
        'id': 'x',
        'time': 1,
        'event': 'message',
        'topic': 't',
        'attachment': {
          'name': 'photo.png',
          'type': 'image/png',
          'size': 12345,
          'url': 'http://example.com/photo.png',
        },
      });
      expect(m.attachment, isNotNull);
      expect(m.attachment!.name, 'photo.png');
      expect(m.attachment!.isImage, isTrue);
    });

    test('扩展名兜底判定图片（type 缺失时）', () {
      const att = NtfyAttachment(name: 'x.JPEG');
      expect(att.isImage, isTrue);
    });

    test('视频判定', () {
      const att = NtfyAttachment(name: 'movie.mp4');
      expect(att.isVideo, isTrue);
      expect(att.isImage, isFalse);
    });
  });

  group('优先级', () {
    test('标签映射', () {
      expect(priorityLabel(kPriorityMin), '最低');
      expect(priorityLabel(kPriorityUrgent), '紧急');
      expect(priorityLabel(99), '默认');
    });
  });
}
