import { FtpContext } from "../FtpContext";
import FtpLogger from "../FtpLogger";
import { FtpResponse } from "../FtpResponse";
import { FtpSocket } from "../socket/FtpSocket";
import { FtpTransfer } from "./FtpTransfer";
import { systemDateTime } from "@kit.BasicServicesKit";

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

  async input(command: string, targetLen: number, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse> {
    FtpLogger.debug(tag, `${this.context.instanceFlag()} input by cmd ${command}, targetLen = ${targetLen}`);
    return new Promise(async (resolve, reject) => {
      if (!this.dataSocket) {
        reject(new Error("Illegal state, call prepare first"));
        return;
      }
      let receivedDataLen = 0;
      let lastReceiveDataTime = systemDateTime.getTime();
      this.runOnClose.push(this.dataSocket!!.subscribeMessage((data) => {
        receiver(data);
        lastReceiveDataTime = systemDateTime.getTime();
        receivedDataLen += data.byteLength;
      }));
      const resp = await this.context.send(command);
      if (resp.code == 150) {
        // 服务端控制通道发了226，可能此时数据通道仍然还在传输，所以对于传入了targetLen的情况，通过收到的数据长度来判断是否结束
        // 对于没有targetLen的情况，通过检测收取数据的间隔时间，当超过200毫秒没有收到数据时，认为数据传输完毕
        const resp = await this.context.consumeNextMessage();
        const monitor = async () => {
          if (targetLen > 0 && receivedDataLen >= targetLen) {
            FtpLogger.debug(tag,
              `${this.context.instanceFlag()} input by cmd ${command} complete because received full data`);
            resolve(resp);
            return;
          }
          const timeGap = systemDateTime.getTime() - lastReceiveDataTime;
          if (lastReceiveDataTime > 0 && timeGap > 200) {
            FtpLogger.debug(tag,
              `${this.context.instanceFlag()} input by cmd ${command} complete because has not received data for a long time`);
            resolve(resp);
            return;
          }
          setTimeout(monitor, 100);
        };
        monitor();
      } else {
        reject(new Error(`input by ${command} failed, resp is ${resp.message}`));
      }
    });
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