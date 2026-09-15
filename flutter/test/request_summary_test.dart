import 'package:companion/domain.dart';
import 'package:companion/main.dart';
import 'package:flutter_test/flutter_test.dart';

PendingRequest request(String tool, Map<String, dynamic> args) =>
    PendingRequest(id: 'r', tool: tool, kind: 'permission', args: args);

void main() {
  group('summarizeRequest', () {
    test('shows the command itself for shell tools', () {
      final summary = summarizeRequest(
        request('Bash', {'command': 'npm run build', 'cwd': '/work/app'}),
      );

      expect(summary.headline, 'npm run build');
      expect(summary.details, contains(('工作目录', '/work/app')));
      expect(summary.dangerous, isFalse);
    });

    test('flags destructive commands so the confirm button is not clicked blindly', () {
      for (final command in [
        'rm -rf node_modules',
        'sudo rm /etc/hosts',
        'git push --force origin main',
        'git reset --hard HEAD~3',
        'dd if=/dev/zero of=/dev/disk2',
      ]) {
        expect(
          summarizeRequest(request('Bash', {'command': command})).dangerous,
          isTrue,
          reason: command,
        );
      }

      // 普通命令不应被误标成危险。
      expect(
        summarizeRequest(request('Bash', {'command': 'git push origin main'}))
            .dangerous,
        isFalse,
      );
      expect(
        summarizeRequest(request('Bash', {'command': 'rm build.log'})).dangerous,
        isFalse,
      );
    });

    test('reduces file tools to a path plus change size', () {
      final summary = summarizeRequest(
        request('Write', {
          'file_path': '/work/app/main.dart',
          'content': 'a\nb\nc',
        }),
      );

      expect(summary.headline, '/work/app/main.dart');
      expect(summary.details, contains(('写入内容', '3 行')));
    });

    test('shows the target address for network tools', () {
      final summary = summarizeRequest(
        request('WebFetch', {'url': 'https://example.com/spec'}),
      );

      expect(summary.headline, 'https://example.com/spec');
    });

    test('never dumps raw JSON for unknown tools', () {
      final summary = summarizeRequest(
        request('Mystery', {'alpha': 1, 'beta': 'two'}),
      );

      // 退化成键值对而不是一屏 JSON。
      expect(summary.headline, contains('Mystery'));
      expect(summary.headline, isNot(contains('{')));
      expect(summary.details, containsAll([('alpha', '1'), ('beta', 'two')]));
    });

    test('falls back to a readable line when arguments are empty', () {
      final summary = summarizeRequest(request('Bash', const {}));

      expect(summary.headline, '执行一条命令');
      expect(summary.dangerous, isFalse);
    });
  });
}
