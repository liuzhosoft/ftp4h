import { FtpSocket, MessageSubscriber } from "./FtpSocket";
import { socket } from "@kit.NetworkKit";
import { FtpTlsOptions } from "./FtpTlsOptions";
import FtpLogger from "../FtpLogger";
import { FtpUtils } from "../FtpUtils";
import { JSON } from "@kit.ArkTS";
import { FtpError } from "../FtpErrors";

const tag = "FtpSocketTLSImpl";

export class FtpSocketTLSImpl implements FtpSocket {
  private tlsOptions: FtpTlsOptions;
  private tcpSock: socket.TCPSocket | undefined;
  private sock: socket.TLSSocket | undefined;
  private connectedAddress: string | undefined;
  private connectedPort: number | undefined;
  private messageSubscribers: MessageSubscriber[] = [];
  private closeSubscribers: ((error?: Error) => void)[] = [];
  private connectionGeneration: number = 0;
  private cancelConnect: (() => void) | undefined;

  constructor(tlsOptions: FtpTlsOptions, tcpSock: socket.TCPSocket | undefined = undefined) {
    this.tcpSock = tcpSock;
    this.tlsOptions = tlsOptions;
  }

  async isConnected(): Promise<boolean> {
    return this.sock !== undefined && (await this.sock.getState()).isConnected;
  }

  connect(address: string, port: number, timeout: number): Promise<void> {
    this.cancelConnect?.();
    const previousSocket = this.sock;
    this.sock = undefined;
    this.connectedAddress = undefined;
    this.connectedPort = undefined;
    const generation = ++this.connectionGeneration;
    return new Promise<void>((resolve, reject) => {
      let pending = true;
      let handshakeComplete = false;
      let tlsSocket: socket.TLSSocket | undefined;
      const finish = (error?: Error): void => {
        if (!pending) {
          return;
        }
        pending = false;
        clearTimeout(timer);
        if (generation === this.connectionGeneration) {
          this.cancelConnect = undefined;
        }
        if (error) {
          if (this.sock === tlsSocket) {
            this.sock = undefined;
          }
          const failedSocket = tlsSocket ?? this.tcpSock;
          this.tcpSock = undefined;
          failedSocket?.close().catch((closeError: Error) => FtpLogger.error(tag, "close TLS socket failed", closeError));
          reject(error);
        } else {
          resolve();
        }
      };
      const timer = setTimeout(() => finish(new FtpError(`TLS connect to ${address}:${port} timed out`)),
        timeout > 0 ? timeout : 30000);
      this.cancelConnect = () => finish(new FtpError("TLS connection canceled"));
      const connect = async () => {
        await previousSocket?.close();
        const connectAddress = await FtpUtils.buildNetAddress(address, port);
        const tcpConnected = this.tcpSock ? (await this.tcpSock.getState()).isConnected : false;
        // 地址解析、绑定及握手都可能迟到，取消的连接不能再创建或覆盖当前 socket。
        if (!pending || generation !== this.connectionGeneration) {
          return;
        }
        const currentSocket = tcpConnected ? socket.constructTLSSocketInstance(this.tcpSock!) :
          socket.constructTLSSocketInstance();
        // TLS 原生实例接管已连接的 TCP，后续只关闭拥有该连接的实例。
        this.tcpSock = undefined;
        tlsSocket = currentSocket;
        this.sock = currentSocket;
        if (!tcpConnected) {
          await currentSocket.bind({
            address: connectAddress.family === 2 ? "::" : "0.0.0.0",
            family: connectAddress.family === 2 ? 2 : 1
          });
        }
        if (!pending || generation !== this.connectionGeneration) {
          return;
        }
        // 未绑定的系统 TLS socket 尚未创建原生实例，事件监听必须在 bind 完成后注册。
        currentSocket.on("close", () => {
          FtpLogger.debug(tag, `${address}:${port} closed`);
          const ownsSocket = this.sock === currentSocket;
          if (ownsSocket) {
            this.sock = undefined;
            this.closeSubscribers.slice().forEach(subscriber => subscriber());
          }
          if (!handshakeComplete) {
            finish(new FtpError("TLS socket closed during handshake"));
          } else if (ownsSocket) {
            // 对端结束发送后仍需关闭本地连接，释放原生资源并让服务端完成收尾。
            currentSocket.close().catch((error: Error) => FtpLogger.error(tag, "close peer TLS socket failed", error));
          }
        });
        currentSocket.on("error", (err) => {
          FtpLogger.error(tag, `${address}:${port} meet error, ${JSON.stringify(err)}`);
          finish(err);
          if (handshakeComplete && this.sock === currentSocket) {
            this.closeSubscribers.slice().forEach(subscriber => subscriber(err));
          }
        });
        currentSocket.on("message", (msg) => {
          if (generation === this.connectionGeneration && this.sock === currentSocket) {
            this.messageSubscribers.forEach(subscriber => subscriber(msg.message));
          }
        });
        FtpLogger.info(tag, `connect to ${JSON.stringify(connectAddress)}`);
        await currentSocket.connect({
          address: connectAddress,
          secureOptions: {},
          skipRemoteValidation: this.tlsOptions.skipRemoteValidation === true
        });
        if (!pending || generation !== this.connectionGeneration) {
          return;
        }
        handshakeComplete = true;
        this.connectedAddress = address;
        this.connectedPort = port;
        try {
          await currentSocket.setExtraOptions({ socketTimeout: 0, TCPNoDelay: true });
        } catch (e) {
          // 短传输可能在握手回调后已正常关闭，不把附加参数设置失败当成握手失败。
          if (this.sock === currentSocket) {
            throw e as Error;
          }
        }
        finish();
      };
      connect().catch((error: Error) => {
        FtpLogger.error(tag, `connect to ${address}:${port} failed`, error);
        finish(error);
      });
    });
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    if (!this.sock || !this.connectedAddress || !this.connectedPort) {
      throw new FtpError("Invalid socket instance, please wait connect success");
    }
    return this.sock.send(data);
  }

  subscribeMessage(subscriber: MessageSubscriber): () => void {
    this.messageSubscribers.push(subscriber);
    return () => {
      const index = this.messageSubscribers.indexOf(subscriber);
      if (index !== -1) {
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
    ++this.connectionGeneration;
    const currentSocket = this.sock;
    this.sock = undefined;
    this.connectedAddress = undefined;
    this.connectedPort = undefined;
    const cancelConnect = this.cancelConnect;
    this.cancelConnect = undefined;
    if (cancelConnect) {
      cancelConnect();
    } else {
      // 数据端口可能仅完成 TCP 连接、尚未启动 TLS 握手，此时仍需释放底层连接。
      const transport = this.tcpSock;
      this.tcpSock = undefined;
      await (currentSocket ?? transport)?.close();
    }
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
