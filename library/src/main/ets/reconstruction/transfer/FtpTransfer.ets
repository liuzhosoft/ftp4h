import { FtpResponse } from "../FtpResponse";

export interface FtpTransfer {
  prepare(): Promise<void>;

  input(command: string, receiver: (buf: ArrayBuffer) => void): Promise<FtpResponse>;

  output(command: string, source: () => Promise<ArrayBuffer>): Promise<FtpResponse>;

  close(): Promise<void>;
}
