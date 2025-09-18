import { AccessOptions } from "./AccessOptions";
import { FtpResponse } from "./FtpResponse";
import { FtpSocket } from "./socket/FtpSocket";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { StringEncoding } from "./util/StringEncoding";
import { socket } from "@kit.NetworkKit";

export interface FtpContext {
  readonly timeout: number;
  readonly accessOptions: AccessOptions;

  hasFeature(feature: string): boolean;

  isConnected(): Promise<boolean>;

  close(): Promise<void>;

  prepareTransfer(): Promise<FtpTransfer>;

  send(command: string): Promise<FtpResponse>;

  access(accessOptions: AccessOptions): Promise<FtpResponse>;

  instanceFlag(options?: AccessOptions): string;

  getRemoteAddress(): Promise<socket.NetAddress | undefined>;

  createSocket(): FtpSocket;

  consumeNextMessage(): Promise<FtpResponse>;

  encoding(): StringEncoding;
}