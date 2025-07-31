import { FtpTlsOptions } from "./FtpTlsOptions";
import { socket } from "@kit.NetworkKit";

export type MessageSubscriber = (data: ArrayBuffer) => void;

export interface FtpSocket {
  isConnected(): Promise<boolean>;

  connect(address: string, port: number, timeout: number): Promise<void>;

  send(data: string | ArrayBuffer): Promise<void>;

  subscribeMessage(subscriber: MessageSubscriber): () => void;

  close(): Promise<void>;

  useTls(options: FtpTlsOptions): FtpSocket;

  hasTls(): boolean;

  getRemoteAddress(): Promise<socket.NetAddress | undefined>;
}