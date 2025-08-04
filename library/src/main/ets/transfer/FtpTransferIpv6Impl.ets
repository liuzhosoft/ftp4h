import { AbsFtpTransfer, DataSocketOptions } from "./AbsFtpTransfer";

export class FtpTransferIpv6Impl extends AbsFtpTransfer {
  async prepareInternal(): Promise<DataSocketOptions> {
    const resp = await this.context.send("EPSV");
    const port = this.parseEpsvResponse(resp.message);
    if (!port) {
      throw new Error(`can't parse EPSV response: ${resp.message}`);
    }
    const controlHost = await this.context.getRemoteAddress().catch(() => undefined);
    if (!controlHost) {
      throw new Error("get controlHost failed");
    }
    return {
      address: controlHost.address,
      port: port
    };
  }

  private parseEpsvResponse(message: string): number {
    // Get port from EPSV response, e.g. "229 Entering Extended Passive Mode (|||6446|)"
    // Some FTP Servers such as the one on IBM i (OS/400) use ! instead of | in their EPSV response.
    const groups = message.match(/[|!]{3}(.+)[|!]/);
    if (groups === null || groups[1] === undefined) {
      throw new Error(`Can't parse response to 'EPSV': ${message}`);
    }
    const port = parseInt(groups[1], 10);
    if (Number.isNaN(port)) {
      throw new Error(`Can't parse response to 'EPSV', port is not a number: ${message}`);
    }
    return port;
  }
}