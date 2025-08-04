export class FtpUtils {
  /**
   * 判断字符串是否为有效的IPv6地址
   * @param ip 输入的IP地址字符串
   * @returns 是否是IPv6地址
   */
  static isIPv6(ip: string): boolean {
    // 匹配标准 IPv6 格式（包括压缩格式 ::）
    const ipv6Regex = /^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$/; // 完整格式
    const ipv6CompressedRegex =
      /^(([0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4})?::(([0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4})?$/; // 允许 ::
    const ipv4MappedRegex = /^::ffff:(\d{1,3}\.){3}\d{1,3}$/; // IPv4 映射地址（::ffff:192.168.1.1）

    return ipv6Regex.test(ip) || ipv6CompressedRegex.test(ip) || ipv4MappedRegex.test(ip);
  }

  /**
   * 判断字符串是否为有效的IPv4地址
   * @param ip 输入的IP地址字符串
   * @returns 是否是IPv4地址
   */
  static isIPv4(ip: string): boolean {
    // IPv4正则表达式（严格匹配0-255的四个十进制数）
    const ipv4Regex =
      /^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/;
    return ipv4Regex.test(ip);
  }
}