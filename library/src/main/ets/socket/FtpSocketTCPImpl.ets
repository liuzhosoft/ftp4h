import { FtpSocket, MessageSubscriber } from "./FtpSocket";
import { socket } from "@kit.NetworkKit";
import { FtpTlsOptions } from "./FtpTlsOptions";
import { FtpSocketTLSImpl } from "./FtpSocketTLSImpl";
import FtpLogger from "../FtpLogger";
import { FtpUtils } from "../FtpUtils";
import { BusinessError } from "@ohos.base";
import deviceInfo from "@ohos.deviceInfo";

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