import { FtpSocket, MessageSubscriber } from "./FtpSocket";
import { socket } from "@kit.NetworkKit";
import { FtpTlsOptions } from "./FtpTlsOptions";
import { FtpSocketTLSImpl } from "./FtpSocketTLSImpl";
import FtpLogger from "../FtpLogger";
import { FtpUtils } from "../FtpUtils";
import { BusinessError } from "@ohos.base";
import { FtpError } from "../FtpErrors";

const tag = "FtpSocketTCPImpl";

export class FtpSocketTCPImpl implements FtpSocket {
  private sock: socket.TCPSocket | undefined;
  private connectedAddress: string | undefined;
  private connectedPort: number | undefined;
  private messageSubscribers: MessageSubscriber[] = [];
  private closeSubscribers: ((error?: Error) => void)[] = [];
  private closing: Promise<void> | undefined;
  private timeout: number = 0;

  connect(address: string, port: number, timeout: number): Promise<void> {
    return new Promise(async (resolve, reject) => {
      try {
        if (this.sock) {
          await this.sock.close();
        }
        this.sock = socket.constructTCPSocketInstance();
        this.closing = undefined;
        const currentSocket = this.sock;
        this.sock.on("close", async () => {
          FtpLogger.debug(tag, `socket close for ${address}:${port}`);
          if (this.sock !== currentSocket) {
            return;
          }
          try {
            // 对端已结束连接，释放本地描述符后通知读取方 EOF。
            await this.close();
            this.closeSubscribers.slice().forEach(subscriber => subscriber());
          } catch (error) {
            this.closeSubscribers.slice().forEach(subscriber => subscriber(error as Error));
          }
        });
        this.sock.on("error", (err) => {
          reject(err);
          this.closeSubscribers.slice().forEach(subscriber => subscriber(err));
          FtpLogger.error(tag, `socket error for  ${address}:${port}`, err);
        });
        this.sock.on("message", (msg) => {
          this.messageSubscribers.forEach(subscriber => subscriber(msg.message));
        });
        const connectAddress = await FtpUtils.buildNetAddress(address, port);
        await this.sock.bind({
          address: connectAddress.family == 2 ? "::" : "0.0.0.0",
          family: connectAddress.family == 2 ? 2 : 1
        });
        FtpLogger.info(tag, `connect to ${JSON.stringify(connectAddress)}`);
        await this.sock.connect({
          address: connectAddress,
          timeout: timeout ? timeout : 30000
        });
        this.connectedAddress = address;
        this.connectedPort = port;
        this.timeout = timeout;
        await this.sock.setExtraOptions({
          socketTimeout: 0,
          TCPNoDelay: true,
        });
        resolve();
      } catch (e) {
        FtpLogger.error(tag, `connect to [${address}]:${port} failed: ${JSON.stringify(e as BusinessError)}`, e);
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
      throw new FtpError("Invalid socket instance, please wait connect success");
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

  subscribeClose(subscriber: (error?: Error) => void): () => void {
    this.closeSubscribers.push(subscriber);
    return () => {
      const index = this.closeSubscribers.indexOf(subscriber);
      if (index !== -1) {
        this.closeSubscribers.splice(index, 1);
      }
    };
  }

  async close(): Promise<void> {
    if (this.closing !== undefined) {
      await this.closing;
      return;
    }
    const currentSocket = this.sock;
    this.sock = undefined;
    if (currentSocket !== undefined) {
      this.closing = currentSocket.close();
      await this.closing;
    }
  }

  useTls(options: FtpTlsOptions): FtpSocket {
    const transport = this.sock;
    // 升级后连接由 TLS 实例独占，TCP 的迟到关闭事件不能再次释放同一个描述符。
    this.sock = undefined;
    return new FtpSocketTLSImpl(options, transport);
  }

  hasTls(): boolean {
    return false;
  }

  async getRemoteAddress(): Promise<socket.NetAddress | undefined> {
    return this.sock?.getRemoteAddress();
  }
}
