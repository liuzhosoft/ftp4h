import { FtpResponse } from "../FtpResponse";

export interface FtpTransfer {
  prepare(): Promise<void>;

  // 因为数据是另外一个Socket，这里传入targetLen作为一个检测数据是否传输完毕的辅助措施，否则会出现控制通道已经收到226，但是数据通道还有数据一直在回调的问题
  input(command: string, targetLen: number, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse>;

  output(command: string, source: (buf: ArrayBuffer) => Promise<number>,
    onSend?: (currentSendLen: number, totalSendLen: number) => void): Promise<FtpResponse>;

  close(): Promise<void>;
}
