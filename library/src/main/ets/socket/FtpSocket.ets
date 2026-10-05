import { FtpTlsOptions } from "./FtpTlsOptions";
import { socket } from "@kit.NetworkKit";

export type MessageSubscriber = (data: ArrayBuffer) => void;

export interface FtpSocket {
  isConnected(): Promise<boolean>;

  connect(address: string, port: number, timeout: number): Promise<void>;

  send(data: string | ArrayBuffer): Promise<void>;

  subscribeMessage(subscriber: MessageSubscriber): () => void;

  // 在最后一段数据之后通知对端关闭；有错误时不能当作正常 EOF。
  subscribeClose(subscriber: (error?: Error) => void): () => void;

  close(): Promise<void>;

  useTls(options: FtpTlsOptions): FtpSocket;

  hasTls(): boolean;

  getRemoteAddress(): Promise<socket.NetAddress | undefined>;
}