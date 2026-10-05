import FtpLogger from "../FtpLogger";
import { FtpResponse } from "../FtpResponse";
import { FtpSocket } from "../socket/FtpSocket";
import { FtpSocketTCPImpl } from "../socket/FtpSocketTCPImpl";
import { FtpTransfer } from "./FtpTransfer";
import { positiveCompletion } from "../parser/parseControlResponse";
import { FtpContext } from "../FtpContext";
import { FtpError } from "../FtpErrors";

export interface DataSocketOptions {
  address: string;
  port: number;
}

const tag = "AbsFtpTransfer";

interface TransferStart {
  ready: Promise<void>;
  complete: Promise<FtpResponse>;
}

export abstract class AbsFtpTransfer implements FtpTransfer {
  protected readonly context: FtpContext;
  protected dataSocket: FtpSocket | undefined;
  protected runOnClose: (() => void)[] = [];
  private dataOptions: DataSocketOptions | undefined;
  private closed: boolean = false;
  private closing: Promise<void> | undefined;
  private running: boolean = false;
  private commandSent: boolean = false;
  private controlComplete: boolean = false;
  private failTransfer: ((error: Error) => void) | undefined;
  private refreshTimeout: (() => void) | undefined;

  constructor(context: FtpContext) {
    this.context = context;
  }

  async prepare(): Promise<void> {
    const options = await this.prepareInternal();
    if (this.closed) {
      throw new FtpError("transfer canceled");
    }
    this.dataOptions = options;
    const transport = new FtpSocketTCPImpl();
    this.dataSocket = transport;
    FtpLogger.debug(tag, `${this.context.instanceFlag()} prepare transfer, data port is ${options.port}`);
    // 先确认被动端口的 TCP 连接可用，连接失败仍由 prepareTransfer 尝试下一个被动模式。
    await transport.connect(options.address, options.port, this.context.timeout);
    if (this.closed) {
      await transport.close();
      throw new FtpError("transfer canceled");
    }
    // TLS 数据握手随传输命令启动，不能阻塞等待 LIST、RETR 或 STOR 的服务端。
    this.dataSocket = this.context.createSocket(transport);
  }

  async input(command: string, targetLen: number, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse> {
    FtpLogger.debug(tag, `${this.context.instanceFlag()} input by cmd ${command}, targetLen = ${targetLen}`);
    return this.runTransfer(async () => {
      const dataSocket = this.requireDataSocket();
      let receivedDataLen = 0;
      const dataEnded = new Promise<void>((resolve, reject) => {
        this.runOnClose.push(dataSocket.subscribeClose(error => {
          if (error) {
            reject(error);
          } else {
            resolve();
          }
        }));
      });
      // 对端可能在传输命令完成前断开，立即接住拒绝并交给统一清理流程。
      dataEnded.catch((error: Error) => this.failTransfer?.(error as Error));
      // 先订阅数据，再启动握手和命令，避免快速返回的目录内容被丢弃。
      this.runOnClose.push(dataSocket.subscribeMessage((data) => {
        try {
          receiver(data);
        } catch (error) {
          this.failTransfer?.(error as Error);
          return;
        }
        receivedDataLen += data.byteLength;
        this.refreshTimeout?.();
      }));
      const transfer = this.startTransfer(command);
      // 控制连接的完成响应和数据连接的 EOF 都到达后，才能结束本次传输。
      // LIST 没有预先已知的长度，短暂无数据不能证明目录列表已经收完。
      await Promise.all([transfer.ready, transfer.complete, dataEnded]);
      if (targetLen >= 0 && receivedDataLen !== targetLen) {
        throw new FtpError(`FTP data length mismatch: expected ${targetLen}, received ${receivedDataLen}`);
      }
      return transfer.complete;
    });
  }

  async output(
    command: string,
    source: (buf: ArrayBuffer) => Promise<number>,
    onSend?: (currentSendLen: number, totalSendLen: number) => void
  ): Promise<FtpResponse> {
    FtpLogger.debug(tag, `${this.context.instanceFlag()} output by cmd ${command}`);
    return this.runTransfer(async () => {
      const dataSocket = this.requireDataSocket();
      const transfer = this.startTransfer(command);
      const writeData = async () => {
        await transfer.ready;
        let totalSendLen = 0;
        const buf = new ArrayBuffer(1024 * 1024);
        while (!this.closed) {
          const readLen = await source(buf);
          // 读取源可能异步返回，取消后不得再向数据通道写入。
          if (this.closed) {
            throw new FtpError("transfer canceled");
          }
          if (readLen <= 0) {
            break;
          }
          await dataSocket.send(readLen === buf.byteLength ? buf : buf.slice(0, readLen));
          totalSendLen += readLen;
          onSend?.(readLen, totalSendLen);
          this.refreshTimeout?.();
        }
        if (this.closed) {
          throw new FtpError("transfer canceled");
        }
        await dataSocket.close();
      };
      await Promise.all([writeData(), transfer.complete]);
      return transfer.complete;
    });
  }

  private requireDataSocket(): FtpSocket {
    if (this.closed || !this.dataSocket || !this.dataOptions) {
      throw new FtpError("Illegal state, prepare an open transfer first");
    }
    return this.dataSocket;
  }

  private startTransfer(command: string): TransferStart {
    const dataSocket = this.requireDataSocket();
    const options = this.dataOptions!;
    const connected = dataSocket.hasTls()
      ? dataSocket.connect(options.address, options.port, this.context.timeout) : Promise.resolve();
    this.commandSent = true;
    // 控制通道和数据握手并行推进，兼容立即握手和收到传输命令后握手的服务端。
    const accepted = this.context.send(command).then(resp => {
      if (this.closed) {
        throw new FtpError("transfer canceled");
      }
      if (resp.code !== 150 && resp.code !== 125) {
        this.controlComplete = true;
        throw new FtpError(`transfer ${command} rejected: ${resp.message}`);
      }
      this.refreshTimeout?.();
    });
    // 收到初步响应后立即监听最终响应，不等待数据握手，避免遗漏提前到达的 226 或 522。
    const complete = accepted.then(() => this.context.consumeNextMessage(0)).then(resp => {
      this.controlComplete = true;
      if (!positiveCompletion(resp.code)) {
        throw new FtpError(`transfer ${command} failed: ${resp.message}`);
      }
      this.refreshTimeout?.();
      return resp;
    });
    const ready = Promise.all([connected, accepted]).then(() => {
      if (this.closed) {
        throw new FtpError("transfer canceled");
      }
      this.refreshTimeout?.();
    });
    return { ready: ready, complete: complete };
  }

  private runTransfer(action: () => Promise<FtpResponse>): Promise<FtpResponse> {
    if (this.closed || this.running) {
      return Promise.reject(new FtpError("transfer is closed or already running"));
    }
    this.running = true;
    return new Promise<FtpResponse>((resolve, reject) => {
      let settled = false;
      let timer: number | undefined;
      const finish = (error?: Error, response?: FtpResponse): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        this.refreshTimeout = undefined;
        this.failTransfer = undefined;
        this.running = false;
        if (error) {
          this.close().then(() => reject(error), (closeError: Error) => {
            FtpLogger.error(tag, "close transfer failed", closeError);
            reject(error);
          });
        } else {
          resolve(response!);
        }
      };
      this.failTransfer = (error: Error) => finish(error);
      this.refreshTimeout = () => {
        clearTimeout(timer);
        timer = setTimeout(() => finish(new FtpError("FTP transfer timed out")),
          this.context.timeout > 0 ? this.context.timeout : 30000);
      };
      this.runOnClose.push(() => finish(new FtpError("transfer canceled")));
      this.refreshTimeout();
      action().then(resp => finish(undefined, resp), (error: Error) => finish(error));
    });
  }

  close(): Promise<void> {
    if (this.closing) {
      return this.closing;
    }
    this.closed = true;
    const dataSocket = this.dataSocket;
    this.dataSocket = undefined;
    // 未收到传输最终响应时连接不能复用，避免迟到响应被下一条命令消费。
    // 控制通道立即失效，并独立清理，避免 context.close 与 transfer.close 相互等待。
    const controlClosing = this.commandSent && !this.controlComplete ? this.context.closeControlConnection() :
      Promise.resolve();
    controlClosing.catch(() => {});
    this.closing = Promise.resolve().then(async () => {
      try {
        await dataSocket?.close();
      } finally {
        await controlClosing;
      }
    });
    // 取消回调及外层 finally 都等待同一个关闭任务，会话只能在清理完成后释放。
    this.runOnClose.forEach(callback => callback());
    this.runOnClose = [];
    return this.closing;
  }

  abstract prepareInternal(): Promise<DataSocketOptions>;
}
