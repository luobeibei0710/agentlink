import 'package:companion/domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('context line reports the last request, not the cumulative session total', () {
    // 真实数据：会话累计输入 69.8M，窗口 258.4k。用累计值会得出 27027%，
    // 这个百分比没有任何参考价值 —— 所以必须取本轮用量（75.3k → 29%）。
    final label = formatTokenCountLabel({
      'info': {
        'total': {
          'inputTokens': 69837745,
          'outputTokens': 204974,
          'cachedInputTokens': 67960832,
          'reasoningOutputTokens': 46956,
        },
        'last': {'inputTokens': 75293, 'outputTokens': 10, 'cachedInputTokens': 7040},
        'modelContextWindow': 258400,
      },
    });

    expect(label, contains('Context 75.3k / 258.4k (29%)'));
    // out / cached / reasoning 表达的是会话至今的消耗，仍是累计口径。
    expect(label, contains('out 205.0k'));
    expect(label, contains('cached 68.0M'));
    expect(label, contains('reasoning 47.0k'));
  });

  test('context line falls back to the cumulative total when there is no last snapshot', () {
    final label = formatTokenCountLabel({
      'info': {
        'total': {'inputTokens': 1000, 'outputTokens': 10},
        'modelContextWindow': 2000,
      },
    });

    expect(label, contains('Context 1k / 2k (50%)'));
  });

  test('rate limits accept either key style and convert seconds to milliseconds', () {
    final limits = RateLimits.fromJson({
      'primary': {
        'used_percent': 99,
        'window_minutes': 10080,
        'resets_at': 1789819456,
      },
      'plan_type': 'pro',
      'credits': {'has_credits': false},
    }, 1234);

    expect(limits, isNotNull);
    expect(limits!.planType, 'pro');
    expect(limits.hasCredits, isFalse);
    expect(limits.primary!.usedPercent, 99.0);
    expect(limits.primary!.windowMinutes, 10080);
    // Codex 给的是秒；不换算会显示成 1970 年。
    expect(limits.primary!.resetsAt, 1789819456000);
  });

  test('a limit payload without any usable field is rejected', () {
    // Codex 平时只推一个空壳（primary/secondary 全是 null），此时不该占据额度卡。
    expect(RateLimits.fromJson({'limit_id': 'premium'}, 1), isNull);
    expect(RateLimits.fromJson(null, 1), isNull);
    expect(RateLimits.fromJson(const <String, dynamic>{}, 1), isNull);
  });
}
