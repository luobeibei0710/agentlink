import 'domain.dart';

/// A QR is untrusted input: validate an origin before displaying or connecting.
class PairingTarget {
  const PairingTarget(this.uri, this.code);
  final Uri uri;
  final String code;
  bool get isLan => uri.scheme == 'http';

  static bool isLanHttp(Uri uri) =>
      uri.scheme == 'http' && _privateIPv4(uri.host);

  static bool _privateIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
      final value = int.parse(part);
      if (value > 255) return false;
      octets.add(value);
    }
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  static Uri parseHub(String raw) {
    try {
      final value = raw.trim();
      final source = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      if (source.host.isEmpty ||
          source.userInfo.isNotEmpty ||
          source.hasQuery ||
          source.hasFragment ||
          (source.path.isNotEmpty && source.path != '/') ||
          source.port < 1 ||
          source.port > 65535) {
        throw HubException('Hub 必须是完整根地址，不含路径、账号或查询参数');
      }
      if (source.scheme != 'https' && !isLanHttp(source)) {
        throw HubException(
          'HTTP 仅支持局域网 IPv4 地址（10.x、172.16–31.x、192.168.x）；外网请使用 HTTPS',
        );
      }
      return Uri(
        scheme: source.scheme,
        host: source.host.toLowerCase(),
        port: source.port == (source.scheme == 'https' ? 443 : 80)
            ? null
            : source.port,
      );
    } on FormatException {
      throw HubException('Hub 地址格式无效');
    }
  }

  static PairingTarget parseLink(String text) {
    try {
      final raw = text.trim();
      if (raw.length > 16384 || RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(raw)) {
        throw HubException('配对二维码格式无效');
      }
      final link = Uri.parse(raw);
      if (link.scheme != 'hapicompanion' ||
          link.host != 'bind' ||
          link.path.isNotEmpty ||
          link.userInfo.isNotEmpty ||
          link.hasPort ||
          link.hasFragment) {
        throw HubException('请扫描电脑端生成的 AgentLink 配对二维码');
      }
      final values = link.queryParametersAll;
      if (values['hub']?.length != 1 ||
          values['code']?.length != 1 ||
          values['code']!.single.trim().isEmpty) {
        throw HubException('配对链接缺少唯一的 Hub 地址或配对码');
      }
      return PairingTarget(
        parseHub(values['hub']!.single),
        values['code']!.single.trim(),
      );
    } on FormatException {
      throw HubException('配对二维码格式无效');
    }
  }
}
