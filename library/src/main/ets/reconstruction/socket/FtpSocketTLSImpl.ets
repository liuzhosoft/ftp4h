import { FtpSocket, MessageSubscriber } from "./FtpSocket";
import { socket } from "@kit.NetworkKit";
import { FtpTlsOptions } from "./FtpTlsOptions";
import FtpLogger from "../FtpLogger";

const tag = "FtpSocketTLSImpl";

export class FtpSocketTLSImpl implements FtpSocket {
  private tlsOptions: FtpTlsOptions;
  private tcpSock: socket.TCPSocket | undefined;
  private sock: socket.TLSSocket | undefined;
  private connectedAddress: string | undefined;
  private connectedPort: number | undefined;
  private messageSubscribers: MessageSubscriber[] = [];
  private timeout: number = 0;

  constructor(tlsOptions: FtpTlsOptions, tcpSock: socket.TCPSocket | undefined = undefined) {
    this.tcpSock = tcpSock;
    this.tlsOptions = tlsOptions;
  }

  async isConnected(): Promise<boolean> {
    return this.sock != undefined && (await this.sock.getState()).isConnected;
  }

  connect(address: string, port: number, timeout: number): Promise<void> {
    return new Promise(async (resolve, reject) => {
      try {
        if (this.sock) {
          await this.sock.close();
        }
        if (this.tcpSock && (await this.tcpSock.getState()).isConnected) {
          this.sock = socket.constructTLSSocketInstance(this.tcpSock);
        } else {
          this.sock = socket.constructTLSSocketInstance();
          await this.sock.bind({ address: "0.0.0.0" });
          await this.sock.connect({
            address: { address: address, port: port },
            secureOptions: {},
            skipRemoteValidation: this.tlsOptions.skipRemoteValidation == true,
          });
        }
        this.sock.on("close", () => {
          this.sock = undefined;
        });
        this.sock.on("error", (err) => {
          reject(err);
          FtpLogger.error(tag, `socket error`, err);
        });
        this.sock.on("message", (msg) => {
          this.messageSubscribers.forEach(subscriber => subscriber(msg.message));
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

  async send(data: string | ArrayBuffer): Promise<void> {
    if (!this.sock || !this.connectedAddress || !this.connectedPort) {
      throw new Error("Invalid socket instance, please wait connect success");
    }
    return this.sock.send(data);
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
    return this;
  }

  hasTls(): boolean {
    return true;
  }

  async getRemoteAddress(): Promise<socket.NetAddress | undefined> {
    return this.sock?.getRemoteAddress();
  }
}