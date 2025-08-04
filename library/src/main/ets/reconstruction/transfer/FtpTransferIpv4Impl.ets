import { FtpContext } from "../FtpContext";
import { AbsFtpTransfer, DataSocketOptions } from "./AbsFtpTransfer";

export class FtpTransferIpv4Impl extends AbsFtpTransfer {
  constructor(context: FtpContext) {
    super(context);
  }

  async prepareInternal(): Promise<DataSocketOptions> {
    const pasvResp = await this.context.send("PASV");
    const parsedResp = this.parsePasvResponse(pasvResp.message);
    const controlHost = await this.context.getRemoteAddress().catch(() => undefined);
    // If the host in the PASV response has a local address while the control connection hasn't,
    // we assume a NAT issue and use the IP of the control connection as the target for the data connection.
    // We can't always perform this replacement because it's possible (although unlikely) that the FTP server
    // indeed uses a different host for data connections.
    if (this.ipIsPrivateV4Address(parsedResp[0]) && controlHost && !this.ipIsPrivateV4Address(controlHost.address)) {
      parsedResp[0] = controlHost.address;
    }
    return {
      address: parsedResp[0],
      port: parsedResp[1]
    };
  }

  private parsePasvResponse(message: string): [string, number] {
    // Get host and port from PASV response, e.g. "227 Entering Passive Mode (192,168,1,100,10,229)"
    const groups = message.match(/([-\d]+,[-\d]+,[-\d]+,[-\d]+),([-\d]+),([-\d]+)/);
    if (groups === null || groups.length !== 4) {
      throw new Error(`Can't parse response to 'PASV': ${message}`);
    }
    return [groups[1].replace(/,/g, "."), (parseInt(groups[2], 10) & 255) * 256 + (parseInt(groups[3], 10) & 255)];
  }

  private ipIsPrivateV4Address(ip = ""): boolean {
    // Handle IPv4-mapped IPv6 addresses like ::ffff:192.168.0.1
    if (ip.startsWith("::ffff:")) {
      ip = ip.substr(7); // Strip ::ffff: prefix
    }
    const octets = ip.split(".").map(o => parseInt(o, 10));
    return octets[0] === 10 // 10.0.0.0 - 10.255.255.255
      || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) // 172.16.0.0 - 172.31.255.255
      || (octets[0] === 192 && octets[1] === 168) // 192.168.0.0 - 192.168.255.255
      || ip === "127.0.0.1";
  }
}