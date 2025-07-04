export interface FtpWriteStream {
  writeSync(buf: ArrayBuffer): number;

  flushSync(): void;
}