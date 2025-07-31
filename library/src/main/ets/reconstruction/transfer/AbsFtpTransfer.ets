import { FtpContext } from "../FtpContext";
import FtpLogger from "../FtpLogger";
import { FtpResponse } from "../FtpResponse";
import { FtpSocket } from "../socket/FtpSocket";
import { FtpTransfer } from "./FtpTransfer";

export interface DataSocketOptions {
  socket: FtpSocket;
  address: string;
  port: number;
}

const tag = "AbsFtpTransfer";

export abstract class AbsFtpTransfer implements FtpTransfer {
  protected readonly context: FtpContext;
  protected dataSocket: FtpSocket | undefined;
  protected runOnClose: (() => void)[] = [];

  constructor(context: FtpContext) {
    this.context = context;
  }

  async prepare(): Promise<void> {
    const options = await this.prepareInternal();
    this.dataSocket = options.socket;
    FtpLogger.debug(tag, `${this.context.instanceFlag()} prepare transfer, data port is ${options.port}`);
    await this.dataSocket?.connect(options.address, options.port, this.context.timeout);
  }

  async input(command: string, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse> {
    if (!this.dataSocket) {
      throw new Error("Illegal state, call prepare first");
    }
    this.runOnClose.push(this.dataSocket!!.subscribeMessage((data) => {
      receiver(data);
    }));
    const resp = await this.context.send(command);
    if (resp.code == 150) {
      return await this.context.consumeNextMessage();
    }
    throw new Error(`input by ${command} failed, resp is ${resp.message}`);
  }

  async output(command: string, source: () => Promise<ArrayBuffer>): Promise<FtpResponse> {
    if (!this.dataSocket) {
      throw new Error("Illegal state, call prepare first");
    }
    let closed = false;
    throw new Error("not implement yet");
  }

  async close(): Promise<void> {
    this.runOnClose.forEach((c) => c());
    await this.dataSocket?.close();
  }

  abstract prepareInternal(): Promise<DataSocketOptions>
}