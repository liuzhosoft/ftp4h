import { connection, socket } from "@kit.NetworkKit";
import { deviceInfo } from "@kit.BasicServicesKit";

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

  static async buildNetAddress(address: string, port: number): Promise<socket.NetAddress> {
    let isIpv6 = FtpUtils.isIPv6(address);
    let isIpv4 = FtpUtils.isIPv4(address);
    if (!isIpv6 && !isIpv4) {
      address = (await connection.getDefaultNet()
        .then((net) => net.getAddressesByName(address))
        .then((addresses) => {
          return addresses.find(e => !FtpUtils.isDNSFailureDefaultIP(e.address));
        }).catch(() => undefined))?.address ?? address;
      isIpv6 = FtpUtils.isIPv6(address);
      isIpv4 = FtpUtils.isIPv4(address);
    }
    return {
      address: address,
      port: port,
      family: isIpv6 ? 2 : (isIpv4 ? 1 : (deviceInfo.sdkApiVersion >= 18 ? 3 : 1)),
    };
  }

  /**
   * 判断IP地址是否是DNS解析失败时返回的默认地址
   * @param ip IP地址字符串（IPv4或IPv6）
   * @returns 如果是DNS解析失败的默认地址返回true，否则返回false
   */
  static isDNSFailureDefaultIP(ip: string): boolean {
    if (!FtpUtils.isValidIP(ip)) {
      return false;
    }

    if (ip.includes(".")) {
      return FtpUtils.isDNSFailureIPv4(ip);
    } else if (ip.includes(":")) {
      return FtpUtils.isDNSFailureIPv6(ip);
    }

    return false;
  }

  /**
   * 验证IP地址格式是否正确
   */
  private static isValidIP(ip: string): boolean {
    // IPv4验证
    const ipv4Regex = /^(\d{1,3}\.){3}\d{1,3}$/;
    if (ipv4Regex.test(ip)) {
      const parts = ip.split(".").map(Number);
      return parts.every(part => part >= 0 && part <= 255);
    }

    // IPv6验证
    const ipv6Regex =
      /^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::1$|^::$|^([0-9a-fA-F]{1,4}:){1,7}:$|^([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}$|^([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}$|^([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}$|^([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}$|^([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}$|^[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})$|^:((:[0-9a-fA-F]{1,4}){1,7}|:)$/;
    return ipv6Regex.test(ip);
  }

  /**
   * 判断IPv4地址是否是DNS解析失败的默认地址
   */
  private static isDNSFailureIPv4(ip: string): boolean {
    const parts = ip.split(".").map(Number);
    const a = parts[0];
    const b = parts[1];
    const c = parts[2];
    const d = parts[3];

    // 常见的DNS解析失败默认地址
    const dnsFailureIPs = [
    // 环回地址（常见于本地测试）
      "127.0.0.1",

      // IANA保留的测试地址（dnsmasq等常用）
      "192.0.2.1", // TEST-NET-1
      "198.51.100.1", // TEST-NET-2
      "203.0.113.1", // TEST-NET-3
      "198.18.0.6", // 基准测试地址（你遇到的）
      "198.19.255.254", // 基准测试地址范围

      // 零地址（某些DNS软件使用）
      "0.0.0.0",

      // 广播地址（极少使用）
      "255.255.255.255",

      // 常见的占位地址
      "1.1.1.1", // 有时被用作占位
      "8.8.8.8",// 有时被用作占位
    ];

    // 检查精确匹配
    if (dnsFailureIPs.includes(ip)) {
      return true;
    }

    // 检查地址段匹配
    if (a === 192 && b === 0 && c === 2) {
      return true;
    } // 192.0.2.0/24
    if (a === 198 && b === 51 && c === 100) {
      return true;
    } // 198.51.100.0/24
    if (a === 203 && b === 0 && c === 113) {
      return true;
    } // 203.0.113.0/24
    if (a === 198 && b >= 18 && b <= 19) {
      return true;
    } // 198.18.0.0/15

    return false;
  }

  /**
   * 判断IPv6地址是否是DNS解析失败的默认地址
   */
  private static isDNSFailureIPv6(ip: string): boolean {
    const normalizedIP = FtpUtils.normalizeIPv6(ip);

    // 常见的DNS解析失败默认地址
    const dnsFailureIPs = [
    // 环回地址
      "::1",

      // 未指定地址
      "::",

      // 文档示例地址
      "2001:db8::1",
      "2001:db8:85a3::8a2e:370:7334",

      // 基准测试地址
      "2001:2::1",

      // ORCHID地址
      "2001:10::1",

      // 零地址变体
      "0:0:0:0:0:0:0:0",
      "0000:0000:0000:0000:0000:0000:0000:0000"
    ];

    // 检查精确匹配
    if (dnsFailureIPs.includes(normalizedIP) || dnsFailureIPs.includes(ip)) {
      return true;
    }

    // 检查地址段匹配
    if (normalizedIP.startsWith("2001:0db8:")) {
      return true;
    } // 2001:db8::/32
    if (normalizedIP.startsWith("2001:0002:")) {
      return true;
    } // 2001:2::/48
    if (normalizedIP.startsWith("2001:0010:")) {
      return true;
    } // 2001:10::/28

    return false;
  }

  /**
   * 标准化IPv6地址为完整格式
   */
  private static normalizeIPv6(ip: string): string {
    if (ip.includes("::")) {
      const parts = ip.split("::");
      const leftParts = parts[0] ? parts[0].split(":") : [];
      const rightParts = parts[1] ? parts[1].split(":") : [];

      const missingZeros = 8 - leftParts.length - rightParts.length;
      const zeros = Array(missingZeros).fill("0000");

      const allParts = [...leftParts, ...zeros, ...rightParts];
      ip = allParts.join(":");
    }

    const parts = ip.split(":");
    const normalizedParts = parts.map(part => part.padStart(4, "0"));
    return normalizedParts.join(":");
  }
}