import { CharsetUtil, StringEncoding } from "./util/StringEncoding";
import { AccessOptions } from "./AccessOptions";
import { FtpResponse } from "./FtpResponse";
import { FtpSocket, MessageSubscriber } from "./socket/FtpSocket";
import { parseControlResponse, positiveCompletion } from "./parser/parseControlResponse";
import { FtpSocketTLSImpl } from "./socket/FtpSocketTLSImpl";
import { FtpSocketTCPImpl } from "./socket/FtpSocketTCPImpl";
import FtpLogger from "./FtpLogger";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { FtpTransferIpv4Impl } from "./transfer/FtpTransferIpv4Impl";
import { socket } from "@kit.NetworkKit";
import { FtpContext } from "./FtpContext";
import { FtpTransferIpv6Impl } from "./transfer/FtpTransferIpv6Impl";
import { FtpConnectFailedError, FtpError, FtpLoginFailedError } from "./FtpErrors";

const tag = `FtpContext`;

interface SocketTask {
  cmd: string,
  resolve: (resp: FtpResponse) => void;
  reject: (err: Error) => void;
}

interface ResponseWaiter {
  resolve: (response: FtpResponse) => void;
  reject: (error: Error) => void;
}

export class FtpContextImpl implements FtpContext {
  readonly timeout: number;
  private _accessOptions: AccessOptions = {};
  private commandSocket: FtpSocket | undefined;
  private taskQueue: SocketTask[] = [];
  private taskQueueRunning = false;
  private responseWaiters: ResponseWaiter[] = [];
  private responseSocket: FtpSocket | undefined;
  private unsubscribeResponse: (() => void) | undefined;
  private closing: Promise<void> | undefined;
  private controlClosing: Promise<void> | undefined;
  private partialResponse = "";
  private features: Map<string, string> = new Map();
  private utf8On: boolean = false;
  private transfer: FtpTransfer | undefined;
  private dataSocketUseTls = false;

  get accessOptions(): AccessOptions {
    return this._accessOptions;
  }

  constructor(timeout: number) {
    this.timeout = timeout;
  }

  hasFeature(feature: string): boolean {
    return this.features.has(feature);
  }

  async isConnected(): Promise<boolean> {
    return this.commandSocket != undefined && (await this.commandSocket.isConnected());
  }

  close(): Promise<void> {
    if (this.closing) {
      return this.closing;
    }
    FtpLogger.debug(tag, `${this.instanceFlag()} close`);
    const transfer = this.transfer;
    this.transfer = undefined;
    const controlClosing = this.closeControlConnection();
    controlClosing.catch(() => {});
    const closing = Promise.resolve().then(async () => {
      try {
        await transfer?.close();
      } finally {
        await controlClosing;
      }
    }).finally(() => {
      if (this.closing === closing) {
        this.closing = undefined;
      }
    });
    this.closing = closing;
    return closing;
  }

  closeControlConnection(): Promise<void> {
    const commandSocket = this.commandSocket;
    if (!commandSocket) {
      return this.controlClosing ?? Promise.resolve();
    }
    // 先让控制连接失效，清理中的传输不能再被新命令复用。
    this.commandSocket = undefined;
    this.unsubscribeResponse?.();
    this.unsubscribeResponse = undefined;
    this.responseSocket = undefined;
    this.partialResponse = "";
    this.dataSocketUseTls = false;
    const controlClosing = Promise.resolve().then(() => commandSocket.close()).finally(() => {
      if (this.controlClosing === controlClosing) {
        this.controlClosing = undefined;
      }
    });
    this.controlClosing = controlClosing;
    const error = new FtpError("FTP connection closed");
    this.responseWaiters.slice().forEach(waiter => waiter.reject(error));
    this.taskQueue.splice(0).forEach(task => task.reject(error));
    return this.controlClosing;
  }

  async prepareTransfer(): Promise<FtpTransfer> {
    if (this.transfer) {
      throw new FtpError("illegal state, already has a transfer session");
    }
    const commandSocket = this.commandSocket;
    if (!commandSocket) {
      throw new FtpError("FTP connection closed");
    }
    const transferFactories: (() => FtpTransfer)[] = [
      () => new FtpTransferIpv6Impl(this),
      () => new FtpTransferIpv4Impl(this)
    ];

    for (const factory of transferFactories) {
      const transfer = new FtpTransferCloseAwareWrapper(factory(), () => {
        if (this.transfer === transfer) {
          this.transfer = undefined;
        }
      });
      this.transfer = transfer;
      try {
        await transfer.prepare();
        if (this.commandSocket !== commandSocket) {
          throw new FtpError("FTP connection closed");
        }
        return transfer;
      } catch (e) {
        await transfer.close();
        // 只有同一控制会话可以回退被动模式，已取消的准备任务不能向重连后的会话发送 PASV。
        if (this.commandSocket !== commandSocket) {
          throw e as Error;
        }
      }
    }

    throw new FtpError("prepare transfer failed");
  }

  send(command: string): Promise<FtpResponse> {
    FtpLogger.debug(tag, `${this.instanceFlag()} send ${command}`);
    return new Promise((resolve, reject) => {
      this.taskQueue.push({
        cmd: command,
        resolve: resolve,
        reject: reject
      });
      this.checkToEnqueueTasks();
    });
  }

  async access(accessOptions: AccessOptions): Promise<FtpResponse> {
    FtpLogger.debug(tag, `access to ${this.instanceFlag(accessOptions)}`);
    let optionsChanged = false;
    for (const key of Object.keys(accessOptions)) {
      if ((accessOptions as object)[key] !== (this._accessOptions as object)[key]) {
        optionsChanged = true;
      }
    }
    this._accessOptions = accessOptions;
    if (!optionsChanged && this.commandSocket && (await this.commandSocket.isConnected())) {
      FtpLogger.debug(tag, `${this.instanceFlag()} access already complete`);
      return { code: 220, message: "" };
    }
    // 重连前等待上一会话的控制通道和数据通道都完成清理。
    await this.close();
    const useExplicitTLS = this._accessOptions.secureMode === true;
    const useImplicitTLS = this._accessOptions.secureMode === "implicit";
    if (useImplicitTLS) {
      this.commandSocket = new FtpSocketTLSImpl(this._accessOptions.tlsOptions ?? {});
    } else {
      this.commandSocket = new FtpSocketTCPImpl();
    }
    const welcomePromise = this.consumeNextMessage();
    // 连接阶段失败时欢迎消息也会被取消，提前接住其拒绝，避免未处理的 Promise。
    welcomePromise.catch(() => {});
    FtpLogger.debug(tag, `${this.instanceFlag()} connect start`);
    try {
      await this.commandSocket.connect(accessOptions.host ?? "localhost", accessOptions.port ?? 21, this.timeout);
    } catch (e) {
      await this.close();
      throw new FtpConnectFailedError(`connect to ${accessOptions.host}:${accessOptions.port} failed`, e);
    }
    await welcomePromise;
    FtpLogger.debug(tag, `${this.instanceFlag()} connect complete`);
    if (useExplicitTLS) {
      const ret = await this.send("AUTH TLS");
      FtpLogger.debug(tag, `auth tls resp = ${JSON.stringify(ret)}`);
      if (ret.code == 234 || ret.code == 334) {
        this.commandSocket = this.commandSocket.useTls(accessOptions.tlsOptions ?? {});
        try {
          await this.commandSocket.connect(accessOptions.host ?? "localhost", accessOptions.port ?? 21, this.timeout);
        } catch (e) {
          throw new FtpConnectFailedError(`connect to ${accessOptions.host}:${accessOptions.port} use tls failed`, e);
        }
      } else {
        // throw new Error("use explicit tls failed! with reply " + ret.message);
        FtpLogger.info(tag, `use explicit tls failed, maybe server not support!`);
      }
    }

    await this.login(accessOptions);

    await this.applyDefaultSettings();


    return welcomePromise;
  }

  instanceFlag(options?: AccessOptions): string {
    options = options ?? this._accessOptions;
    return `${options.user}@${options.host}:${options.port}`;
  }

  async getRemoteAddress(): Promise<socket.NetAddress | undefined> {
    return this.commandSocket?.getRemoteAddress();
  }

  createSocket(transport?: FtpSocket): FtpSocket {
    if (this.dataSocketUseTls) {
      const options = this.accessOptions.tlsOptions ?? {};
      return transport ? transport.useTls(options) : new FtpSocketTLSImpl(options);
    }
    return transport ?? new FtpSocketTCPImpl();
  }

  /**
   * partialResponse中有有效的完整response，直接取出返回，并将剩余部分重新赋值到partialResponse
   */
  private takeResponseFromPartialResponse(): FtpResponse | undefined {
    if (!this.partialResponse) {
      return undefined;
    }
    const parsed = parseControlResponse(this.partialResponse, true);
    if (parsed.messages.length <= 0) {
      return undefined;
    }
    this.partialResponse = parsed.rest;
    const msg = parsed.messages[0];
    const code = parseInt(msg.substring(0, 3), 10);
    return {
      code: code,
      message: msg
    };
  }

  private listenForResponses(): void {
    const commandSocket = this.commandSocket;
    if (!commandSocket || this.responseSocket === commandSocket) {
      return;
    }
    this.unsubscribeResponse?.();
    this.responseSocket = commandSocket;
    // 旧订阅在连接关闭或重新注册监听时取消，回调内同步解析收到的响应。
    const messageSubscriber: MessageSubscriber = data => {
      const serverMsg = CharsetUtil.decode(data, this.encoding());
      FtpLogger.debug(tag, `${this.instanceFlag()} receive message: ${serverMsg}`);
      const completeResponse = this.partialResponse + serverMsg;
      //completeResponse 可能包含多个有效的response，解析第一条返回，其余的继续存下来等待后续的consumer
      this.partialResponse = completeResponse;
      // 监听持续到连接关闭；没有消费者时也保留响应，发送回调与下一次订阅之间不能丢包。
      while (this.responseWaiters.length > 0) {
        const response = this.takeResponseFromPartialResponse();
        if (!response) {
          break;
        }
        this.responseWaiters[0].resolve(response);
      }
    };
    this.unsubscribeResponse = commandSocket.subscribeMessage(messageSubscriber);
  }

  consumeNextMessage(timeout: number = this.timeout): Promise<FtpResponse> {
    return new Promise((resolve, reject) => {
      if (!this.commandSocket) {
        reject(new FtpError("invalid state, commandSocket is not ready!"));
        return;
      }
      this.listenForResponses();
      const cachedResp = this.takeResponseFromPartialResponse();
      if (cachedResp) {
        resolve(cachedResp);
        return;
      }
      let timer: number | undefined;
      const cleanup = () => {
        clearTimeout(timer);
        const index = this.responseWaiters.indexOf(waiter);
        if (index !== -1) {
          this.responseWaiters.splice(index, 1);
        }
      };
      const waiter: ResponseWaiter = {
        resolve: response => {
          cleanup();
          resolve(response);
        },
        reject: error => {
          cleanup();
          reject(error);
        }
      };
      this.responseWaiters.push(waiter);
      // 数据传输的最终响应由传输层按活动情况计时，普通命令仍有独立响应期限。
      if (timeout > 0) {
        timer = setTimeout(() => {
          waiter.reject(new FtpError("FTP response timed out"));
          this.close().catch((error: Error) => FtpLogger.error(tag, "close timed out connection failed", error));
        }, timeout);
      }
    });
  }

  private async login(accessOptions: AccessOptions) {
    const loginResp = await this.send(`USER ${accessOptions.user ?? "anonymous"}`).then((resp) => {
      FtpLogger.debug(tag, `${this.instanceFlag()} command user resp = ${JSON.stringify(resp)}`);
      if (resp.code == 331) {
        return this.send(`PASS ${accessOptions.password ?? "anonymous"}`);
      } else {
        return resp;
      }
    });
    FtpLogger.debug(tag, `${this.instanceFlag()} loginResp = ${JSON.stringify(loginResp)}`);
    if (!positiveCompletion(loginResp.code)) {
      throw new FtpLoginFailedError(loginResp.message);
    }
  }

  encoding(): StringEncoding {
    if (this.utf8On) {
      return "utf8";
    }
    return this._accessOptions.encoding ? this._accessOptions.encoding : "utf8";
  }

  private async applyDefaultSettings() {
    this.features.clear();
    const featureResp = await this.send("FEAT");
    FtpLogger.debug(tag, `${this.instanceFlag()} feature resp is ${JSON.stringify(featureResp)}`);
    if (featureResp.code < 400) {
      featureResp.message.split("\n").slice(1, -1).forEach((line) => {
        const entry = line.trim().split(" ");
        this.features.set(entry[0], entry[1] || "");
      });
    }
    await this.send("TYPE I");
    await this.send("STRU F");
    const supportUtf8 = this.features.has("UTF8") || this.features.has("UTF-8");
    if (supportUtf8) {
      const utf8Resp = await this.send("OPTS UTF8 ON");
      this.utf8On = utf8Resp.code == 200;
      FtpLogger.info(tag,
        `utf8 on for ${this.instanceFlag()} ${this.utf8On ? "success" : "failed"} resp=${JSON.stringify(utf8Resp)}`);
    }
    // 屏蔽这个操作，部分服务器如果这里协商失败，会回退成只返回文件名的状态，这个指令主要是为了减少数据包的大小，但是不同服务器支持情况不一样，所以不设置以保证兼容性
    // if (this.features.has("MLST")) {
    //   await this.send("OPTS MLST type;size;modify;unique;unix.mode;unix.owner;unix.group;unix.ownername;unix.groupname;");
    // }
    if (this.commandSocket?.hasTls() == true) {
      await this.send("PBSZ 0");
      const protResp = await this.send("PROT P");
      this.dataSocketUseTls = positiveCompletion(protResp.code);
    }
  }

  private async checkToEnqueueTasks() {
    if (this.taskQueueRunning) {
      return;
    }
    this.taskQueueRunning = true;
    try {
      while (this.taskQueue.length > 0) {
        const task = this.taskQueue.shift()!;
        const commandSocket = this.commandSocket;
        try {
          if (!commandSocket) {
            throw new FtpError("invalid state, commandSocket is not ready!");
          }
          const response = this.consumeNextMessage();
          FtpLogger.debug(tag, `${this.instanceFlag()} real send command ${task.cmd}`);
          await Promise.all([
            response,
            commandSocket.send(CharsetUtil.encode(task.cmd + "\r\n", this.encoding()))
          ]);
          task.resolve(await response);
        } catch (e) {
          task.reject(e as Error);
          // 等待发送或响应期间可能已取消并清理连接；异常只关闭本次命令使用的连接。
          if (this.commandSocket === commandSocket) {
            await this.close();
          }
        }
      }
    } finally {
      this.taskQueueRunning = false;
    }
  }
}

class FtpTransferCloseAwareWrapper implements FtpTransfer {
  private readonly base: FtpTransfer;
  private readonly onClose: () => void;

  constructor(base: FtpTransfer, onClose: () => void) {
    this.base = base;
    this.onClose = onClose;
  }

  prepare(): Promise<void> {
    return this.base.prepare();
  }

  input(command: string, targetLen: number, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse> {
    return this.base.input(command, targetLen, receiver);
  }

  output(command: string, source: (buf: ArrayBuffer) => Promise<number>,
    onSend?: (currentSendLen: number, totalSendLen: number) => void): Promise<FtpResponse> {
    return this.base.output(command, source, onSend);
  }

  close(): Promise<void> {
    return this.base.close().finally(() => {
      this.onClose();
    });
  }
}
