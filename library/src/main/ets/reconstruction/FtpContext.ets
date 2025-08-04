import { CharsetUtil, StringEncoding } from "../StringEncoding";
import { AccessOptions } from "./AccessOptions";
import { FtpResponse } from "./FtpResponse";
import { FtpSocket, MessageSubscriber } from "./socket/FtpSocket";
import { parseControlResponse, positiveCompletion, isSingleLine, isMultiline } from "../parseControlResponse";
import { FtpSocketTLSImpl } from "./socket/FtpSocketTLSImpl";
import { FtpSocketTCPImpl } from "./socket/FtpSocketTCPImpl";
import FtpLogger from "./FtpLogger";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { FtpTransferIpv4Impl } from "./transfer/FtpTransferIpv4Impl";
import { socket } from "@kit.NetworkKit";
import { rcp } from "@kit.RemoteCommunicationKit";
import { FtpTransferIpv6Impl } from "./transfer/FtpTransferIpv6Impl";

const tag = `FtpContext`;

interface SocketTask {
  cmd: string,
  resolve: (resp: FtpResponse) => void;
  reject: (err: Error) => void;
}

export class FtpContext {
  readonly timeout: number;
  private _accessOptions: AccessOptions = {};
  private commandSocket: FtpSocket | undefined;
  private taskQueue: SocketTask[] = [];
  private taskQueueRunning = false;
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

  async close(): Promise<void> {
    FtpLogger.debug(tag, `${this.instanceFlag()} close`);
    await this.commandSocket?.close();
    await this.transfer?.close();
  }

  async prepareTransfer(): Promise<FtpTransfer> {
    if (this.transfer) {
      throw new Error("illegal state, already has a transfer session");
    }
    this.transfer = new FtpTransferCloseAwareWrapper(new FtpTransferIpv6Impl(this), () => {
      this.transfer = undefined;
    });
    await this.transfer.prepare();
    return this.transfer;
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
    const useExplicitTLS = this._accessOptions.secureMode === true;
    const useImplicitTLS = this._accessOptions.secureMode === "implicit";
    if (useImplicitTLS) {
      this.commandSocket = new FtpSocketTLSImpl(this._accessOptions.tlsOptions ?? {});
    } else {
      this.commandSocket = new FtpSocketTCPImpl();
    }
    const welcomePromise = this.consumeNextMessage();
    FtpLogger.debug(tag, `${this.instanceFlag()} connect start`);
    await this.commandSocket.connect(accessOptions.host ?? "localhost", accessOptions.port ?? 21, this.timeout);
    await welcomePromise;
    FtpLogger.debug(tag, `${this.instanceFlag()} connect complete`);
    if (useExplicitTLS) {
      const ret = await this.send("AUTH TLS");
      FtpLogger.debug(tag, `auth tls resp = ${JSON.stringify(ret)}`);
      if (ret.code == 234 || ret.code == 334) {
        this.commandSocket = this.commandSocket.useTls(accessOptions.tlsOptions ?? {});
        await this.commandSocket.connect(accessOptions.host ?? "localhost", accessOptions.port ?? 21, this.timeout);
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

  createSocket(): FtpSocket {
    return this.dataSocketUseTls ? new FtpSocketTLSImpl(this.accessOptions.tlsOptions ?? {}) :
      new FtpSocketTCPImpl();
  }

  consumeNextMessage(): Promise<FtpResponse> {
    return new Promise(async (resolve, reject) => {
      if (!this.commandSocket) {
        reject(new Error("invalid state, commandSocket is not ready!"));
        return;
      }
      let unsubscribe: () => void = () => {
      };
      const messageSubscriber: MessageSubscriber = (data) => {
        const serverMsg = CharsetUtil.decode(data, this.encoding());
        if (serverMsg) {
          const completeResponse = this.partialResponse + serverMsg;
          const parsed = parseControlResponse(completeResponse);
          this.partialResponse = parsed.rest;
          const responses: FtpResponse[] = [];
          parsed.messages.forEach((msg) => {
            const code = parseInt(msg.substring(0, 3), 10);
            responses.push({ code: code, message: msg });
          });
          if (responses.length > 0) {
            unsubscribe();
            FtpLogger.debug(tag, `${this.instanceFlag()} receive resp ${JSON.stringify(responses)}`);
            const last = responses[responses.length-1];
            resolve({
              code: last.code,
              message: last.message,
              multiLineResponse: responses.length > 1 ? responses : undefined
            });
          }
        }
      };
      unsubscribe = this.commandSocket.subscribeMessage(messageSubscriber);
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
      throw new Error("login failed");
    }
  }

  encoding(): StringEncoding {
    if (this.utf8On) {
      return "utf8";
    }
    return this._accessOptions.encoding ?? "utf8";
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
        `utf8 on for ${this.instanceFlag()}`);
    }
    if (this.features.has("MLST")) {
      await this.send("OPTS MLST type;size;modify;unique;unix.mode;unix.owner;unix.group;unix.ownername;unix.groupname;");
    }
    if (this.commandSocket?.hasTls() == true) {
      await this.send("PBSZ 0");
      const portPResp = await this.send("PORT P");
      this.dataSocketUseTls = positiveCompletion(portPResp.code);
    }
  }

  private async checkToEnqueueTasks() {
    if (!this.taskQueueRunning) {
      this.taskQueueRunning = true;
      try {
        do {
          const task = this.taskQueue.shift();
          if (task) {
            await new Promise<void>(async (resolve) => {
              if (!this.commandSocket) {
                task.reject(new Error("invalid state, commandSocket is not ready!"));
                resolve();
                return;
              }
              this.consumeNextMessage()
                .then((resp) => task.resolve(resp))
                .catch((e: Error) => task.reject(e))
                .finally(() => {
                  resolve();
                });
              FtpLogger.debug(tag, `${this.instanceFlag()} real send command ${task.cmd}`);
              this.commandSocket.send(CharsetUtil.encode(task.cmd + "\r\n", this.encoding()));
            });
          }
        } while (this.taskQueue.length > 0);
      } finally {
        this.taskQueueRunning = false;
      }
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

  output(command: string, source: () => Promise<ArrayBuffer>,
    onSend?: (currentSendLen: number, totalSendLen: number) => void): Promise<FtpResponse> {
    return this.base.output(command, source, onSend);
  }

  close(): Promise<void> {
    return this.base.close().finally(() => {
      this.onClose();
    });
  }
}