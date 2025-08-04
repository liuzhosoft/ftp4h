import { FtpSocket, MessageSubscriber } from "./FtpSocket";
import { socket } from "@kit.NetworkKit";
import { FtpTlsOptions } from "./FtpTlsOptions";
import { FtpSocketTLSImpl } from "./FtpSocketTLSImpl";
import FtpLogger from "../FtpLogger";
import { FtpUtils } from "../FtpUtils";

const tag = "FtpSocketTCPImpl";

export class FtpSocketTCPImpl implements FtpSocket {
  private sock: socket.TCPSocket | undefined;
  private connectedAddress: string | undefined;
  private connectedPort: number | undefined;
  private messageSubscribers: MessageSubscriber[] = [];
  private timeout: number = 0;

  connect(address: string, port: number, timeout: number): Promise<void> {
    return new Promise(async (resolve, reject) => {
      try {
        if (this.sock) {
          await this.sock.close();
        }
        this.sock = socket.constructTCPSocketInstance();
        this.sock.on("close", () => {
          FtpLogger.debug(tag, `socket close for ${address}:${port}`);
          this.sock = undefined;
        });
        this.sock.on("error", (err) => {
          reject(err);
          FtpLogger.error(tag, `socket error for  ${address}:${port}`, err);
        });
        this.sock.on("message", (msg) => {
          this.messageSubscribers.forEach(subscriber => subscriber(msg.message));
        });
        const isIpv6 = FtpUtils.isIPv6(address);
        const isIpv4 = FtpUtils.isIPv4(address);
        await this.sock.bind({ address: isIpv6 ? "::" : "0.0.0.0", family: isIpv6 ? 2 : 1 });
        const netAddress: socket.NetAddress = { address: address, port: port, family: isIpv6 ? 2 : isIpv4 ? 1 : 3 };
        FtpLogger.debug(tag, `connect to ${JSON.stringify(netAddress)}`);
        await this.sock.connect({
          address: netAddress,
          timeout: timeout ? timeout : 30000
        });
        this.connectedAddress = address;
        this.connectedPort = port;
        this.timeout = timeout;
        this.sock.setExtraOptions({
          socketTimeout: 0
        });
        resolve();
      } catch (e) {
        reject(e);
      }
    });
  }

  async isConnected(): Promise<boolean> {
    const state = await this.sock?.getState();
    FtpLogger.debug(tag, `socketState = ${JSON.stringify(state)}`);
    return this.sock != undefined && (await this.sock.getState()).isConnected;
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    if (!this.sock || !this.connectedAddress || !this.connectedPort) {
      throw new Error("Invalid socket instance, please wait connect success");
    }
    return this.sock.send({ data: data });
  }

  subscribeMessage(subscriber: MessageSubscriber): () => void {
    this.messageSubscribers.push(subscriber);
    return () => {
      const index = this.messageSubscribers.indexOf(subscriber);
      if (index != -1) {
        this.messageSubscribers.splice(index, 1);
      }
    };
  }

  async close(): Promise<void> {
    await this.sock?.close();
  }

  useTls(options: FtpTlsOptions): FtpSocket {
    return new FtpSocketTLSImpl(options, this.sock);
  }

  hasTls(): boolean {
    return false;
  }

  async getRemoteAddress(): Promise<socket.NetAddress | undefined> {
    return this.sock?.getRemoteAddress();
  }
}